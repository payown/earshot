import Foundation
import SwiftData

/// Abstraction over feed fetching so the repository can be tested without
/// hitting the network. ``FeedService`` is the production implementation.
///
/// `Sendable` so a fetcher can be handed to ``FeedRefreshActor`` (a
/// `@ModelActor` on a background executor) and used there off the main thread.
/// The production `FeedService` is a value type and trivially `Sendable`; test
/// doubles adopt `@unchecked Sendable`.
protocol FeedFetching: Sendable {
    func fetch(_ urlString: String) async throws -> ParsedFeed
}

// `FeedService: FeedFetching` is declared in FeedService.swift (same file as the
// type) because `FeedFetching` refines `Sendable`: Swift 6 requires a `Sendable`
// conformance to live in the type's own source file so the compiler can verify
// every stored property is itself `Sendable`.

/// Abstraction over episode downloading so tests can assert download calls
/// without hitting the network or filesystem. ``DownloadManager`` satisfies
/// this protocol in production.
protocol EpisodeDownloading: AnyObject {
    func download(_ episode: Episode) async
}

extension DownloadManager: EpisodeDownloading {}

/// The result of refreshing a single podcast. `added` is the count of genuinely
/// new (non-future, newer-than-the-mark) episodes inserted; `wasBackfill` is
/// true when the refresh took a backfill path (first-subscribe / migrated-shell
/// catalog seed) where the inserted episodes are pre-existing catalog and must
/// NOT trigger a new-episode notification (#72). `newestNewEpisodeGUID` is the
/// guid of the newest genuinely-new episode, used as the deep-link / action
/// target.
///
/// `Sendable` — it carries only value types (a guid string, never a `@Model`
/// `Episode`), so it can be returned from ``FeedRefreshActor`` across the actor
/// boundary without dragging a SwiftData object onto another executor. (This
/// also clears the swift6 baseline flag on the old `static let backfill` of a
/// non-Sendable type.)
struct RefreshOutcome: Sendable {
    var added: Int
    var wasBackfill: Bool
    var newestNewEpisodeGUID: String?

    static let backfill = RefreshOutcome(added: 0, wasBackfill: true, newestNewEpisodeGUID: nil)
}

/// Owns subscribe and refresh logic for podcasts. Views call into this instead
/// of touching the model graph directly.
@MainActor
final class SubscriptionRepository {
    private let context: ModelContext
    private let feed: FeedFetching
    private let downloader: EpisodeDownloading?

    /// Whether auto-queue enrollment is active. Preserves the old `queue != nil`
    /// gate: with no queue repository injected, an `autoQueue` podcast's new
    /// episodes fall back to the inbox instead of being enqueued. The actual
    /// enqueue now runs inside ``FeedRefreshActor`` on its background context (the
    /// main-actor `QueueRepository` can't run there), so only the capability flag
    /// is carried — not the repository itself.
    private let autoQueueEnabled: Bool

    init(
        context: ModelContext,
        feed: FeedFetching = FeedService(),
        downloader: EpisodeDownloading? = nil,
        queue: QueueRepository? = nil
    ) {
        self.context = context
        self.feed = feed
        self.downloader = downloader
        self.autoQueueEnabled = queue != nil
    }

    /// Subscribes to a feed URL. If already subscribed, returns the existing
    /// podcast. The existing backlog is pre-dismissed from the inbox and the
    /// high-water mark is set to the newest episode, so subscribing never floods
    /// the inbox -- only episodes published after this point surface later.
    ///
    /// If a `downloader` was provided at init, auto-downloads the N most recent
    /// episodes where N = the global `autoDownloadCount` setting (default 3).
    /// Download failures are logged and do not roll back the subscription.
    ///
    /// The feed fetch, RSS parse, per-episode inserts, and save all run on
    /// ``FeedRefreshActor`` (a background `@ModelActor`), never the main thread,
    /// so an OPML import or a single add doesn't starve VoiceOver (the same fix
    /// applied to refresh, #382). Only `Sendable` identifiers cross back; the
    /// returned `Podcast` is then re-fetched on the main context so callers
    /// (`OPMLImportService` folder membership, `AddFeedView`, search) hold a valid
    /// main-context object.
    @discardableResult
    func subscribe(feedURL: String) async throws -> Podcast {
        let trimmed = feedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = podcast(forFeedURL: trimmed) { return existing }

        // Hand the fetch/parse/insert/save to the background actor (off the main
        // thread). It returns only Sendable PersistentIdentifiers.
        let actor = FeedRefreshActor(modelContainer: context.container)
        let result = try await actor.subscribe(feedURL: trimmed, feed: feed)

        // Pull the background context's writes into the main context so the
        // re-fetch below resolves the freshly-inserted podcast and episodes.
        mergeBackgroundWrites()

        // Re-fetch the podcast on the main context by its persistentModelID so the
        // returned object is a valid main-context `Podcast` for callers. If the
        // feed already existed (actor early return) it was caught above, but guard
        // anyway: fall back to a feed-URL lookup so we never return a stale object.
        guard let podcast = self.podcast(forPersistentID: result.podcastID)
            ?? self.podcast(forFeedURL: trimmed)
        else {
            throw SubscriptionError.podcastNotFoundAfterSubscribe
        }

        // Auto-download the N most recent episodes (global setting; 0 = off). The
        // downloader is @MainActor and needs main-context `Episode`s, so re-fetch
        // the inserted episodes by ID HERE (never inside the actor), sort newest
        // first, and enqueue the top N. Errors from individual downloads are
        // swallowed -- the download manager already logs and marks the episode
        // .failed -- and never roll back the subscription.
        if let downloader, !result.episodeIDs.isEmpty {
            let count = AppSettingsStore(context: context).int(
                SettingsKey.autoDownloadCount,
                default: SettingsDefault.autoDownloadCount
            )
            if count > 0 {
                let toDownload = result.episodeIDs
                    .compactMap { episode(forPersistentID: $0) }
                    .sorted { ($0.pubDate ?? .distantPast) > ($1.pubDate ?? .distantPast) }
                    .prefix(count)
                for episode in toDownload {
                    await downloader.download(episode)
                }
                AppLog.subscriptions.info(
                    "Auto-download: queued \(toDownload.count) episode(s) for \(podcast.title, privacy: .public)"
                )
            }
        }

        return podcast
    }

    /// Re-fetches a feed and inserts only episodes not already present (by guid).
    /// Episodes newer than the high-water mark surface in the inbox; older ones
    /// are pre-dismissed. The high-water mark then advances to the newest seen.
    ///
    /// If the podcast has `autoQueue = true`, genuinely new episodes (newer than
    /// the high-water mark and not future-dated) are enrolled directly into the
    /// play queue instead of the inbox.
    ///
    /// The fetch, RSS parse, diff, and DB writes all run on ``FeedRefreshActor``
    /// (a background `@ModelActor`), never the main thread, so VoiceOver isn't
    /// starved during a refresh (#382). Only the lightweight ``RefreshOutcome``
    /// (value type) crosses back. After the background save, the main context is
    /// re-read so callers holding `podcast` see the new episodes.
    @discardableResult
    func refresh(_ podcast: Podcast) async throws -> RefreshOutcome {
        let feedURL = podcast.feedURL
        let actor = FeedRefreshActor(modelContainer: context.container)
        guard let outcome = try await actor.refreshOne(
            feedURL: feedURL, feed: feed, autoQueueEnabled: autoQueueEnabled
        ) else {
            // The podcast vanished between fetch and refresh; nothing to report.
            return RefreshOutcome(added: 0, wasBackfill: false, newestNewEpisodeGUID: nil)
        }
        // Pull the background context's writes into the main context so a caller
        // holding `podcast` (e.g. EpisodeListView, the tests) observes the new
        // episodes and advanced high-water mark immediately.
        mergeBackgroundWrites()
        return outcome
    }

    /// Refreshes every subscription, logging and continuing past individual
    /// failures so one bad feed doesn't abort the rest. `onProgress` is called
    /// (on the main actor) after each podcast with the running `(completed, total)`.
    ///
    /// `isCancelled` is checked before each feed so a background-task expiration
    /// (#381) stops the loop promptly instead of spinning through every remaining
    /// feed issuing fetches that immediately cancel. Defaults to `Task.isCancelled`.
    @discardableResult
    func refreshAll(
        isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled },
        onProgress: ((_ completed: Int, _ total: Int) -> Void)? = nil
    ) async -> [NewEpisodeNotification] {
        // Hand the whole per-feed loop — fetch, parse, diff, insert, save — to a
        // background `@ModelActor` so none of it runs on the main thread and
        // starves VoiceOver (#382). The actor returns lightweight value-type
        // results; only the cheap progress callback hops back to the main actor.
        let actor = FeedRefreshActor(modelContainer: context.container)
        let progress = onProgress
        let results = await actor.refreshAll(
            feed: feed,
            autoQueueEnabled: autoQueueEnabled,
            isCancelled: isCancelled,
            onProgress: { completed, total in
                progress?(completed, total)
            }
        )

        // Pull the background context's writes into the main context so the UI
        // (and any held `Podcast`/`Episode` objects) reflect the refresh.
        mergeBackgroundWrites()

        // Build notifications from value-type results only — no `@Model` crossed
        // the actor boundary. Only notification-enabled podcasts with genuinely-new
        // episodes (never a backfill pass) earn a notification (#72).
        var notifications: [NewEpisodeNotification] = []
        for result in results {
            guard NewEpisodeNotificationDecision.shouldNotify(
                notificationEnabled: result.notificationEnabled,
                addedCount: result.outcome.added,
                wasBackfill: result.outcome.wasBackfill
            ), let guid = result.outcome.newestNewEpisodeGUID else { continue }
            notifications.append(
                NewEpisodeNotification(
                    podcastFeedURL: result.feedURL,
                    episodeGUID: guid,
                    podcastTitle: result.podcastTitle,
                    newEpisodeCount: result.outcome.added
                )
            )
        }
        return notifications
    }

    // MARK: Helpers

    /// Re-reads the store on the main context after ``FeedRefreshActor`` saved on
    /// its background context, so the main context (and any `Podcast`/`Episode`
    /// the caller holds) reflect the freshly-inserted episodes and advanced marks.
    ///
    /// SwiftData propagates another context's save to the main context, but a
    /// `Podcast.episodes` array already materialized before the background save
    /// can stay stale until something re-faults it. An explicit fetch over both
    /// types forces that re-fault deterministically — cheap relative to the
    /// network refresh it follows.
    private func mergeBackgroundWrites() {
        _ = try? context.fetch(FetchDescriptor<Podcast>())
        _ = try? context.fetch(FetchDescriptor<Episode>())
    }

    private func podcast(forFeedURL url: String) -> Podcast? {
        var descriptor = FetchDescriptor<Podcast>(predicate: #Predicate { $0.feedURL == url })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// Resolves a podcast on the MAIN context from an identifier the background
    /// actor returned, so callers receive a valid main-context object instead of
    /// one bound to a background `ModelContext`. Uses a predicate fetch (not
    /// `ModelContext.model(for:)`, which traps on a missing ID) so a vanished row
    /// returns nil rather than crashing.
    private func podcast(forPersistentID id: PersistentIdentifier) -> Podcast? {
        var descriptor = FetchDescriptor<Podcast>(predicate: #Predicate { $0.persistentModelID == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// Resolves an episode on the MAIN context from a background-actor identifier,
    /// so the @MainActor downloader enqueues against a main-context `Episode`.
    private func episode(forPersistentID id: PersistentIdentifier) -> Episode? {
        var descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.persistentModelID == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }
}

/// Errors surfaced by ``SubscriptionRepository``.
enum SubscriptionError: Error {
    /// The background actor reported a successful subscribe, but the podcast could
    /// not be resolved on the main context afterward (should not happen in
    /// practice — guards a stale/missing re-fetch instead of force-unwrapping).
    case podcastNotFoundAfterSubscribe
}
