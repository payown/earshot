import Foundation
import SwiftData

/// Background engine for whole-library feed refresh.
///
/// `@ModelActor` gives this its own `ModelContext` on a background executor.
/// All the heavy work that used to run on the main actor — fetching every feed,
/// the synchronous `XMLParser.parse()` for each one, diffing against existing
/// episodes by guid, inserting/updating, and saving — happens here instead, so
/// VoiceOver keeps the main thread it needs to walk the a11y tree and speak.
/// Importing/refreshing 100+ feeds on the main actor is exactly what starved it
/// (the same lesson `SubscriptionImporter` documents for the migration import).
///
/// `@Model` objects never cross the actor boundary: callers pass feed URLs and
/// the actor returns value types only (``RefreshOutcome`` / ``RefreshProgress``
/// carry guids and counts, never an `Episode` or `Podcast`).
@ModelActor
actor FeedRefreshActor {
    /// How many feeds are processed between `ModelContext.save()` calls. The old
    /// code saved once per podcast; batching cuts the save count ~10x for a large
    /// library while still bounding how much un-persisted work is at risk if the
    /// task is cancelled mid-run.
    private static let saveBatchSize = 10

    /// The per-podcast result of one refresh pass, identified by feed URL so the
    /// main actor can resolve it back without an `@Model` crossing the boundary.
    struct RefreshProgress: Sendable {
        let feedURL: String
        let podcastTitle: String
        let notificationEnabled: Bool
        let outcome: RefreshOutcome
    }

    /// Refreshes every subscription on the background context, parsing and writing
    /// off the main actor and saving in batches. Mirrors the per-podcast semantics
    /// of `SubscriptionRepository.refresh` exactly (dedup-by-guid, inbox high-water
    /// mark, future-date clamp, migrated-shell backfill, auto-queue enrollment).
    ///
    /// `isCancelled` is checked before each feed so a background-task expiration
    /// (#381) stops the loop promptly. `onProgress` is marshaled to the main actor
    /// and is intentionally cheap (two ints) so it can't reintroduce a per-feed
    /// main-actor stall.
    ///
    /// Returns one ``RefreshProgress`` per podcast that completed without throwing;
    /// the caller decides which earn a notification.
    func refreshAll(
        feed: FeedFetching,
        autoQueueEnabled: Bool,
        isCancelled: @Sendable () -> Bool,
        onProgress: @MainActor @Sendable (_ completed: Int, _ total: Int) -> Void
    ) async -> [RefreshProgress] {
        let podcasts = (try? modelContext.fetch(FetchDescriptor<Podcast>())) ?? []
        let total = podcasts.count
        var results: [RefreshProgress] = []
        var sinceLastSave = 0

        for (index, podcast) in podcasts.enumerated() {
            guard !isCancelled() else {
                AppLog.subscriptions.info("refreshAll stopped early (cancelled) after \(index) of \(total)")
                break
            }
            let title = podcast.title
            let url = podcast.feedURL
            do {
                // The fetch (network I/O) and the synchronous parse inside it both
                // run on this background actor, never the main thread.
                let parsed = try await feed.fetch(url)
                let outcome = apply(parsed, to: podcast, autoQueueEnabled: autoQueueEnabled)
                sinceLastSave += 1
                if sinceLastSave >= Self.saveBatchSize {
                    saveIfNeeded()
                    sinceLastSave = 0
                }
                results.append(
                    RefreshProgress(
                        feedURL: url,
                        podcastTitle: title,
                        notificationEnabled: podcast.notificationEnabled ?? false,
                        outcome: outcome
                    )
                )
            } catch {
                AppLog.subscriptions.error("Refresh failed for \(title, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            await onProgress(index + 1, total)
        }

        // Flush the final partial batch.
        saveIfNeeded()
        return results
    }

    /// Refreshes a single podcast (resolved by feed URL) on the background context.
    /// Used by the single-feed call site (`EpisodeListView`) so its writes also
    /// stay off the main actor. Returns nil if the URL no longer resolves.
    func refreshOne(
        feedURL: String, feed: FeedFetching, autoQueueEnabled: Bool
    ) async throws -> RefreshOutcome? {
        var descriptor = FetchDescriptor<Podcast>(predicate: #Predicate { $0.feedURL == feedURL })
        descriptor.fetchLimit = 1
        guard let podcast = (try? modelContext.fetch(descriptor))?.first else { return nil }
        let parsed = try await feed.fetch(feedURL)
        let outcome = apply(parsed, to: podcast, autoQueueEnabled: autoQueueEnabled)
        saveIfNeeded()
        return outcome
    }

    // MARK: Per-podcast write (mirrors SubscriptionRepository.refresh)

    /// Diffs `parsed` against `podcast` and inserts new episodes, preserving the
    /// exact behavior of the former main-actor `refresh`: migrated-shell backfill,
    /// dedup-by-guid, future-date clamp on the high-water mark, inbox pre-dismiss
    /// vs surface, and auto-queue enrollment. Does NOT save — saving is batched by
    /// the caller.
    private func apply(
        _ parsed: ParsedFeed, to podcast: Podcast, autoQueueEnabled: Bool
    ) -> RefreshOutcome {
        let now = Date.now

        // First refresh of a freshly-migrated shell (no episodes AND no mark):
        // backfill the whole catalog pre-dismissed and seed the mark. Guarded on
        // episodes.isEmpty so a normally-subscribed podcast never takes this path.
        if podcast.episodes.isEmpty && podcast.lastSeenPubDate == nil {
            for item in parsed.episodes {
                let episode = Self.makeEpisode(from: item)
                episode.podcast = podcast
                episode.inboxDismissed = true
                modelContext.insert(episode)
            }
            podcast.lastSeenPubDate = Self.latestNonFuturePubDate(parsed.episodes, now: now) ?? now
            podcast.refreshedAt = now
            AppLog.subscriptions.info("Backfilled \(podcast.title, privacy: .public): \(parsed.episodes.count) episode(s)")
            return .backfill
        }

        let existingGUIDs = Set(podcast.episodes.map(\.guid))
        // Clamp an already-future mark back to now so a previously-poisoned mark
        // can't keep real new episodes out of the inbox (#296).
        let mark = min(podcast.lastSeenPubDate ?? .distantPast, now)
        // Gate matches the former `podcast.autoQueue && queue != nil`: with no
        // queue capability, an autoQueue podcast's new episodes go to the inbox.
        let autoQueueOn = podcast.autoQueue && autoQueueEnabled
        var added = 0
        var autoQueued: [Episode] = []
        var newestNewGUID: String?
        var newestNewPub = Date.distantPast

        for item in parsed.episodes where !existingGUIDs.contains(item.guid) {
            let episode = Self.makeEpisode(from: item)
            episode.podcast = podcast
            let pub = item.pubDate ?? .distantPast
            // New = newer than the mark AND not future-dated (#296).
            let isNewEpisode = pub > mark && pub <= now
            if isNewEpisode && pub >= newestNewPub {
                newestNewGUID = episode.guid
                newestNewPub = pub
            }
            if isNewEpisode && autoQueueOn {
                // Auto-queue: keep out of inbox; enrollment below sets status to
                // .inQueue. inboxDismissed = true so the episode never surfaces in
                // the inbox even if later removed from the queue.
                episode.inboxDismissed = true
                modelContext.insert(episode)
                autoQueued.append(episode)
            } else {
                episode.inboxDismissed = !isNewEpisode
                modelContext.insert(episode)
            }
            added += 1
        }

        // Advance the mark to the newest non-future pub date; never retreat, never
        // to a future date (#296).
        podcast.lastSeenPubDate = max(mark, Self.latestNonFuturePubDate(parsed.episodes, now: now) ?? mark)
        podcast.refreshedAt = now

        // Enroll auto-queue episodes on this same background context, replicating
        // the minimal QueueRepository.add() enqueue (the real QueueRepository is
        // @MainActor and can't run here). Idempotent + dense positions, mirroring
        // the queue invariant.
        if autoQueueOn && !autoQueued.isEmpty {
            enqueueAtEnd(autoQueued)
            AppLog.subscriptions.info(
                "Auto-queue: enrolled \(autoQueued.count) episode(s) for \(podcast.title, privacy: .public)"
            )
        }

        if added > 0 {
            AppLog.subscriptions.info("Refreshed \(podcast.title, privacy: .public): \(added) new episode(s)")
        }

        return RefreshOutcome(added: added, wasBackfill: false, newestNewEpisodeGUID: newestNewGUID)
    }

    /// Appends episodes to the end of the queue on the background context. Mirrors
    /// `QueueRepository.add` (idempotent per episode; status -> .inQueue; dense
    /// positions) without depending on the @MainActor repository.
    private func enqueueAtEnd(_ episodes: [Episode]) {
        let descriptor = FetchDescriptor<QueueItem>(sortBy: [SortDescriptor(\.position)])
        var items = ((try? modelContext.fetch(descriptor)) ?? []).filter { $0.episode != nil }
        for episode in episodes where episode.queueItem == nil {
            let item = QueueItem(episode: episode, position: items.count)
            modelContext.insert(item)
            episode.status = .inQueue
            items.append(item)
        }
        for (index, item) in items.enumerated() where item.position != index {
            item.position = index
        }
    }

    private func saveIfNeeded() {
        guard modelContext.hasChanges else { return }
        do {
            try modelContext.save()
        } catch {
            AppLog.subscriptions.error("Feed refresh save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Pure helpers (mirror SubscriptionRepository)

    private static func makeEpisode(from item: ParsedEpisode) -> Episode {
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
    private static func latestNonFuturePubDate(_ episodes: [ParsedEpisode], now: Date) -> Date? {
        episodes.compactMap(\.pubDate).filter { $0 <= now }.max()
    }
}
