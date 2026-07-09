import Foundation
import SwiftData

/// Background engine for whole-library feed refresh.
///
/// `@ModelActor` gives this its own `ModelContext` on a background executor.
/// All the heavy work that used to run on the main actor — fetching every feed,
/// the synchronous `XMLParser.parse()` for each one, diffing against existing
/// episodes by guid, inserting/updating, and saving — happens here instead, so
/// VoiceOver keeps the main thread it needs to walk the a11y tree and speak.
/// Importing/refreshing 100+ feeds on the main actor is exactly what starved it.
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
        var outcome: RefreshOutcome
    }

    /// The result of subscribing on the background context. Carries only
    /// `PersistentIdentifier`s (a `Sendable` value type), never an `@Model`
    /// `Podcast`/`Episode`, so it can cross back to the main actor. The caller
    /// re-fetches both on the main context by these IDs: the podcast so callers
    /// hold a valid main-context object, the episodes so the @MainActor downloader
    /// can enqueue auto-downloads against main-context `Episode`s.
    ///
    /// `alreadySubscribed` is true when the feed URL already resolved to an
    /// existing podcast — the actor did no fetch/insert/save and `episodeIDs` is
    /// empty, so the caller skips auto-download (mirroring the old early return).
    struct SubscribeResult: Sendable {
        let podcastID: PersistentIdentifier
        let episodeIDs: [PersistentIdentifier]
        let alreadySubscribed: Bool
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

        // Rows whose `outcome.newEpisodeIDs` must be resolved AFTER a save —
        // `persistentModelID` is temporary for a newly-inserted `Episode` until the
        // context saves, mirroring the identical problem solved for
        // `SubscribeOutcome`/`pendingIndexByResult` in `subscribeAll` below.
        var pendingIndexByApply: [Int: ApplyOutcome] = [:]

        func flushPending() {
            saveIfNeeded()
            for (index, applyOutcome) in pendingIndexByApply {
                results[index].outcome = applyOutcome.result()
            }
            pendingIndexByApply.removeAll()
            sinceLastSave = 0
        }

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
                let applyOutcome = apply(parsed, to: podcast, autoQueueEnabled: autoQueueEnabled)
                let resultIndex = results.count
                results.append(
                    RefreshProgress(
                        feedURL: url,
                        podcastTitle: title,
                        notificationEnabled: podcast.notificationEnabled ?? false,
                        outcome: applyOutcome.refreshOutcome
                    )
                )
                pendingIndexByApply[resultIndex] = applyOutcome
                sinceLastSave += 1
                if sinceLastSave >= Self.saveBatchSize {
                    flushPending()
                }
            } catch {
                AppLog.subscriptions.error("Refresh failed for \(title, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            await onProgress(index + 1, total)
        }

        // Flush the final partial batch and resolve its IDs.
        flushPending()
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
        let applyOutcome = apply(parsed, to: podcast, autoQueueEnabled: autoQueueEnabled)
        // Save BEFORE resolving `newEpisodeIDs` — persistentModelID is temporary
        // for a newly-inserted Episode until the context saves (same reason
        // `subscribe(feedURL:feed:inboxSeedCount:)` above saves before `result()`).
        saveIfNeeded()
        return applyOutcome.result()
    }

    /// Subscribes to `feedURL` on the background context: the fetch (network I/O)
    /// and the synchronous RSS parse inside it, plus the per-episode inserts and
    /// the save, all run here off the main actor so VoiceOver isn't starved while
    /// an OPML import or a single add does its heavy work (the same lesson as
    /// refresh). Mirrors the former main-actor `SubscriptionRepository.subscribe`
    /// per-feed semantics: idempotent by feed URL, the newest `inboxSeedCount`
    /// non-future episodes seeded into the inbox (the rest dismissed), high-water
    /// mark seeded to the newest NON-FUTURE pub date (#296), and `refreshedAt`
    /// stamped.
    ///
    /// Returns a ``SubscribeResult`` of `Sendable` identifiers only — never an
    /// `@Model`. Auto-download is NOT done here: the downloader is `@MainActor`,
    /// so the caller re-fetches the inserted episodes by `episodeIDs` on the main
    /// context and enqueues there.
    func subscribe(feedURL: String, feed: FeedFetching, inboxSeedCount: Int) async throws -> SubscribeResult {
        // Single-feed path: do the core subscribe, persist this one feed's writes,
        // THEN read the now-permanent identifiers. persistentModelID is temporary
        // until the context saves; capturing it before the save would yield IDs that
        // never resolve on the main context (the batched `subscribeAll` saves in
        // batches but likewise captures IDs only after its saves).
        let outcome = try await subscribeOne(feedURL: feedURL, feed: feed, inboxSeedCount: inboxSeedCount)
        saveIfNeeded()
        return outcome.result()
    }

    /// Subscribes to every feed URL in `feedURLs` in ONE background pass, saving in
    /// batches rather than once per feed. This is the bulk OPML-import path: it
    /// keeps the entire fetch/parse/insert/save loop off the main actor and — just
    /// as important — lets the caller reconcile the main context exactly ONCE after
    /// the whole batch instead of per feed, which is what was starving VoiceOver
    /// while the Library tab was visible during an import.
    ///
    /// Per-feed semantics are identical to ``subscribe(feedURL:feed:inboxSeedCount:)``:
    /// idempotent by feed URL, newest `inboxSeedCount` non-future episodes seeded
    /// into the inbox, high-water mark seeded to the newest NON-FUTURE pub date
    /// (#296), and `refreshedAt` stamped. A
    /// feed that throws (bad URL, parse failure) is logged via `AppLog.subscriptions`
    /// and skipped — it never aborts the rest of the batch.
    ///
    /// `onProgress` is marshaled to the main actor after each feed and is
    /// intentionally cheap (two ints + an optional title) so it can't reintroduce a
    /// per-feed main-actor stall. The title, when present, is the just-subscribed
    /// (or already-subscribed) podcast's title read on this background context.
    ///
    /// Returns one ``SubscribeResult`` per feed that resolved (new or already
    /// subscribed), in input order, carrying `Sendable` identifiers only — never an
    /// `@Model`. Feeds that threw are absent from the result array.
    func subscribeAll(
        feedURLs: [String],
        feed: FeedFetching,
        inboxSeedCount: Int,
        onProgress: (@MainActor @Sendable (_ completed: Int, _ total: Int, _ currentTitle: String?) -> Void)? = nil
    ) async -> [SubscribeResult] {
        let total = feedURLs.count
        var results: [SubscribeResult] = []
        var sinceLastSave = 0
        var completed = 0

        // Inserted-but-not-yet-finally-saved subscribes whose IDs must be read AFTER
        // a save. persistentModelID is temporary until the context saves; we collect
        // the live @Model objects here (they never leave the actor) and resolve their
        // permanent IDs into `results` after each batch save below.
        var pendingIndexByResult: [Int: SubscribeOutcome] = [:]

        func flushPending() {
            saveIfNeeded()
            for (index, outcome) in pendingIndexByResult { results[index] = outcome.result() }
            pendingIndexByResult.removeAll()
            sinceLastSave = 0
        }

        for url in feedURLs {
            var title: String?
            do {
                let outcome = try await subscribeOne(feedURL: url, feed: feed, inboxSeedCount: inboxSeedCount)
                title = outcome.title
                if outcome.alreadySubscribed {
                    // No insert/save needed: IDs are already permanent.
                    results.append(outcome.result())
                } else {
                    // Reserve the slot now (preserves input order) and fill its
                    // permanent IDs at the next save.
                    let index = results.count
                    results.append(SubscribeResult(podcastID: outcome.podcast.persistentModelID, episodeIDs: [], alreadySubscribed: false))
                    pendingIndexByResult[index] = outcome
                    sinceLastSave += 1
                    if sinceLastSave >= Self.saveBatchSize { flushPending() }
                }
            } catch {
                AppLog.subscriptions.error("OPML import: failed \(url, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            completed += 1
            await onProgress?(completed, total, title)
        }

        // Flush the final partial batch and resolve its IDs.
        flushPending()
        return results
    }

    /// The result of one core subscribe, holding the live @Model objects (which stay
    /// inside the actor) so the caller can read their permanent identifiers AFTER a
    /// save. `result()` projects to the `Sendable` ``SubscribeResult`` and must be
    /// called only after the context has saved (so the IDs are permanent).
    private struct SubscribeOutcome {
        let podcast: Podcast
        let episodes: [Episode]
        let alreadySubscribed: Bool
        var title: String { podcast.title }

        func result() -> SubscribeResult {
            SubscribeResult(
                podcastID: podcast.persistentModelID,
                episodeIDs: episodes.map(\.persistentModelID),
                alreadySubscribed: alreadySubscribed
            )
        }
    }

    /// Core subscribe used by both ``subscribe(feedURL:feed:)`` and
    /// ``subscribeAll(feedURLs:feed:onProgress:)``. Does NOT save — the caller decides
    /// when to save and then reads permanent IDs via ``SubscribeOutcome/result()``.
    private func subscribeOne(feedURL: String, feed: FeedFetching, inboxSeedCount: Int) async throws -> SubscribeOutcome {
        let trimmed = feedURL.trimmingCharacters(in: .whitespacesAndNewlines)

        // Idempotency: an existing subscription returns it with no fetch or insert —
        // exactly the old early return. Its ID is already permanent (it was saved
        // before), so `result()` is valid immediately.
        var existingDescriptor = FetchDescriptor<Podcast>(predicate: #Predicate { $0.feedURL == trimmed })
        existingDescriptor.fetchLimit = 1
        if let existing = (try? modelContext.fetch(existingDescriptor))?.first {
            return SubscribeOutcome(podcast: existing, episodes: [], alreadySubscribed: true)
        }

        // The fetch (network I/O) and the synchronous parse inside it both run on
        // this background actor, never the main thread.
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
        modelContext.insert(podcast)

        // Restore the user's saved per-podcast inbox cap (if any) onto the fresh
        // Podcast BEFORE inbox seeding, so re-adding a previously-removed podcast
        // seeds min(global seed, saved cap) instead of silently dropping the
        // limit (#548). The cap is keyed by feed URL in the AppSetting store
        // (same pattern as the #489 per-podcast filter), which survives the
        // unsubscribe that deleted the old Podcast row.
        if let savedCap = storedInboxCap(forFeedURL: trimmed) {
            podcast.inboxMaxEpisodes = savedCap
        }

        let now = Date.now
        var insertedEpisodes: [Episode] = []
        for item in parsed.episodes {
            let episode = Self.makeEpisode(from: item)
            episode.podcast = podcast
            // Start every episode dismissed; the seed pass below un-dismisses the
            // newest N so they surface in the inbox. This replaces the former
            // blanket pre-dismiss, which left a fresh subscribe with an empty inbox
            // (Flutter seeded the newest N instead — parity gap).
            episode.inboxDismissed = true
            modelContext.insert(episode)
            insertedEpisodes.append(episode)
        }
        // Seed the inbox with the newest N NON-FUTURE episodes (status stays
        // .newEpisode), keeping the rest dismissed. N is resolved on the main actor
        // and passed in; a smaller per-podcast cap (never set on a brand-new
        // podcast, but honored defensively) wins.
        seedInbox(insertedEpisodes, seedCount: inboxSeedCount, perPodcastCap: podcast.inboxMaxEpisodes, now: now)

        // Seed the high-water mark to the newest NON-FUTURE pub date so a misdated
        // future episode can't push the mark ahead of real new episodes (#296).
        podcast.lastSeenPubDate = Self.latestNonFuturePubDate(parsed.episodes, now: now) ?? now
        podcast.refreshedAt = now
        AppLog.subscriptions.info("Subscribed to \(podcast.title, privacy: .public) with \(parsed.episodes.count) episodes, seeded \(min(inboxSeedCount < 0 ? insertedEpisodes.count : inboxSeedCount, insertedEpisodes.count)) into inbox")

        return SubscribeOutcome(podcast: podcast, episodes: insertedEpisodes, alreadySubscribed: false)
    }

    /// The user's saved per-podcast inbox cap for this feed URL, read from the
    /// `podcast_inbox_cap_<feedURL>` AppSetting row on this background context
    /// (`AppSettingsStore` is @MainActor and can't be used here — same reason
    /// ``currentlyPlayingQueueItemID()`` fetches `AppSetting` directly).
    /// Returns nil when unset, stored as the `"null"` sentinel (an explicit
    /// "No limit"), or not a positive integer — bad stored values are ignored
    /// defensively, never trusted (#548).
    private func storedInboxCap(forFeedURL feedURL: String) -> Int? {
        let key = SettingsKey.podcastInboxCap(feedURL: feedURL)
        var descriptor = FetchDescriptor<AppSetting>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        guard let raw = (try? modelContext.fetch(descriptor))?.first?.value,
              raw != "null",
              let cap = Int(raw), cap > 0
        else { return nil }
        return cap
    }

    /// Un-dismisses the newest N non-future episodes from a just-subscribed
    /// podcast so they land in the inbox, leaving the older backlog dismissed.
    ///
    /// `seedCount` is the global "inbox episodes per new podcast" setting:
    /// - `< 0` (the "All" sentinel) seeds the entire non-future backlog,
    /// - `0` seeds nothing (every episode stays dismissed — the legacy behavior),
    /// - `> 0` seeds the newest that many.
    ///
    /// `perPodcastCap` is the podcast's own `inboxMaxEpisodes`; when set and
    /// smaller than the resolved seed it wins, so a show's own cap is never
    /// exceeded. Future-dated episodes (#296) are never seeded. Reuses
    /// ``InboxLogic/idsToDismissForCount`` so the "keep newest, dismiss beyond"
    /// decision matches the per-podcast inbox cap exactly.
    private func seedInbox(_ episodes: [Episode], seedCount: Int, perPodcastCap: Int?, now: Date) {
        // Only non-future episodes are eligible for the inbox (#296).
        let eligible = episodes
            .filter { ($0.pubDate ?? .distantPast) <= now }
            .sorted { ($0.pubDate ?? .distantPast) > ($1.pubDate ?? .distantPast) }
        guard !eligible.isEmpty else { return }

        // Resolve the effective cap. "All" (-1) means the whole eligible backlog.
        var cap = seedCount < 0 ? eligible.count : seedCount
        if let perPodcastCap { cap = min(cap, perPodcastCap) }
        guard cap > 0 else { return } // 0 = seed nothing; leave all dismissed.

        let dismiss = Set(InboxLogic.idsToDismissForCount(eligible.map(\.persistentModelID), cap: cap))
        for episode in eligible where !dismiss.contains(episode.persistentModelID) {
            episode.inboxDismissed = false
        }
    }

    // MARK: Per-podcast write (mirrors SubscriptionRepository.refresh)

    /// The result of one `apply(_:to:autoQueueEnabled:)` pass, holding the live
    /// `@Model` `Episode`s discovered as genuinely new (which stay inside the
    /// actor) so the caller can read their permanent `persistentModelID`s AFTER a
    /// save. `result()` projects to the `Sendable` ``RefreshOutcome`` and must be
    /// called only after the context has saved — mirrors ``SubscribeOutcome`` /
    /// ``SubscribeOutcome/result()`` above, which solves the identical
    /// temporary-ID problem for a fresh subscribe (#639).
    private struct ApplyOutcome {
        let refreshOutcome: RefreshOutcome
        let newEpisodes: [Episode]

        func result() -> RefreshOutcome {
            var outcome = refreshOutcome
            outcome.newEpisodeIDs = newEpisodes.map(\.persistentModelID)
            return outcome
        }
    }

    /// Diffs `parsed` against `podcast` and inserts new episodes, preserving the
    /// exact behavior of the former main-actor `refresh`: migrated-shell backfill,
    /// dedup-by-guid, future-date clamp on the high-water mark, inbox pre-dismiss
    /// vs surface, and auto-queue enrollment. Does NOT save — saving is batched by
    /// the caller. Returns an ``ApplyOutcome`` rather than a ``RefreshOutcome``
    /// directly because the newly-inserted episodes' `persistentModelID`s are not
    /// permanent until the caller saves.
    private func apply(
        _ parsed: ParsedFeed, to podcast: Podcast, autoQueueEnabled: Bool
    ) -> ApplyOutcome {
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
            // Backfilled/pre-existing catalog episodes must NOT trigger
            // auto-download, matching the existing `wasBackfill` notification gate.
            return ApplyOutcome(refreshOutcome: .backfill, newEpisodes: [])
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
        var newEpisodes: [Episode] = []

        // Lookup by guid for the republish pass below (#397), built once instead
        // of a per-item linear scan.
        let existingByGUID = Dictionary(
            podcast.episodes.map { ($0.guid, $0) }, uniquingKeysWith: { first, _ in first }
        )
        resurfaceRepublished(parsed.episodes, existingByGUID: existingByGUID, now: now)

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
            if isNewEpisode {
                // Auto-queue and auto-download are orthogonal: a genuinely-new
                // episode is eligible for auto-download whether or not it was also
                // auto-queued (#639).
                newEpisodes.append(episode)
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
            // Trim auto-queue pile-up to the per-podcast count cap (#494).
            enforceQueueCap(for: podcast)
        }

        if added > 0 {
            AppLog.subscriptions.info("Refreshed \(podcast.title, privacy: .public): \(added) new episode(s)")
        }

        return ApplyOutcome(
            refreshOutcome: RefreshOutcome(added: added, wasBackfill: false, newestNewEpisodeGUID: newestNewGUID),
            newEpisodes: newEpisodes
        )
    }

    /// Re-surfaces an existing episode to the inbox when its podcast republishes
    /// the same guid with a bumped `pubDate` (#397). Previously any item whose
    /// guid already existed was skipped entirely, so a republished episode never
    /// reappeared even though the feed now advertises it as newer.
    ///
    /// Scope is intentionally narrow: only unplayed, not-queued episodes are
    /// touched, and only `added`/`newestNewEpisodeGUID`/notifications are left
    /// alone — a republish is not a "new episode" for notification purposes.
    /// Future-dated pub dates are ignored, mirroring the #296 guard used
    /// elsewhere in this function.
    private func resurfaceRepublished(
        _ items: [ParsedEpisode], existingByGUID: [String: Episode], now: Date
    ) {
        for item in items {
            guard let existing = existingByGUID[item.guid] else { continue }
            guard let newPub = item.pubDate, newPub <= now else { continue }
            let storedPub = existing.pubDate ?? .distantPast
            guard newPub > storedPub else { continue }
            guard existing.status != .played, existing.queueItem == nil else { continue }

            existing.pubDate = newPub
            existing.status = .newEpisode
            existing.inboxDismissed = false
        }
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

    /// Enforces the per-podcast queue COUNT cap right after auto-queue enrollment,
    /// mirroring the inbox count cap by reusing `Podcast.inboxMaxEpisodes`
    /// (nil = unlimited → no enforcement). Keeps the most-recently-queued `cap`
    /// episodes of this podcast and dequeues the oldest beyond it, never the
    /// currently-playing episode. The decision math is the pure
    /// ``QueueLogic/idsToEvictForCount(_:cap:nowPlaying:)``.
    ///
    /// Recency is keyed on `QueueItem.addedAt`, NOT publish date: a manually
    /// "Play next"-ed older episode has a recent `addedAt`, so it sorts as newest
    /// and is kept. The cap therefore trims auto-queue pile-up without fighting an
    /// explicit user enqueue. Eviction removes only the `QueueItem` (status reverts
    /// to `.newEpisode`); the episode stays in the library and keeps its
    /// `inboxDismissed` flag, so it never floods the inbox and is not deleted.
    private func enforceQueueCap(for podcast: Podcast) {
        guard let cap = podcast.inboxMaxEpisodes else { return } // nil = unlimited

        let podcastID = podcast.persistentModelID
        let descriptor = FetchDescriptor<QueueItem>(sortBy: [SortDescriptor(\.position)])
        let queued = ((try? modelContext.fetch(descriptor)) ?? [])
            .filter { $0.episode?.podcast?.persistentModelID == podcastID }
            .sorted { $0.addedAt > $1.addedAt } // newest-added first

        let evictIDs = Set(
            QueueLogic.idsToEvictForCount(
                queued.map(\.persistentModelID),
                cap: cap,
                nowPlaying: currentlyPlayingQueueItemID()
            )
        )
        guard !evictIDs.isEmpty else { return }

        for item in queued where evictIDs.contains(item.persistentModelID) {
            // Dequeue only: keep the episode in the library, dismissed as
            // auto-queue left it, so it neither floods the inbox nor is deleted.
            item.episode?.status = .newEpisode
            modelContext.delete(item)
        }
        recompactQueue()
        AppLog.subscriptions.info(
            "Queue cap: evicted \(evictIDs.count) over-cap item(s) for \(podcast.title, privacy: .public)"
        )
    }

    /// The queue-item id of the currently/last-playing episode, resolved on the
    /// background context via the durable `SettingsKey.lastPlayingEpisodeID` (the
    /// composite `"feedURL|guid"` key PlayerService persists, #576; legacy
    /// bare-guid values still resolve by guid alone). Returns nil when nothing is
    /// playing or the playing episode isn't queued, so the cap never dequeues it.
    private func currentlyPlayingQueueItemID() -> PersistentIdentifier? {
        let key = SettingsKey.lastPlayingEpisodeID
        var settingDescriptor = FetchDescriptor<AppSetting>(predicate: #Predicate { $0.key == key })
        settingDescriptor.fetchLimit = 1
        guard let stored = (try? modelContext.fetch(settingDescriptor))?.first?.value,
              !stored.isEmpty else { return nil }
        guard let episode = DownloadTaskKey.episode(matching: stored, in: modelContext) else { return nil }
        return episode.queueItem?.persistentModelID
    }

    /// Reassigns dense queue positions `0..<N` over all real (non-orphan) items
    /// after a cap eviction, mirroring `QueueRepository`'s compaction invariant.
    private func recompactQueue() {
        let descriptor = FetchDescriptor<QueueItem>(sortBy: [SortDescriptor(\.position)])
        let items = ((try? modelContext.fetch(descriptor)) ?? []).filter { $0.episode != nil }
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
