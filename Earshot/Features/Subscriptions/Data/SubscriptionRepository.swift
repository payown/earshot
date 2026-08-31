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
    func refresh(_ request: FeedRefreshRequest) async throws -> FeedRefreshFetchResult
}

extension FeedFetching {
    /// Source-compatible fallback for test doubles and alternate fetchers. A
    /// fetcher that does not understand HTTP validators still participates in
    /// refresh correctly; it simply reports a modified representation.
    func refresh(_ request: FeedRefreshRequest) async throws -> FeedRefreshFetchResult {
        .modified(
            try await fetch(request.urlString),
            validators: nil
        )
    }
}

enum FeedRefreshTrigger: String, Codable, Sendable {
    case manualToolbar
    case manualPullToRefresh
    case coldLaunch
    case foreground
    case backgroundTask
    case unspecified
}

// `FeedService: FeedFetching` is declared in FeedService.swift (same file as the
// type) because `FeedFetching` refines `Sendable`: Swift 6 requires a `Sendable`
// conformance to live in the type's own source file so the compiler can verify
// every stored property is itself `Sendable`.

/// Abstraction over episode downloading so tests can assert download calls
/// without hitting the network or filesystem. ``DownloadManager`` satisfies
/// this protocol in production.
@MainActor
protocol EpisodeDownloading: AnyObject {
    func download(_ episode: Episode) async
    /// Downloads queued-but-not-downloaded episodes when the user's
    /// "Auto-download queued episodes" setting is on. Defaulted to a no-op so
    /// test fakes and non-DownloadManager conformers need not implement it.
    func downloadQueuedIfEnabled() async
    /// Cancels obsolete transfers and optionally restores the listener's prior
    /// download intent after a publisher corrects an existing enclosure.
    func replaceCorrectedMedia(_ repairs: [CorrectedEpisodeMedia]) async
}

extension EpisodeDownloading {
    func downloadQueuedIfEnabled() async {}
    func replaceCorrectedMedia(_ repairs: [CorrectedEpisodeMedia]) async {}
}

extension DownloadManager: EpisodeDownloading {}

/// The result of refreshing a single podcast. `added` is the count of genuinely
/// new (non-future, newer-than-the-mark) episodes kept for Inbox/queue routing;
/// `filteredCount` is the separately-budgeted count retained only in Library.
/// `wasBackfill` is
/// true when the refresh took a backfill path (first-subscribe / migrated-shell
/// catalog seed) where the inserted episodes are pre-existing catalog and must
/// NOT trigger a new-episode notification (#72). `newestNewEpisodeGUID` is the
/// guid of the newest genuinely-new episode, used as the deep-link / action
/// target. `newEpisodeIDs` carries the `persistentModelID` of every genuinely-new
/// episode from this refresh pass (both auto-queued and inbox-routed — auto-queue
/// and auto-download are orthogonal) so the caller can trigger auto-download
/// (#639); it is always empty on a backfill pass, matching the `wasBackfill` gate.
///
/// `Sendable` — it carries only value types (a guid string and `PersistentIdentifier`s,
/// never a `@Model` `Episode`), so it can be returned from ``FeedRefreshActor``
/// across the actor boundary without dragging a SwiftData object onto another
/// executor. (This also clears the swift6 baseline flag on the old `static let
/// backfill` of a non-Sendable type.)
struct RefreshOutcome: Sendable {
    var added: Int
    var wasBackfill: Bool
    var newestNewEpisodeGUID: String?
    var newEpisodeIDs: [PersistentIdentifier] = []
    var inboxReentryEpisodeIDs: [PersistentIdentifier] = []
    var filteredCount = 0
    var rejectedAllNewCandidates = false
    var keptOverflowCount = 0
    var filteredOverflowCount = 0
    var metadataUpdatedCount = 0
    var correctedMedia: [CorrectedEpisodeMedia] = []

    static let backfill = RefreshOutcome(added: 0, wasBackfill: true, newestNewEpisodeGUID: nil, newEpisodeIDs: [])
}

/// A saved, actor-produced instruction to finish local recovery on the main
/// actor. The background refresh has committed the corrected metadata and
/// local-state reset; the downloader then removes the old file, cancels any
/// surviving URLSession task, and restores the prior download intent through
/// the normal connectivity gate.
struct CorrectedEpisodeMedia: Sendable, Equatable {
    let episodeID: PersistentIdentifier
    let restoreDownloadIntent: Bool
    let staleDownloadPath: String?
}

/// Result of one explicit historical-catalog page. Historical rows are always
/// pre-dismissed, so this type intentionally carries no Inbox/notification data.
struct OlderEpisodePageOutcome: Sendable, Equatable {
    let inserted: Int
    let hasMore: Bool
}

struct FeedRefreshFailure: Codable, Identifiable, Sendable, Equatable {
    let feedURL: String
    let podcastTitle: String
    let reason: String

    var id: String { FeedURLIdentity.canonical(feedURL) }
}

struct SubscriptionRefreshReport: Sendable {
    enum Completion: Sendable, Equatable {
        case full
        case completedWithErrors(succeeded: Int, total: Int, failed: Int)
        case partial(succeeded: Int, total: Int)
        case failure
    }

    let notifications: [NewEpisodeNotification]
    let attempted: Int
    let total: Int
    let succeeded: Int
    let failed: Int
    let cancelled: Bool
    let intendedInsertions: Int
    let durableInsertions: Int
    var filterSafetyWarningPodcasts: [String] = []
    var newEpisodes = 0
    var unchangedFeeds = 0
    var failures: [FeedRefreshFailure] = []

    var completion: Completion {
        if !cancelled, failed == 0, succeeded == total { return .full }
        if !cancelled, attempted == total, failed > 0, succeeded > 0 {
            return .completedWithErrors(succeeded: succeeded, total: total, failed: failed)
        }
        if succeeded > 0 { return .partial(succeeded: succeeded, total: total) }
        return .failure
    }

    var announcement: String {
        let completionText = switch completion {
        case .full:
            "Library refreshed"
        case let .completedWithErrors(_, _, failed):
            "Library refreshed, \(failed) \(failed == 1 ? "feed" : "feeds") failed"
        case let .partial(succeeded, total):
            "Library partially refreshed, \(succeeded) of \(total) feeds"
        case .failure:
            "Library refresh failed"
        }
        guard !filterSafetyWarningPodcasts.isEmpty else { return completionText }
        let podcasts = filterSafetyWarningPodcasts.joined(separator: ", ")
        return "\(completionText). Episode filters excluded all new episodes for \(podcasts). Review those filters."
    }
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

    /// Test-only hook fired each time the main context is reconciled after a
    /// background save (``mergeBackgroundWrites``). Lets tests assert the bulk
    /// import path reconciles ONCE per import rather than once per feed — the core
    /// VoiceOver fix (#440). Nil in production.
    private let onMerge: (() -> Void)?

    /// Whether the current user has an active Earshot Plus entitlement, for
    /// free-tier podcast cap enforcement (#635). `nil` (the default) means "cap
    /// not enforced" — preserves every existing call site / test that doesn't
    /// pass this, matching how `downloader: EpisodeDownloading? = nil` already
    /// works in this type.
    private let isEntitled: Bool?

    init(
        context: ModelContext,
        feed: FeedFetching = FeedService(),
        downloader: EpisodeDownloading? = nil,
        queue: QueueRepository? = nil,
        isEntitled: Bool? = nil,
        onMerge: (() -> Void)? = nil
    ) {
        self.context = context
        self.feed = feed
        self.downloader = downloader
        self.autoQueueEnabled = queue != nil
        self.isEntitled = isEntitled
        self.onMerge = onMerge
    }

    /// Subscribes to a feed URL. If already subscribed, returns the existing
    /// podcast. The newest N episodes (N = the global `inboxDefaultCount` setting,
    /// default 3) are seeded into the inbox; the older backlog is dismissed and the
    /// high-water mark is set to the newest episode, so subscribing surfaces a few
    /// recent episodes without flooding the inbox.
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
        let canonical = FeedURLIdentity.canonical(feedURL)
        if (try? PodcastIdentityService(context: context)
            .existingFollowed(feedURL: canonical)) != nil {
            await PodcastIdentityWriteGate.shared.acquire(feedURLs: [canonical])
            var repairStagedChanges = false
            do {
                try Task.checkCancellation()
                let repair = try IdentityRepairService(context: context)
                    .repair(feedURLs: [canonical])
                repairStagedChanges = repair.didChange
                if repair.didChange { try context.save() }
                guard let repaired = try PodcastIdentityService(context: context)
                    .existingFollowed(feedURL: canonical) else {
                    throw SubscriptionError.podcastNotFoundAfterSubscribe
                }
                await PodcastIdentityWriteGate.shared.release(feedURLs: [canonical])
                return repaired
            } catch {
                if repairStagedChanges || context.hasChanges { context.rollback() }
                await PodcastIdentityWriteGate.shared.release(feedURLs: [canonical])
                throw error
            }
        }

        // Free-tier podcast cap (#635): block an 11th podcast for a non-Plus
        // user BEFORE the network fetch below, so a blocked add never wastes a
        // fetch. `isEntitled == nil` means the cap isn't enforced at this call
        // site (legacy/test behavior).
        var maximumFollowedCount: Int?
        if let isEntitled {
            let currentCount = currentPodcastCountForCapCheck()
            let grandfathered = AppSettingsStore(context: context).grandfatheredPodcastCount()
            if !PodcastCapPolicy.canAddSubscription(
                currentCount: currentCount,
                isEntitled: isEntitled,
                grandfatheredCount: grandfathered
            ) {
                await PodcastIdentityWriteGate.shared.acquire(feedURLs: [canonical])
                if !context.hasChanges { context.rollback() }
                let concurrentlyFollowed = try? PodcastIdentityService(context: context)
                    .existingFollowed(feedURL: canonical)
                await PodcastIdentityWriteGate.shared.release(feedURLs: [canonical])
                if let concurrentlyFollowed { return concurrentlyFollowed }
                throw SubscriptionError.podcastCapReached(
                    currentCount: currentCount,
                    limit: PodcastCapPolicy.effectiveFreeLimit(grandfatheredCount: grandfathered)
                )
            }
            if !isEntitled {
                maximumFollowedCount = PodcastCapPolicy.effectiveFreeLimit(
                    grandfatheredCount: grandfathered
                )
            }
        }

        // Resolve the inbox seed count on the main actor (AppSettingsStore is
        // @MainActor) and pass it into the background actor, which must not touch
        // settings. This is what makes a fresh subscribe land the newest N episodes
        // in the inbox instead of an empty inbox (Flutter parity).
        let inboxSeedCount = AppSettingsStore(context: context).inboxDefaultCount()

        // Hand the fetch/parse/insert/save to the background actor (off the main
        // thread). It returns only Sendable PersistentIdentifiers.
        let actor = await FeedRefreshActor.makeBackground(modelContainer: context.container)
        let result = try await actor.subscribe(
            feedURL: canonical, feed: feed, inboxSeedCount: inboxSeedCount,
            maximumFollowedCount: maximumFollowedCount
        )

        // Pull the background context's writes into the main context so the
        // re-fetch below resolves the freshly-inserted podcast and episodes.
        mergeBackgroundWrites()
        // Re-fetch the podcast on the main context by its persistentModelID so the
        // returned object is a valid main-context `Podcast` for callers. If the
        // feed already existed (actor early return) it was caught above, but guard
        // anyway: fall back to a feed-URL lookup so we never return a stale object.
        guard let podcast = self.podcast(forPersistentID: result.podcastID)
            ?? self.podcast(forFeedURL: canonical)
        else {
            throw SubscriptionError.podcastNotFoundAfterSubscribe
        }

        // No read-only check needed here (#635): the cap gate above already threw
        // before this point when a non-entitled user was at/over the limit, so a
        // freshly-created podcast can never itself be read-only at creation time.
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
        // Cover episodes a fresh subscribe auto-queued (podcast.autoQueue). No-op
        // unless "Auto-download queued episodes" is on and something is queued.
        await downloader?.downloadQueuedIfEnabled()

        if !result.alreadySubscribed {
            NotificationCenter.default.post(
                name: .earshotSubscriptionsDidChange, object: canonical
            )
            NotificationCenter.default.post(name: .earshotInboxDidChange, object: nil)
        }

        return podcast
    }

    /// Unsubscribes from `podcast`: removes every folder membership first — both
    /// the podcast's own (`FolderMembership`) and its episodes'
    /// (`EpisodeFolderMembership`), neither of which cascades from the podcast side,
    /// so a leftover row would dangle — see `FolderRepository.removeFromAllFolders`
    /// and `removePodcastEpisodesFromAllFolders`. Then removes its dangling
    /// listening sessions (same no-cascade problem, which
    /// would otherwise corrupt stats as "Unknown Podcast" — #377), then deletes the
    /// podcast (its episodes cascade) and saves.
    ///
    /// Centralizes the unsubscribe path that previously lived inline in
    /// `SubscriptionsView.unsubscribe` so search, the library, and the inbox all
    /// share one implementation (#499/#500). Returns `true` when the delete saved,
    /// `false` (logged) when the save threw, so the caller can decide whether to
    /// announce success. This method does NOT post a VoiceOver announcement —
    /// announcing is the presentation layer's job.
    @discardableResult
    func unsubscribe(_ podcast: Podcast) -> Bool {
        SubscriptionDeletionRepository(context: context).unsubscribe(podcast)
    }
}

/// Context-local destructive subscription operation. Keeping this small type
/// free of global-actor isolation lets compact Cloud reconciliation run the
/// cascade on its background ModelActor while UI callers continue to invoke it
/// from ``SubscriptionRepository`` on the main actor.
struct SubscriptionDeletionRepository {
    let context: ModelContext
    private let saveOperation: (ModelContext) throws -> Void

    init(context: ModelContext, saveOperation: @escaping (ModelContext) throws -> Void = {
        try $0.save()
    }) {
        self.context = context
        self.saveOperation = saveOperation
    }

    @discardableResult
    func unsubscribe(_ podcast: Podcast) -> Bool {
        let title = podcast.title
        do {
            try PendingCloudFollowIntent.clear(feedURL: podcast.feedURL, in: context)
            try PendingCloudRemoteActivationIntent.clear(feedURL: podcast.feedURL, in: context)
            try PendingCloudUnfollowIntent.set(feedURL: podcast.feedURL, in: context)
        } catch {
            context.rollback()
            AppLog.subscriptions.error(
                "Failed to prepare unsubscribe from \(title, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
        // If the player currently holds an episode of this podcast (loaded or
        // gapless-preloaded), it must let go BEFORE the cascade delete below —
        // otherwise the periodic position persist / listening-session flush
        // writes to a deleted instance within seconds and SwiftData traps
        // (#574). PlayerService observes synchronously on the main queue, so the
        // unload completes before `context.delete` runs even when this context
        // belongs to a background ModelActor. A notification keeps this repository
        // free of a player dependency and covers every unsubscribe surface
        // through this single choke point.
        NotificationCenter.default.post(
            name: .earshotWillDeleteEpisodes,
            object: nil,
            userInfo: [PlayerService.willDeletePodcastIDKey: podcast.persistentModelID]
        )
        let podcastID = podcast.persistentModelID
        var folderRowsRemoved = 0
        var sessionRowsRemoved = 0
        do {
            for membership in try context.fetch(FetchDescriptor<FolderMembership>())
            where membership.podcast?.persistentModelID == podcastID {
                context.delete(membership); folderRowsRemoved += 1
            }
            for membership in try context.fetch(FetchDescriptor<EpisodeFolderMembership>())
            where membership.episode?.podcast?.persistentModelID == podcastID {
                context.delete(membership); folderRowsRemoved += 1
            }
            for session in try context.fetch(FetchDescriptor<ListeningSession>())
            where session.podcast?.persistentModelID == podcastID
                || session.episode?.podcast?.persistentModelID == podcastID {
                context.delete(session); sessionRowsRemoved += 1
            }
        } catch {
            context.rollback()
            AppLog.subscriptions.error(
                "Failed to stage unsubscribe from \(title, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
        // ActiveDownload.episode is a one-way reference (no inverse on Episode, so
        // that Episode's shape stays out of the V4→V5 migration — #701), which
        // means SwiftData will NOT nullify it when the cascade below deletes this
        // podcast's episodes. Drop those rows first, in this same save, or they
        // dangle at deleted rows.
        ActiveDownload.removeRows(forEpisodesOf: podcast, in: context)
        context.delete(podcast)
        do {
            try saveOperation(context)
            if folderRowsRemoved > 0 {
                NotificationCenter.default.post(name: .earshotFoldersDidChange, object: nil)
            }
            if sessionRowsRemoved > 0 {
                NotificationCenter.default.post(name: .earshotListeningHistoryDidChange, object: nil)
            }
            NotificationCenter.default.post(name: .earshotSubscriptionsDidChange, object: nil)
            AppLog.subscriptions.info("Unsubscribed from \(title, privacy: .public)")
            return true
        } catch {
            context.rollback()
            AppLog.subscriptions.error(
                "Failed to unsubscribe from \(title, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

}

@MainActor
extension SubscriptionRepository {

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
    ///
    /// If a `downloader` was provided at init and this pass discovered genuinely
    /// new episodes (never a backfill pass), auto-downloads the newest
    /// `autoDownloadCount` of them via ``autoDownloadRecent(episodeIDsPerPodcast:)``
    /// — this is what makes auto-download fire on an ORDINARY refresh of an
    /// already-subscribed podcast, not just on first subscribe (#639).
    @discardableResult
    func refresh(
        _ podcast: Podcast,
        reconcileEpisodeModels: Bool = true
    ) async throws -> RefreshOutcome {
        let feedURL = podcast.feedURL
        let actor = await FeedRefreshActor.makeBackground(modelContainer: context.container)
        guard let outcome = try await actor.refreshOne(
            feedURL: feedURL, feed: feed, autoQueueEnabled: autoQueueEnabled
        ) else {
            // The podcast vanished between fetch and refresh; nothing to report.
            return RefreshOutcome(added: 0, wasBackfill: false, newestNewEpisodeGUID: nil, newEpisodeIDs: [])
        }
        // Pull the background context's writes into the main context so a caller
        // holding `podcast` (e.g. EpisodeListView, the tests) observes the new
        // episodes and advanced high-water mark immediately. Only THIS podcast's
        // episodes need re-faulting.
        mergeBackgroundWrites(
            affectedPodcastIDs: reconcileEpisodeModels ? [podcast.persistentModelID] : []
        )
        publishInboxReentries(outcome.inboxReentryEpisodeIDs)
        // Refresh-time auto-queue mutates the queue on the background actor, so
        // QueueRepository never gets a chance to publish its normal change
        // notification. Notify after the durable save and main-context merge so
        // CloudProjectionCoordinator exports the new item and queue consumers
        // refresh from committed state.
        if autoQueueEnabled, !outcome.newEpisodeIDs.isEmpty {
            NotificationCenter.default.post(name: .earshotQueueDidChange, object: nil)
        }
        if downloader != nil, !outcome.newEpisodeIDs.isEmpty {
            await autoDownloadRecent(episodeIDsPerPodcast: [outcome.newEpisodeIDs])
        }
        // Refresh-time auto-queue enqueues on a background context (no
        // .earshotQueueDidChange), so trigger the queued-download sweep here on the
        // main actor, where the downloader lives. No-op unless the setting is on.
        await downloader?.downloadQueuedIfEnabled()
        return outcome
    }

    /// Fetches one bounded page of catalog rows that ordinary refresh purposely
    /// leaves behind. The actor scans feed identities in bounded chunks and the
    /// main context is reconciled only after the durable background save.
    func loadOlderEpisodes(
        for podcast: Podcast,
        pageSize: Int = 10,
        reconcileEpisodeModels: Bool = true
    ) async throws -> OlderEpisodePageOutcome {
        let actor = await FeedRefreshActor.makeBackground(modelContainer: context.container)
        guard let outcome = try await actor.loadOlderEpisodes(
            feedURL: podcast.feedURL,
            feed: feed,
            pageSize: pageSize
        ) else {
            return OlderEpisodePageOutcome(inserted: 0, hasMore: false)
        }
        if outcome.inserted > 0 {
            mergeBackgroundWrites(
                affectedPodcastIDs: reconcileEpisodeModels ? [podcast.persistentModelID] : []
            )
        }
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
        await refreshAllReport(isCancelled: isCancelled, onProgress: onProgress).notifications
    }

    @discardableResult
    func refreshAllReport(
        trigger: FeedRefreshTrigger = .unspecified,
        isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled },
        onDurableNotifications: @escaping @MainActor @Sendable (
            [NewEpisodeNotification]
        ) async -> Void = { _ in },
        onDurableCheckpoint: @escaping @MainActor @Sendable (
            FeedRefreshStatusCheckpoint
        ) -> Void = { _ in },
        onProgress: ((_ completed: Int, _ total: Int) -> Void)? = nil
    ) async -> SubscriptionRefreshReport {
        let walStarted = ContinuousClock.now
        StoreWALDiagnostics.log(.beforeFullRefresh)
        defer {
            StoreWALDiagnostics.log(
                .afterFullRefresh,
                elapsed: ContinuousClock.now - walStarted
            )
        }
        // Hand the whole per-feed loop — fetch, parse, diff, insert, save — to a
        // background `@ModelActor` so none of it runs on the main thread and
        // starves VoiceOver (#382). The actor returns lightweight value-type
        // results; only the cheap progress callback hops back to the main actor.
        let actor = await FeedRefreshActor.makeBackground(modelContainer: context.container)
        let progress = onProgress
        let actorReport = await actor.refreshAllReport(
            feed: feed,
            autoQueueEnabled: autoQueueEnabled,
            trigger: trigger,
            isEntitled: isEntitled,
            isCancelled: isCancelled,
            onProgress: { completed, total in
                progress?(completed, total)
            },
            onCheckpoint: { checkpoint in
                // Every value in this callback belongs to a successful actor
                // save. Re-fault only affected podcasts, then start queue and
                // download side effects while the remaining feeds continue.
                let affectedIDs = checkpoint
                    .filter {
                        $0.outcome.added > 0 || $0.outcome.filteredCount > 0
                            || $0.outcome.metadataUpdatedCount > 0
                            || !$0.outcome.inboxReentryEpisodeIDs.isEmpty
                    }
                    .compactMap {
                        self.podcast(forFeedURL: $0.feedURL)?.persistentModelID
                    }
                self.mergeBackgroundWrites(affectedPodcastIDs: affectedIDs)
                self.publishInboxReentries(
                    checkpoint.flatMap { $0.outcome.inboxReentryEpisodeIDs }
                )
                if self.autoQueueEnabled,
                   checkpoint.contains(where: { !$0.outcome.newEpisodeIDs.isEmpty }) {
                    NotificationCenter.default.post(
                        name: .earshotQueueDidChange,
                        object: nil
                    )
                }
                await self.autoDownloadRecent(
                    episodeIDsPerPodcast: checkpoint.map { $0.outcome.newEpisodeIDs }
                )
                await self.downloader?.replaceCorrectedMedia(
                    checkpoint.flatMap { $0.outcome.correctedMedia }
                )
                await self.downloader?.downloadQueuedIfEnabled()
                await onDurableNotifications(self.notifications(from: checkpoint))
                onDurableCheckpoint(
                    FeedRefreshStatusCheckpoint(
                        checked: checkpoint.count,
                        newEpisodes: checkpoint.reduce(0) { $0 + $1.outcome.added },
                        unchangedFeeds: checkpoint.filter(\.wasNotModified).count
                    )
                )
            }
        )
        let results = actorReport.results

        // Build notifications from value-type results only — no `@Model` crossed
        // the actor boundary. Only notification-enabled podcasts with genuinely-new
        // episodes (never a backfill pass) earn a notification (#72).
        let notifications = notifications(from: results)
        recordMediaTransportSnapshot(trigger: .fullRefresh)
        return SubscriptionRefreshReport(
            notifications: notifications,
            attempted: actorReport.attempted,
            total: actorReport.total,
            succeeded: results.count,
            failed: actorReport.failed,
            cancelled: actorReport.cancelled,
            intendedInsertions: actorReport.intendedInsertions,
            durableInsertions: actorReport.durableInsertions,
            filterSafetyWarningPodcasts: results.compactMap {
                $0.outcome.rejectedAllNewCandidates ? $0.podcastTitle : nil
            },
            newEpisodes: results.reduce(0) { $0 + $1.outcome.added },
            unchangedFeeds: results.filter(\.wasNotModified).count,
            failures: actorReport.failures
        )
    }

    private func notifications(
        from results: [FeedRefreshActor.RefreshProgress]
    ) -> [NewEpisodeNotification] {
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

    /// One feed's outcome from a bulk ``subscribeAll(feedURLs:onProgress:)``, resolved
    /// back onto the MAIN context: a live `Podcast` the caller can attach folder
    /// memberships to, plus the `Sendable` episode IDs the @MainActor downloader can
    /// re-fetch and enqueue. `feedURL` is the (trimmed) URL this came from so the
    /// caller can map results back to the OPML group it belongs to.
    struct BulkSubscribeOutcome {
        let feedURL: String
        let podcast: Podcast
        let episodeIDs: [PersistentIdentifier]
        let alreadySubscribed: Bool
    }

    /// The result of a bulk ``subscribeAll(feedURLs:onProgress:)`` pass: the
    /// per-feed outcomes that were actually attempted, plus how many requested
    /// feed URLs were trimmed off the front by the free-tier cap before the
    /// pass even started (#635).
    struct BulkSubscribeResult {
        let outcomes: [BulkSubscribeOutcome]
        /// How many requested feed URLs were NOT attempted because of the
        /// free-tier cap (0 for Plus users, 0 when already under the cap). #635.
        let skippedForCap: Int
        let failed: Int
        let cancelled: Bool
    }

    /// Subscribes to every URL in `feedURLs` in ONE background pass, reconciling the
    /// main context exactly ONCE afterward — not per feed. This is the bulk OPML
    /// import path. The old per-feed `subscribe()` merged the entire Podcast +
    /// Episode tables on the main context once for every feed, and the Library
    /// `@Query` rebuilt its list and VoiceOver tree on each of those merges, which
    /// starved VoiceOver during a large import (#440). Doing the whole batch on the
    /// background actor and merging once removes that per-feed main-thread churn.
    ///
    /// Per-feed semantics match the single-feed `subscribe()`: idempotent by feed
    /// URL, backlog pre-dismissed, #296 future-date clamp, `refreshedAt` stamped,
    /// and a failing feed logged + skipped (never fatal). `onProgress` fires on the
    /// main actor after each feed with `(completed, total, currentTitle)` and is kept
    /// cheap (two ints + an optional String) so it can't reintroduce a stall.
    ///
    /// Auto-download is NOT done here — the caller (`OPMLImportService`) runs it once
    /// at the end against the returned `episodeIDs`, so it too stays off the per-feed
    /// path. Returns one ``BulkSubscribeOutcome`` per feed that resolved, in input
    /// order; feeds that threw are absent.
    func subscribeAll(
        feedURLs: [String],
        onProgress: (@MainActor @Sendable (_ completed: Int, _ total: Int, _ currentTitle: String?) -> Void)? = nil
    ) async -> BulkSubscribeResult {
        var seenFeedURLs: Set<String> = []
        let canonicalFeedURLs = feedURLs.compactMap { rawValue -> String? in
            let canonical = FeedURLIdentity.canonical(rawValue)
            guard !canonical.isEmpty, seenFeedURLs.insert(canonical).inserted else { return nil }
            return canonical
        }
        guard !canonicalFeedURLs.isEmpty else {
            return BulkSubscribeResult(outcomes: [], skippedForCap: 0, failed: 0, cancelled: false)
        }

        var maximumFollowedCount: Int?
        if let isEntitled {
            let grandfathered = AppSettingsStore(context: context).grandfatheredPodcastCount()
            if !isEntitled {
                maximumFollowedCount = PodcastCapPolicy.effectiveFreeLimit(
                    grandfatheredCount: grandfathered
                )
            }
        }

        // Resolve the inbox seed count on the main actor (AppSettingsStore is
        // @MainActor) so the bulk OPML path seeds the inbox identically to the
        // single-add path. The background actor never reads settings.
        let inboxSeedCount = AppSettingsStore(context: context).inboxDefaultCount()

        // Hand the whole fetch/parse/insert/save loop to the background actor. It
        // returns only Sendable PersistentIdentifiers, batching its saves.
        let actor = await FeedRefreshActor.makeBackground(modelContainer: context.container)
        let actorReport = await actor.subscribeAllReport(
            feedURLs: canonicalFeedURLs, feed: feed, inboxSeedCount: inboxSeedCount,
            maximumFollowedCount: maximumFollowedCount, onProgress: onProgress
        )
        let results = actorReport.results

        let reconciliationInterval = PerformanceSignposts.signposter.beginInterval(
            "OPMLReconciliation",
            "resultCount=\(results.count)"
        )
        defer {
            PerformanceSignposts.signposter.endInterval(
                "OPMLReconciliation",
                reconciliationInterval
            )
        }

        // Reconcile the main context ONCE for the entire batch (the essential fix:
        // this used to run once per feed).
        mergeBackgroundWrites()
        // Resolve each result back to a live main-context podcast. A missing
        // persistentID re-fetch is simply skipped (never force-unwrapped).
        var outcomes: [BulkSubscribeOutcome] = []
        for result in results {
            guard let podcast = self.podcast(forPersistentID: result.podcastID)
                ?? self.podcast(forFeedURL: result.feedURL)
            else { continue }
            outcomes.append(
                BulkSubscribeOutcome(
                    feedURL: podcast.feedURL,
                    podcast: podcast,
                    episodeIDs: result.episodeIDs,
                    alreadySubscribed: result.alreadySubscribed
                )
            )
        }
        if actorReport.mutated {
            NotificationCenter.default.post(name: .earshotSubscriptionsDidChange, object: nil)
            NotificationCenter.default.post(name: .earshotInboxDidChange, object: nil)
        }
        recordMediaTransportSnapshot(trigger: .bulkImport)
        return BulkSubscribeResult(
            outcomes: outcomes,
            skippedForCap: actorReport.skippedForCap,
            failed: actorReport.failed,
            cancelled: Task.isCancelled
        )
    }

    private func recordMediaTransportSnapshot(
        trigger: MediaTransportSnapshot.Trigger
    ) {
        do {
            _ = try MediaTransportDiagnostics.capture(in: context, trigger: trigger)
        } catch {
            AppLog.networking.error(
                "Media transport sample failed: \(error.localizedDescription, privacy: .public) (#709)"
            )
        }
    }

    /// Auto-downloads the N most recent episodes (global `autoDownloadCount`; 0 =
    /// off) for each episode-ID set, re-fetching them on the MAIN context (the
    /// downloader is @MainActor and needs main-context `Episode`s). Used by the bulk
    /// OPML path to run auto-download ONCE at the end rather than per feed. No-op
    /// when no downloader was injected — preserving the OPML path's existing
    /// behavior, which has never had a downloader.
    ///
    /// Free-tier cap (#635): when `isEntitled == false`, episodes belonging to a
    /// read-only podcast (``PodcastCapPolicy/readOnlyPodcastIDs``) are excluded —
    /// "no new episodes download for podcasts beyond the first 10." `isEntitled ==
    /// nil` (the default) means the cap isn't enforced at this call site.
    func autoDownloadRecent(episodeIDsPerPodcast: [[PersistentIdentifier]]) async {
        guard let downloader, !episodeIDsPerPodcast.isEmpty else { return }
        let count = AppSettingsStore(context: context).int(
            SettingsKey.autoDownloadCount,
            default: SettingsDefault.autoDownloadCount
        )
        guard count > 0 else { return }

        var readOnlyIDs: Set<PersistentIdentifier> = []
        if let isEntitled, !isEntitled {
            let allPodcasts = allPodcastsForCapCheck()
            let grandfathered = AppSettingsStore(context: context).grandfatheredPodcastCount()
            readOnlyIDs = PodcastCapPolicy.readOnlyPodcastIDs(in: allPodcasts, isEntitled: isEntitled, grandfatheredCount: grandfathered)
        }

        for episodeIDs in episodeIDsPerPodcast where !episodeIDs.isEmpty {
            let toDownload = episodeIDs
                .compactMap { episode(forPersistentID: $0) }
                .filter { episode in
                    guard let podcastID = episode.podcast?.persistentModelID else { return true }
                    return !readOnlyIDs.contains(podcastID)
                }
                .sorted { ($0.pubDate ?? .distantPast) > ($1.pubDate ?? .distantPast) }
                .prefix(count)
            for episode in toDownload {
                await downloader.download(episode)
            }
        }
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
    private func mergeBackgroundWrites(affectedPodcastIDs: [PersistentIdentifier] = []) {
        // Re-register podcast rows so the Library @Query and any held Podcast
        // reflect the background save. Cheap — a few hundred small rows, no
        // episode graph.
        _ = try? context.fetch(FetchDescriptor<Podcast>())
        // Re-fault ONLY the episodes of the podcasts this write actually touched,
        // one podcast at a time, instead of materializing the ENTIRE Episode table
        // at once. The old blanket `fetch(Episode)` was the #696 OOM: measured on
        // device it cost +580 MB at 400 feeds and ~+1.7 GB at 1200 feeds, and it
        // ran on every launch/resume/refresh/import — a memory-pressure jetsam kill
        // on low-RAM devices (a 332-feed tester on an iPhone 13). SwiftData's
        // cross-context merge already keeps @Query results current on its own; this
        // targeted re-fault only fixes a caller holding a specific Podcast whose
        // `.episodes` array faulted in before the background save (the single-feed
        // refresh path). The scoped fetch stays flat with library size: +6.6 MB at
        // 1184 feeds, down from ~1.7 GB.
        for id in affectedPodcastIDs {
            let scoped = FetchDescriptor<Episode>(
                predicate: #Predicate { $0.podcast?.persistentModelID == id }
            )
            _ = try? context.fetch(scoped)
        }
        onMerge?()
    }

    private func podcast(forFeedURL url: String) -> Podcast? {
        try? PodcastIdentityService(context: context).existingAnyState(feedURL: url)
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

    /// A republished episode deliberately re-enters Inbox. Project that false
    /// dismissal with a fresh clock so it wins over an older explicit removal
    /// on another device; ordinary new/backlog rows never enter this path.
    private func publishInboxReentries(_ episodeIDs: [PersistentIdentifier]) {
        let episodes = episodeIDs.compactMap(episode(forPersistentID:))
        guard !episodes.isEmpty else { return }
        postEpisodeUserStateChanges(
            episodes,
            inboxDismissedChangedExplicitly: true
        )
    }

    /// Current podcast count for the free-tier cap check (#635). Unlike the
    /// other `try?` fetch helpers above (whose fallback-to-nil/empty is a
    /// genuinely benign "not found" outcome), a fetch failure HERE would
    /// silently under-count and let a capped-out user add another podcast —
    /// so it's logged rather than swallowed. Still falls back to 0 (never
    /// throws out of a cap check) since blocking every subscribe on a rare
    /// local SwiftData read failure would be a worse user-facing outcome than
    /// the cap being momentarily under-enforced.
    private func currentPodcastCountForCapCheck() -> Int {
        do {
            return try PodcastQuery.followedCount(in: context)
        } catch {
            AppLog.subscriptions.error(
                "Podcast cap check: failed to fetch podcast count, treating as 0: \(error.localizedDescription, privacy: .public)"
            )
            return 0
        }
    }

    /// Full podcast list for the free-tier cap's read-only-podcast computation
    /// (#635). Same reasoning as ``currentPodcastCountForCapCheck()``: a fetch
    /// failure here would silently skip the read-only auto-download gate, so
    /// it's logged rather than swallowed.
    private func allPodcastsForCapCheck() -> [Podcast] {
        do {
            return try context.fetch(PodcastQuery.followedDescriptor())
        } catch {
            AppLog.subscriptions.error(
                "Podcast cap check: failed to fetch podcasts, treating as empty: \(error.localizedDescription, privacy: .public)"
            )
            return []
        }
    }
}

/// Errors surfaced by ``SubscriptionRepository``.
enum SubscriptionError: Error {
    /// The background actor reported a successful subscribe, but the podcast could
    /// not be resolved on the main context afterward (should not happen in
    /// practice — guards a stale/missing re-fetch instead of force-unwrapping).
    case podcastNotFoundAfterSubscribe
    /// Non-Plus user already has `PodcastCapPolicy.effectiveFreeLimit`(-or-more)
    /// podcasts. #632's paywall screen is the intended next UI step; this issue
    /// only defines the gate/result a future paywall presentation hooks into.
    case podcastCapReached(currentCount: Int, limit: Int)
}

extension SubscriptionError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .podcastNotFoundAfterSubscribe:
            return nil // preserves existing fallback-to-generic-message behavior
        case let .podcastCapReached(currentCount, limit):
            return "You've reached the \(limit)-podcast limit on the free plan (currently \(currentCount)). Upgrade to Earshot Plus for unlimited podcasts."
        }
    }
}
