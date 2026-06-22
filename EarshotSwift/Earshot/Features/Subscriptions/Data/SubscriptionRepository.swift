import Foundation
import SwiftData

/// Abstraction over feed fetching so the repository can be tested without
/// hitting the network. ``FeedService`` is the production implementation.
protocol FeedFetching {
    func fetch(_ urlString: String) async throws -> ParsedFeed
}

extension FeedService: FeedFetching {}

/// Abstraction over episode downloading so tests can assert download calls
/// without hitting the network or filesystem. ``DownloadManager`` satisfies
/// this protocol in production.
protocol EpisodeDownloading: AnyObject {
    func download(_ episode: Episode) async
}

extension DownloadManager: EpisodeDownloading {}

/// Owns subscribe and refresh logic for podcasts. Views call into this instead
/// of touching the model graph directly.
@MainActor
final class SubscriptionRepository {
    private let context: ModelContext
    private let feed: FeedFetching
    private let downloader: EpisodeDownloading?
    private let queue: QueueRepository?

    init(
        context: ModelContext,
        feed: FeedFetching = FeedService(),
        downloader: EpisodeDownloading? = nil,
        queue: QueueRepository? = nil
    ) {
        self.context = context
        self.feed = feed
        self.downloader = downloader
        self.queue = queue
    }

    /// Subscribes to a feed URL. If already subscribed, returns the existing
    /// podcast. The existing backlog is pre-dismissed from the inbox and the
    /// high-water mark is set to the newest episode, so subscribing never floods
    /// the inbox -- only episodes published after this point surface later.
    ///
    /// If a `downloader` was provided at init, auto-downloads the N most recent
    /// episodes where N = the global `autoDownloadCount` setting (default 3).
    /// Download failures are logged and do not roll back the subscription.
    @discardableResult
    func subscribe(feedURL: String) async throws -> Podcast {
        let trimmed = feedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = podcast(forFeedURL: trimmed) { return existing }

        let parsed = try await feed.fetch(trimmed)
        let podcast = Podcast(
            feedURL: trimmed,
            title: parsed.title.isEmpty ? "Untitled podcast" : parsed.title,
            author: parsed.author,
            podcastDescription: parsed.description,
            artworkURL: parsed.artworkURL,
            websiteURL: parsed.websiteURL,
            language: parsed.language,
            category: parsed.category
        )
        context.insert(podcast)

        var insertedEpisodes: [Episode] = []
        for item in parsed.episodes {
            let episode = makeEpisode(from: item)
            episode.podcast = podcast
            episode.inboxDismissed = true // pre-dismiss backlog on subscribe
            context.insert(episode)
            insertedEpisodes.append(episode)
        }
        // Seed the high-water mark to the newest NON-FUTURE pub date so a misdated
        // future episode can't push the mark ahead of real new episodes (#296).
        let now = Date.now
        podcast.lastSeenPubDate = latestNonFuturePubDate(parsed.episodes, now: now) ?? now
        podcast.refreshedAt = now
        try context.save()
        AppLog.subscriptions.info("Subscribed to \(podcast.title, privacy: .public) with \(parsed.episodes.count) episodes")

        // Auto-download the N most recent episodes (global setting; 0 = off).
        // Runs after save so episodes are persisted before the download task begins.
        // Errors from individual downloads are swallowed here -- the download
        // manager already logs and marks the episode .failed.
        if let downloader {
            let count = AppSettingsStore(context: context).int(
                SettingsKey.autoDownloadCount,
                default: SettingsDefault.autoDownloadCount
            )
            if count > 0 {
                let toDownload = insertedEpisodes
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
    /// If the podcast has `autoQueue = true` and a `queue` was provided at init,
    /// genuinely new episodes (newer than the high-water mark and not future-dated)
    /// are enrolled directly into the play queue instead of the inbox.
    func refresh(_ podcast: Podcast) async throws {
        let parsed = try await feed.fetch(podcast.feedURL)
        let now = Date.now

        // First refresh of a freshly-migrated shell (no episodes AND no high-water
        // mark): backfill the whole catalog pre-dismissed and seed the mark, so the
        // inbox starts empty and only future episodes surface later -- mirroring
        // subscribe. Guarded on episodes.isEmpty so a normally-subscribed podcast
        // (which always has a mark) never takes this path.
        if podcast.episodes.isEmpty && podcast.lastSeenPubDate == nil {
            for item in parsed.episodes {
                let episode = makeEpisode(from: item)
                episode.podcast = podcast
                episode.inboxDismissed = true
                context.insert(episode)
            }
            podcast.lastSeenPubDate = latestNonFuturePubDate(parsed.episodes, now: now) ?? now
            podcast.refreshedAt = now
            try context.save()
            AppLog.subscriptions.info("Backfilled \(podcast.title, privacy: .public): \(parsed.episodes.count) episode(s)")
            return
        }

        let existingGUIDs = Set(podcast.episodes.map(\.guid))
        // Clamp an already-future mark back to now so a previously-poisoned mark
        // can't keep real new episodes out of the inbox (#296).
        let mark = min(podcast.lastSeenPubDate ?? .distantPast, now)
        var added = 0
        var autoQueued: [Episode] = []

        for item in parsed.episodes where !existingGUIDs.contains(item.guid) {
            let episode = makeEpisode(from: item)
            episode.podcast = podcast
            let pub = item.pubDate ?? .distantPast
            // New = newer than the mark AND not future-dated (#296).
            let isNewEpisode = pub > mark && pub <= now
            if isNewEpisode && podcast.autoQueue && queue != nil {
                // Auto-queue: keep out of inbox; the queue.add() call below sets
                // status = .inQueue. inboxDismissed = true ensures the episode
                // never surfaces in the inbox even if it is later removed from
                // the queue (which would reset status to .newEpisode).
                episode.inboxDismissed = true
                context.insert(episode)
                autoQueued.append(episode)
            } else {
                episode.inboxDismissed = !isNewEpisode
                context.insert(episode)
            }
            added += 1
        }

        // Advance the mark to the newest non-future pub date; never retreat, never
        // to a future date (#296).
        podcast.lastSeenPubDate = max(mark, latestNonFuturePubDate(parsed.episodes, now: now) ?? mark)
        podcast.refreshedAt = now
        try context.save()

        // Enqueue auto-queue episodes after save so they have persistent IDs.
        if let queue, !autoQueued.isEmpty {
            for episode in autoQueued {
                queue.add(episode)
            }
            AppLog.subscriptions.info(
                "Auto-queue: enrolled \(autoQueued.count) episode(s) for \(podcast.title, privacy: .public)"
            )
        }

        if added > 0 {
            AppLog.subscriptions.info("Refreshed \(podcast.title, privacy: .public): \(added) new episode(s)")
        }
    }

    /// Refreshes every subscription, logging and continuing past individual
    /// failures so one bad feed doesn't abort the rest. `onProgress` is called
    /// (on the main actor) after each podcast with the running `(completed, total)`.
    ///
    /// `isCancelled` is checked before each feed so a background-task expiration
    /// (#381) stops the loop promptly instead of spinning through every remaining
    /// feed issuing fetches that immediately cancel. Defaults to `Task.isCancelled`.
    func refreshAll(
        isCancelled: @escaping () -> Bool = { Task.isCancelled },
        onProgress: ((_ completed: Int, _ total: Int) -> Void)? = nil
    ) async {
        let all = (try? context.fetch(FetchDescriptor<Podcast>())) ?? []
        let total = all.count
        for (index, podcast) in all.enumerated() {
            guard !isCancelled() else {
                AppLog.subscriptions.info("refreshAll stopped early (cancelled) after \(index) of \(total)")
                return
            }
            do {
                try await refresh(podcast)
            } catch {
                AppLog.subscriptions.error("Refresh failed for \(podcast.title, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            onProgress?(index + 1, total)
        }
    }

    // MARK: Helpers

    private func podcast(forFeedURL url: String) -> Podcast? {
        var descriptor = FetchDescriptor<Podcast>(predicate: #Predicate { $0.feedURL == url })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    private func makeEpisode(from item: ParsedEpisode) -> Episode {
        Episode(
            guid: item.guid,
            title: item.title,
            audioURL: item.audioURL,
            episodeDescription: item.description,
            durationSeconds: item.durationSeconds,
            pubDate: item.pubDate,
            artworkURL: item.artworkURL,
            episodeNumber: item.episodeNumber,
            seasonNumber: item.seasonNumber,
            chapterURL: item.chapterURL,
            transcriptURL: item.transcriptURL
        )
    }

    /// The newest episode pub date that is not in the future, or nil if none.
    /// Future-dated items are excluded so a misdated episode can't advance the
    /// inbox high-water mark and silently strand later real episodes (#296).
    private func latestNonFuturePubDate(_ episodes: [ParsedEpisode], now: Date) -> Date? {
        episodes.compactMap(\.pubDate).filter { $0 <= now }.max()
    }
}
