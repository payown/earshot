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
    /// A `ModelContext` adopts the executor on which it is created. Constructing
    /// this actor directly from `SubscriptionRepository` (which is `@MainActor`)
    /// therefore pinned the supposedly-background refresh to the UI thread. Do
    /// the construction itself in a detached task so every subsequent actor call
    /// uses a genuinely background serial model executor.
    nonisolated static func makeBackground(
        modelContainer: ModelContainer
    ) async -> FeedRefreshActor {
        await Task.detached(priority: .utility) {
            FeedRefreshActor(modelContainer: modelContainer)
        }.value
    }

#if DEBUG
    private var forcedSaveFailuresForTesting = 0

    /// Direct executor assertion used by the regression test for the device-
    /// measured main-thread refresh stall.
    func isExecutingOnMainThreadForTesting() -> Bool { Thread.isMainThread }

    func forceNextSaveFailureForTesting() {
        forcedSaveFailuresForTesting += 1
    }

    func hasPendingChangesForTesting() -> Bool { modelContext.hasChanges }
#endif

    /// How many feeds are processed between `ModelContext.save()` calls. The old
    /// code saved once per podcast; batching cuts the save count ~10x for a large
    /// library while still bounding how much un-persisted work is at risk if the
    /// task is cancelled mid-run.
    private static let saveBatchSize = 10
    /// Network fetches are overlapped, but all SwiftData mutation remains on this
    /// actor in input order. This keeps imports responsive without creating a
    /// context per feed or an unbounded request burst.
    // Three concurrent feeds balance throughput with CPU and memory headroom for
    // SwiftUI and VoiceOver on device. Six overlapped XML parses made a 60-feed
    // import faster in isolation but could starve the foreground UI; two proved
    // responsive in the build-169 device test, so build 170 measures the middle.
    private static let subscribeFetchConcurrency = 3
    /// Whole-library refresh uses the same bounded network overlap as OPML.
    /// Parsed results are still applied serially on this model actor, so this
    /// never creates concurrent SwiftData writers.
    private static let refreshFetchConcurrency = 3

    private struct FetchCandidate: Sendable {
        let index: Int
        let url: String
        let validators: FeedHTTPValidators?
    }

    private struct FetchedFeed: Sendable {
        let index: Int
        let url: String
        let result: FeedRefreshFetchResult?
        let errorDescription: String?
    }

    /// A single-consumer, back-pressured bridge between cooperative network
    /// children and this actor's serial SwiftData apply loop. `AsyncStream`
    /// buffering can drop values or retain many large parsed feeds; this channel
    /// holds at most one completed result and suspends the producer until the
    /// actor consumes it.
    private actor FetchResultChannel {
        private var waitingReceiver: CheckedContinuation<FetchedFeed?, Never>?
        private var waitingSender: (FetchedFeed, CheckedContinuation<Void, Never>)?
        private var deliveredSender: CheckedContinuation<Void, Never>?
        private var isFinished = false

        func send(_ value: FetchedFeed) async {
            guard !isFinished else { return }
            await withCheckedContinuation { continuation in
                if let receiver = waitingReceiver {
                    waitingReceiver = nil
                    deliveredSender = continuation
                    receiver.resume(returning: value)
                } else {
                    waitingSender = (value, continuation)
                }
            }
        }

        func next() async -> FetchedFeed? {
            // Calling next means the consumer has completely applied the prior
            // value. Only now may the producer replenish that network slot.
            deliveredSender?.resume()
            deliveredSender = nil
            if let sender = waitingSender {
                waitingSender = nil
                deliveredSender = sender.1
                return sender.0
            }
            guard !isFinished else { return nil }
            return await withCheckedContinuation { continuation in
                waitingReceiver = continuation
            }
        }

        func finish() {
            guard !isFinished else { return }
            isFinished = true
            waitingReceiver?.resume(returning: nil)
            waitingReceiver = nil
            deliveredSender?.resume()
            deliveredSender = nil
            waitingSender?.1.resume()
            waitingSender = nil
        }
    }

    private struct FetchPipeline: Sendable {
        let channel: FetchResultChannel
        let producer: Task<Void, Never>
    }

    /// Run only the network fan-out on the cooperative executor. Keeping the task
    /// group out of the custom SwiftData model executor avoids Release builds
    /// discarding completed child results while all model mutation stays isolated.
    private nonisolated static func fetchPipeline(
        _ candidates: [FetchCandidate],
        trigger: FeedRefreshTrigger,
        feed: FeedFetching,
        isCancelled: @escaping @Sendable () -> Bool
    ) -> FetchPipeline {
        let channel = FetchResultChannel()
        let producer = Task { @concurrent in
                await withTaskGroup(of: FetchedFeed.self) { group in
                    var nextIndex = 0

                    func addNext() {
                        guard nextIndex < candidates.count,
                              !Task.isCancelled,
                              !isCancelled() else { return }
                        let candidate = candidates[nextIndex]
                        nextIndex += 1
                        group.addTask {
                            do {
                                return FetchedFeed(
                                    index: candidate.index,
                                    url: candidate.url,
                                    result: try await feed.refresh(FeedRefreshRequest(
                                        urlString: candidate.url,
                                        validators: candidate.validators,
                                        trigger: trigger
                                    )),
                                    errorDescription: nil
                                )
                            } catch {
                                return FetchedFeed(
                                    index: candidate.index,
                                    url: candidate.url,
                                    result: nil,
                                    errorDescription: error.localizedDescription
                                )
                            }
                        }
                    }

                    // Fill the bounded window immediately. Every schedule attempt
                    // still checks both cancellation sources, and cancellation of
                    // the retained producer cancels every task-group child. Waiting
                    // for one feed to finish before opening the window made a slow
                    // first feed stall the entire library for no safety benefit.
                    for _ in 0..<refreshFetchConcurrency { addNext() }
                    while let result = await group.next() {
                        await channel.send(result)
                        addNext()
                    }
                }
                await channel.finish()
        }
        return FetchPipeline(channel: channel, producer: producer)
    }

    /// `Task` cancellation does not automatically propagate into the detached
    /// network producer retained by `FetchPipeline`. Wake the channel consumer
    /// and cancel every task-group child when the refresh owner is cancelled.
    private nonisolated static func nextResult(
        from pipeline: FetchPipeline
    ) async -> FetchedFeed? {
        await withTaskCancellationHandler {
            await pipeline.channel.next()
        } onCancel: {
            pipeline.producer.cancel()
            Task { await pipeline.channel.finish() }
        }
    }
    /// Bulk subscription outcomes retain their newly inserted Episode objects
    /// until a save gives them permanent IDs. Keep this smaller than refresh's
    /// metadata-only batch so large back catalogs cannot accumulate ten feeds'
    /// worth of live model objects at once.
    private static let subscribeSaveBatchSize = 2
    /// OPML restores prioritize making subscriptions usable quickly. The normal
    /// refresh path can add older catalog rows later; because the subscribe seeds
    /// the newest-date high-water mark, that older history stays dismissed and is
    /// never mistaken for newly published Inbox content.
    private static let opmlInitialEpisodeLimit = 10
    /// A relationship-free synced subscription arrives with its source device's
    /// feed high-water mark but no local episode catalog. Seed a small usable
    /// catalog on first refresh; older feed history remains refetchable metadata,
    /// not CloudKit state.
    private static let syncedShellInitialEpisodeLimit = 10
    /// An established subscription refreshes frequently, so it should ingest
    /// only a bounded set of genuinely-new rows. Rebuilding historical gaps made a
    /// single 45,436-episode inverse relationship monopolize SwiftData and block
    /// the UI even from a background context. Older local rows are preserved.
    private static let ordinaryRefreshNewEpisodeLimit = 10
    /// Filtered rows are retained for Library recovery, but never consume the
    /// ten insertion slots reserved for episodes the listener wants to keep.
    private static let ordinaryRefreshFilteredEpisodeLimit = 10
    /// Store lookups used by explicit historical paging stay bounded even when
    /// the remote feed contains tens of thousands of items.
    private static let olderEpisodeIdentityChunkSize = 50
    /// A single unresponsive feed must not hold an OPML import at the URLSession
    /// resource timeout. The normal feed refresh path keeps its existing policy;
    /// this shorter ceiling applies only to bulk import prefetches.
    private static let subscribeFetchTimeout: Duration = .seconds(15)

    /// The per-podcast result of one refresh pass, identified by feed URL so the
    /// main actor can resolve it back without an `@Model` crossing the boundary.
    struct RefreshProgress: Sendable {
        let feedURL: String
        let podcastTitle: String
        let notificationEnabled: Bool
        var outcome: RefreshOutcome
        var wasNotModified = false
    }

    struct RefreshRun: Sendable {
        let results: [RefreshProgress]
        let failures: [FeedRefreshFailure]
        let attempted: Int
        let total: Int
        let failed: Int
        let cancelled: Bool
        let intendedInsertions: Int
        let durableInsertions: Int
    }

    /// The result of subscribing on the background context. Carries only
    /// `PersistentIdentifier`s (a `Sendable` value type), never an `@Model`
    /// `Podcast`/`Episode`, so it can cross back to the main actor. The caller
    /// re-fetches both on the main context by these IDs: the podcast so callers
    /// hold a valid main-context object, the episodes so the @MainActor downloader
    /// can enqueue auto-downloads against main-context `Episode`s.
    ///
    /// `episodeIDs` is NOT every inserted episode — it is only the newest
    /// ``SubscribeOutcome/autoDownloadIDCap`` by pub date, because its sole
    /// consumer is the auto-download pass (which keeps at most the newest
    /// `autoDownloadCount`). Bounding it on the actor keeps a large OPML import
    /// from making the main context resolve every episode of every feed (#696).
    ///
    /// `alreadySubscribed` is true when the feed URL already resolved to an
    /// existing podcast — the actor did no fetch/insert/save and `episodeIDs` is
    /// empty, so the caller skips auto-download (mirroring the old early return).
    struct SubscribeResult: Sendable {
        let feedURL: String
        let podcastID: PersistentIdentifier
        let episodeIDs: [PersistentIdentifier]
        let alreadySubscribed: Bool
    }

    struct BulkSubscribeReport: Sendable {
        let results: [SubscribeResult]
        let skippedForCap: Int
        let failed: Int
        let mutated: Bool
    }

    /// Refreshes every subscription on the background context, parsing and writing
    /// off the main actor and saving in batches. Mirrors the per-podcast semantics
    /// of `SubscriptionRepository.refresh` exactly (dedup-by-guid, inbox high-water
    /// mark, future-date clamp, migrated-shell backfill, auto-queue enrollment).
    ///
    /// `isCancelled` is checked before the initial request and after every
    /// completion so a background-task expiration (#381) stops scheduling new
    /// work and cancels outstanding requests promptly. `onProgress` is marshaled
    /// to the main actor and is intentionally cheap (two ints) so it can't
    /// reintroduce a per-feed main-actor stall.
    ///
    /// Returns one ``RefreshProgress`` per podcast that completed without throwing;
    /// the caller decides which earn a notification.
    func refreshAll(
        feed: FeedFetching,
        autoQueueEnabled: Bool,
        trigger: FeedRefreshTrigger = .unspecified,
        isEntitled: Bool? = nil,
        isCancelled: @escaping @Sendable () -> Bool,
        onProgress: @MainActor @Sendable (_ completed: Int, _ total: Int) -> Void
    ) async -> [RefreshProgress] {
        await refreshAllReport(
            feed: feed,
            autoQueueEnabled: autoQueueEnabled,
            trigger: trigger,
            isEntitled: isEntitled,
            isCancelled: isCancelled,
            onProgress: onProgress
        ).results
    }

    func refreshAllReport(
        feed: FeedFetching,
        autoQueueEnabled: Bool,
        trigger: FeedRefreshTrigger = .unspecified,
        isEntitled: Bool? = nil,
        isCancelled: @escaping @Sendable () -> Bool,
        onProgress: @MainActor @Sendable (_ completed: Int, _ total: Int) -> Void,
        onCheckpoint: @MainActor @Sendable ([RefreshProgress]) async -> Void = { _ in },
        onInboxChange: @MainActor @Sendable () -> Void = {
            NotificationCenter.default.post(name: .earshotInboxDidChange, object: nil)
        }
    ) async -> RefreshRun {
        let wholeRefresh = PerformanceSignposts.signposter.beginInterval("WholeRefresh")
        defer {
            PerformanceSignposts.signposter.endInterval("WholeRefresh", wholeRefresh)
        }
        let correlationID = UUID().uuidString.lowercased()
        let taskCancelledAtEntry = Task.isCancelled
        let fetchedPodcasts = (
            try? modelContext.fetch(PodcastQuery.followedDescriptor())
        ) ?? []
        let refreshDatePairs: [(String, Date)] =
            (try? modelContext.fetch(FetchDescriptor<LocalPodcastState>()))?.compactMap {
                guard let refreshedAt = $0.refreshedAt else { return nil }
                return (FeedURLIdentity.canonical($0.feedURL), refreshedAt)
            } ?? []
        let refreshDates = Dictionary(refreshDatePairs, uniquingKeysWith: max)
        // A foreground pass may be cancelled when the scene backgrounds. Start
        // the next pass with feeds that have never refreshed, then oldest first,
        // so short sessions make fair forward progress instead of repeatedly
        // spending their budget on the same prefix of a large library.
        let podcasts = fetchedPodcasts.sorted { lhs, rhs in
            let lhsDate = refreshDates[FeedURLIdentity.canonical(lhs.feedURL)]
            let rhsDate = refreshDates[FeedURLIdentity.canonical(rhs.feedURL)]
            switch (lhsDate, rhsDate) {
            case (nil, .some): return true
            case (.some, nil): return false
            case let (lhs?, rhs?) where lhs != rhs: return lhs < rhs
            default: return lhs.feedURL < rhs.feedURL
            }
        }
        let total = podcasts.count
        let eligibleFeedCount = podcasts.count
        let entitlementValue = isEntitled.map(String.init) ?? "unknown"
        let availableCapacity = Self.availableCapacityForImportantUsage()
        AppLog.subscriptions.info(
            "refresh=\(correlationID, privacy: .public) trigger=\(trigger.rawValue, privacy: .public) taskCancelledAtEntry=\(taskCancelledAtEntry, privacy: .public) feedsAttempted=\(total) eligibleFeeds=\(eligibleFeedCount) isEntitled=\(entitlementValue, privacy: .public) availableBytes=\(availableCapacity)"
        )
        var resultByInputIndex: [Int: RefreshProgress] = [:]
        var pendingByInputIndex: [Int: ApplyOutcome] = [:]
        var pendingUnchangedByInputIndex: [Int: RefreshProgress] = [:]
        var completed = 0
        var failed = 0
        var intendedInsertions = 0
        var durableInsertions = 0
        var batchIndex = 0
        var sinceLastSave = 0
        var postedIncrementalInboxChange = false
        var failuresByInputIndex: [Int: FeedRefreshFailure] = [:]

        func recordFailure(index: Int, feedURL: String, title: String, reason: String) {
            failuresByInputIndex[index] = FeedRefreshFailure(
                feedURL: feedURL,
                podcastTitle: title,
                reason: reason
            )
        }

        func flushPending() -> (madeNewContentDurable: Bool, results: [RefreshProgress]) {
            guard !pendingByInputIndex.isEmpty || !pendingUnchangedByInputIndex.isEmpty else {
                return (false, [])
            }
            let pendingIndexes = Set(
                pendingByInputIndex.keys.map { $0 }
                    + pendingUnchangedByInputIndex.keys.map { $0 }
            )
            batchIndex += 1
            let batchIntended = pendingByInputIndex.values.reduce(0) {
                $0 + $1.insertedCount
            }
            intendedInsertions += batchIntended
            var madeNewContentDurable = false
            if saveIfNeededOrLog(
                correlationID: correlationID,
                batchIndex: batchIndex,
                feedCount: pendingByInputIndex.count + pendingUnchangedByInputIndex.count,
                intendedInsertions: batchIntended
            ) {
                durableInsertions += batchIntended
                madeNewContentDurable = batchIntended > 0
                for (index, applyOutcome) in pendingByInputIndex {
                    guard var progress = resultByInputIndex[index] else { continue }
                    progress.outcome = applyOutcome.result()
                    resultByInputIndex[index] = progress
                }
                for (index, progress) in pendingUnchangedByInputIndex {
                    resultByInputIndex[index] = progress
                }
            } else {
                failed += pendingByInputIndex.count + pendingUnchangedByInputIndex.count
                for index in pendingByInputIndex.keys {
                    if let progress = resultByInputIndex[index] {
                        recordFailure(
                            index: index,
                            feedURL: progress.feedURL,
                            title: progress.podcastTitle,
                            reason: "Could not save refresh changes."
                        )
                    }
                    resultByInputIndex.removeValue(forKey: index)
                }
                for index in pendingUnchangedByInputIndex.keys {
                    if let progress = resultByInputIndex[index] {
                        recordFailure(
                            index: index,
                            feedURL: progress.feedURL,
                            title: progress.podcastTitle,
                            reason: "Could not save refresh changes."
                        )
                    }
                    resultByInputIndex.removeValue(forKey: index)
                }
            }
            pendingByInputIndex.removeAll()
            pendingUnchangedByInputIndex.removeAll()
            sinceLastSave = 0
            let checkpointResults = pendingIndexes.sorted().compactMap {
                resultByInputIndex[$0]
            }
            return (madeNewContentDurable, checkpointResults)
        }

        let cancelledAtFirstSchedule = isCancelled()
        let firstScheduleReason = cancelledAtFirstSchedule
            ? "task-cancelled"
            : (eligibleFeedCount == 0 ? "no-eligible-feeds" : "scheduled")
        AppLog.subscriptions.info(
            "refresh=\(correlationID, privacy: .public) firstFetch=\(firstScheduleReason, privacy: .public) taskCancelled=\(cancelledAtFirstSchedule, privacy: .public) eligibleFeeds=\(eligibleFeedCount) total=\(total) isEntitled=\(entitlementValue, privacy: .public)"
        )

        let candidates = podcasts.enumerated().map { index, podcast in
            FetchCandidate(
                index: index,
                url: podcast.feedURL,
                validators: FeedRefreshValidatorStore.validators(
                    feedURL: podcast.feedURL,
                    in: modelContext
                )
            )
        }
        let pipeline = Self.fetchPipeline(
            candidates,
            trigger: trigger,
            feed: feed,
            isCancelled: isCancelled
        )
        refreshLoop: while let fetched = await Self.nextResult(from: pipeline) {
            guard !cancelledAtFirstSchedule else { break }
                let inputIndex = fetched.index
                let requestedURL = fetched.url
                // Resolve the destination again by the URL captured inside the
                // network task. This prevents a stale fetched-model/index pair
                // from ever attaching one feed's episodes to another podcast
                // while CloudKit subscription inserts and feed requests overlap.
                guard let podcast = try? PodcastIdentityService(context: modelContext)
                    .existingFollowed(feedURL: requestedURL) else {
                    failed += 1
                    recordFailure(
                        index: inputIndex,
                        feedURL: requestedURL,
                        title: podcasts[inputIndex].title,
                        reason: "Could not match this feed to its podcast."
                    )
                    let feedID = Self.opaqueFeedID(requestedURL, salt: correlationID)
                    AppLog.subscriptions.error(
                        "refresh=\(correlationID, privacy: .public) feed=\(feedID, privacy: .public) outcome=identity-failure"
                    )
                    completed += 1
                    await onProgress(completed, total)
                    continue
                }
                let title = podcast.title
                let url = requestedURL
                let feedID = Self.opaqueFeedID(url, salt: correlationID)
                if let fetchResult = fetched.result {
                    do {
                        if case let .notModified(validators) = fetchResult {
                            LocalStateStore.setRefreshedAt(.now, on: podcast, in: modelContext)
                            try FeedRefreshValidatorStore.set(
                                validators,
                                feedURL: url,
                                in: modelContext
                            )
                            let progress = RefreshProgress(
                                feedURL: url,
                                podcastTitle: title,
                                notificationEnabled: podcast.notificationEnabled ?? false,
                                outcome: RefreshOutcome(
                                    added: 0,
                                    wasBackfill: false,
                                    newestNewEpisodeGUID: nil
                                ),
                                wasNotModified: true
                            )
                            pendingUnchangedByInputIndex[inputIndex] = progress
                            sinceLastSave += 1
                            if sinceLastSave >= Self.saveBatchSize {
                                let checkpoint = flushPending()
                                if !checkpoint.results.isEmpty {
                                    await onCheckpoint(checkpoint.results)
                                }
                            }
                            completed += 1
                            await onProgress(completed, total)
                            if isCancelled() { break refreshLoop }
                            continue
                        }
                        guard case let .modified(parsed, validators) = fetchResult else {
                            continue
                        }
                        let markBefore = podcast.lastSeenPubDate
                        let repairGUIDs = ordinaryRefreshCandidates(
                            from: Self.deduplicatedEpisodes(parsed.episodes),
                            podcast: podcast,
                            now: .now
                        ).map(\.guid)
                        let repair = try IdentityRepairService(context: modelContext)
                            .repairEpisodes(in: podcast, matchingGUIDs: repairGUIDs)
                        if repair.didChange { try saveWithSignpost() }
                        let applyInterval = PerformanceSignposts.signposter.beginInterval(
                            "ActorApply",
                            "inputIndex=\(inputIndex) candidateCount=\(repairGUIDs.count)"
                        )
                        let applyOutcome = apply(
                            parsed, to: podcast, autoQueueEnabled: autoQueueEnabled
                        )
                        try FeedRefreshValidatorStore.set(
                            validators,
                            feedURL: url,
                            in: modelContext
                        )
                        PerformanceSignposts.signposter.endInterval(
                            "ActorApply",
                            applyInterval,
                            "insertedCount=\(applyOutcome.insertedCount)"
                        )
                        AppLog.subscriptions.info(
                            "refresh=\(correlationID, privacy: .public) feed=\(feedID, privacy: .public) candidates=\(repairGUIDs.count) markBefore=\(Self.epoch(markBefore)) markAfter=\(Self.epoch(podcast.lastSeenPubDate)) intended=\(applyOutcome.insertedCount)"
                        )
                        resultByInputIndex[inputIndex] = RefreshProgress(
                            feedURL: url,
                            podcastTitle: title,
                            notificationEnabled: podcast.notificationEnabled ?? false,
                            outcome: applyOutcome.refreshOutcome
                        )
                        pendingByInputIndex[inputIndex] = applyOutcome
                        sinceLastSave += 1
                        let shouldFlushFirstContent = !postedIncrementalInboxChange
                            && applyOutcome.insertedCount > 0
                        if shouldFlushFirstContent || sinceLastSave >= Self.saveBatchSize {
                            let checkpoint = flushPending()
                            if !checkpoint.results.isEmpty {
                                await onCheckpoint(checkpoint.results)
                            }
                            if checkpoint.madeNewContentDurable,
                               !postedIncrementalInboxChange {
                            // Surface the first durable new-content batch while a
                            // large library continues refreshing. Limit the whole
                            // run to this early signal plus the final signal below
                            // so Inbox reloads cannot become a per-batch hot path.
                            postedIncrementalInboxChange = true
                            await onInboxChange()
                            }
                        }
                    } catch {
                        modelContext.rollback()
                        failed += 1
                        recordFailure(
                            index: inputIndex,
                            feedURL: url,
                            title: title,
                            reason: "Could not process or save this feed."
                        )
                        AppLog.subscriptions.error(
                            "refresh=\(correlationID, privacy: .public) feed=\(feedID, privacy: .public) outcome=feed-failure error=\(Self.errorDetail(error), privacy: .public)"
                        )
                    }
                } else {
                    failed += 1
                    recordFailure(
                        index: inputIndex,
                        feedURL: url,
                        title: title,
                        reason: "Could not download or read this feed."
                    )
                    AppLog.subscriptions.error(
                        "refresh=\(correlationID, privacy: .public) feed=\(feedID, privacy: .public) outcome=fetch-failure error=\(Self.sanitized(fetched.errorDescription ?? "Unknown error"), privacy: .public)"
                    )
                }
                completed += 1
                await onProgress(completed, total)

                if isCancelled() {
                    AppLog.subscriptions.info(
                        "refreshAll stopped early (cancelled) after \(completed) of \(total)"
                    )
                    break refreshLoop
                }
        }
        await pipeline.channel.finish()
        pipeline.producer.cancel()
        _ = await pipeline.producer.value
        let finalCheckpoint = flushPending()
        if !finalCheckpoint.results.isEmpty {
            await onCheckpoint(finalCheckpoint.results)
        }
        let report = RefreshRun(
            results: resultByInputIndex.keys.sorted().compactMap { resultByInputIndex[$0] },
            failures: failuresByInputIndex.keys.sorted().compactMap { failuresByInputIndex[$0] },
            attempted: completed,
            total: total,
            failed: failed,
            cancelled: completed < total,
            intendedInsertions: intendedInsertions,
            durableInsertions: durableInsertions
        )
        // Reconcile the final durable state even if an early batch was already
        // surfaced. A run emits at most two Inbox changes: first durable content
        // and final completion, never one notification per save batch (#736).
        await onInboxChange()
        AppLog.subscriptions.info(
            "refresh=\(correlationID, privacy: .public) summary trigger=\(trigger.rawValue, privacy: .public) attempted=\(report.attempted) total=\(report.total) succeeded=\(report.results.count) failed=\(report.failed) cancelled=\(report.cancelled) intendedInsertions=\(report.intendedInsertions) durableInsertions=\(report.durableInsertions)"
        )
        return report
    }

    /// Refreshes a single podcast (resolved by feed URL) on the background context.
    /// Used by the single-feed call site (`EpisodeListView`) so its writes also
    /// stay off the main actor. Returns nil if the URL no longer resolves.
    func refreshOne(
        feedURL: String, feed: FeedFetching, autoQueueEnabled: Bool
    ) async throws -> RefreshOutcome? {
        let canonical = FeedURLIdentity.canonical(feedURL)
        guard let podcast = try PodcastIdentityService(context: modelContext)
            .existingFollowed(feedURL: canonical)
        else { return nil }
        let parsed = try await feed.fetch(canonical)
        let repairGUIDs = ordinaryRefreshCandidates(
            from: Self.deduplicatedEpisodes(parsed.episodes),
            podcast: podcast,
            now: .now
        ).map(\.guid)
        let repair = try IdentityRepairService(context: modelContext)
            .repairEpisodes(in: podcast, matchingGUIDs: repairGUIDs)
        if repair.didChange { try saveWithSignpost() }
        let applyOutcome = apply(parsed, to: podcast, autoQueueEnabled: autoQueueEnabled)
        // Save BEFORE resolving `newEpisodeIDs` — persistentModelID is temporary
        // for a newly-inserted Episode until the context saves (same reason
        // `subscribe(feedURL:feed:inboxSeedCount:)` above saves before `result()`).
        try saveIfNeeded()
        return applyOutcome.result()
    }

    /// Inserts the next missing historical page without ever classifying it as
    /// new Inbox content. Re-fetching and scanning the feed makes the operation
    /// restartable: a cancellation or failed save leaves no cursor to corrupt,
    /// and the next attempt resumes from durable GUID identity.
    func loadOlderEpisodes(
        feedURL: String,
        feed: FeedFetching,
        pageSize: Int = 10
    ) async throws -> OlderEpisodePageOutcome? {
        let canonical = FeedURLIdentity.canonical(feedURL)
        guard let podcast = try PodcastIdentityService(context: modelContext)
            .existingFollowed(feedURL: canonical)
        else { return nil }

        guard pageSize > 0 else {
            return OlderEpisodePageOutcome(inserted: 0, hasMore: true)
        }
        let parsed = try await feed.fetch(canonical)
        try Task.checkCancellation()
        let catalog = Self.deduplicatedEpisodes(parsed.episodes)
            .enumerated()
            .sorted { lhs, rhs in
                let leftDate = lhs.element.pubDate ?? .distantPast
                let rightDate = rhs.element.pubDate ?? .distantPast
                return leftDate == rightDate ? lhs.offset < rhs.offset : leftDate > rightDate
            }
            .map(\.element)

        var missing: [ParsedEpisode] = []
        for start in stride(
            from: 0,
            to: catalog.count,
            by: Self.olderEpisodeIdentityChunkSize
        ) {
            try Task.checkCancellation()
            let end = min(start + Self.olderEpisodeIdentityChunkSize, catalog.count)
            let chunk = Array(catalog[start..<end])
            let existingGUIDs = Set(
                episodes(in: podcast, matchingGUIDs: chunk.map(\.guid)).map(\.guid)
            )
            for item in chunk where !existingGUIDs.contains(item.guid) {
                missing.append(item)
                if missing.count > pageSize { break }
            }
            if missing.count > pageSize { break }
        }

        let page = missing.prefix(pageSize)
        guard !page.isEmpty else {
            return OlderEpisodePageOutcome(inserted: 0, hasMore: false)
        }
        let repair = try IdentityRepairService(context: modelContext)
            .repairEpisodes(in: podcast, matchingGUIDs: page.map(\.guid))
        if repair.didChange { try saveWithSignpost() }

        var inserted = 0
        let existingAfterRepair = Set(
            episodes(in: podcast, matchingGUIDs: page.map(\.guid)).map(\.guid)
        )
        for item in page where !existingAfterRepair.contains(item.guid) {
            let episode = Self.makeEpisode(from: item)
            episode.podcast = podcast
            episode.inboxDismissed = true
            modelContext.insert(episode)
            inserted += 1
        }
        try saveIfNeeded()
        return OlderEpisodePageOutcome(
            inserted: inserted,
            hasMore: missing.count > pageSize
        )
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
    func subscribe(
        feedURL: String,
        feed: FeedFetching,
        inboxSeedCount: Int,
        maximumFollowedCount: Int? = nil
    ) async throws -> SubscribeResult {
        let canonical = FeedURLIdentity.canonical(feedURL)
        let parsed = try await feed.fetch(canonical)
        try Task.checkCancellation()
        let prepared = PreparedSubscription(
            inputIndex: 0, feedURL: canonical, parsed: parsed, initialEpisodeLimit: nil
        )
        let committed = try await commitPreparedBatch(
            [prepared], inboxSeedCount: inboxSeedCount,
            maximumFollowedCount: maximumFollowedCount,
            capBehavior: .throwError
        )
        guard let result = committed.results.first else {
            throw SubscriptionError.podcastNotFoundAfterSubscribe
        }
        return result.result
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
        isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled },
        onProgress: (@MainActor @Sendable (_ completed: Int, _ total: Int, _ currentTitle: String?) -> Void)? = nil
    ) async -> [SubscribeResult] {
        await subscribeAllReport(
            feedURLs: feedURLs, feed: feed, inboxSeedCount: inboxSeedCount,
            maximumFollowedCount: nil, isCancelled: isCancelled,
            onProgress: onProgress
        ).results
    }

    func subscribeAllReport(
        feedURLs: [String],
        feed: FeedFetching,
        inboxSeedCount: Int,
        maximumFollowedCount: Int?,
        isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled },
        onProgress: (@MainActor @Sendable (_ completed: Int, _ total: Int, _ currentTitle: String?) -> Void)? = nil
    ) async -> BulkSubscribeReport {
        let total = feedURLs.count
        var resultByIndex: [Int: SubscribeResult] = [:]
        var skippedForCap = 0
        var failed = 0
        var mutated = false
        var completed = 0

        let identity = PodcastIdentityService(context: modelContext)
        let existing = (try? identity.existingAnyStateByCanonicalFeedURL(for: feedURLs)) ?? [:]
        var candidates: [(Int, String)] = []
        for (index, rawURL) in feedURLs.enumerated() {
            guard !isCancelled() else { break }
            let url = FeedURLIdentity.canonical(rawURL)
            if let podcast = existing[url], podcast.isFollowed {
                do {
                    if let confirmed = try await confirmedExistingSubscription(
                        feedURL: url
                    ) {
                        resultByIndex[index] = confirmed.result
                        completed += 1
                        await onProgress?(completed, total, confirmed.title)
                    } else {
                        candidates.append((index, url))
                    }
                } catch is CancellationError {
                    break
                } catch {
                    failed += 1
                    completed += 1
                    await onProgress?(completed, total, nil)
                }
            } else {
                candidates.append((index, url))
            }
        }
        let fetchChunkSize = max(Self.subscribeFetchConcurrency, Self.subscribeSaveBatchSize)
        var nextCandidate = 0
        while nextCandidate < candidates.count {
            guard !isCancelled() else { break }
            let remaining = Array(candidates[nextCandidate...])
            let capacitySnapshot: BulkCapacitySnapshot
            do {
                capacitySnapshot = try await authoritativeBulkCapacitySnapshot(
                    feedURLs: remaining.map { $0.1 },
                    maximumFollowedCount: maximumFollowedCount
                )
            } catch is CancellationError {
                break
            } catch {
                failed += remaining.count
                break
            }
            var stillNeedsFetch: [(Int, String)] = []
            for candidate in remaining {
                if let confirmed = capacitySnapshot.followed[candidate.1] {
                    resultByIndex[candidate.0] = confirmed.result
                    completed += 1
                    await onProgress?(completed, total, confirmed.title)
                } else {
                    stillNeedsFetch.append(candidate)
                }
            }
            candidates.replaceSubrange(nextCandidate..., with: stillNeedsFetch)
            guard nextCandidate < candidates.count, !isCancelled() else { break }

            let availableSlots = capacitySnapshot.availableSlots
            guard availableSlots > 0 else {
                skippedForCap += candidates.count - nextCandidate
                break
            }
            let end = min(
                nextCandidate + min(fetchChunkSize, availableSlots), candidates.count
            )
            let chunk = Array(candidates[
                nextCandidate..<end
            ])
            nextCandidate = end
            await withTaskGroup(of: PreparedFetchResult.self) { group in
                for (index, url) in chunk {
                    group.addTask {
                        guard let parsed = await Self.fetchForImport(url, feed: feed) else {
                            return .failure(index)
                        }
                        return .success(PreparedSubscription(
                            inputIndex: index, feedURL: url, parsed: parsed,
                            initialEpisodeLimit: Self.opmlInitialEpisodeLimit
                        ))
                    }
                }
                // Fetches finish out of order, but only a contiguous input-order
                // prefix may consume cap slots or publish durable progress.
                var resolved: [Int: PreparedFetchResult] = [:]
                var applyOffset = 0
                for await fetched in group {
                    resolved[fetched.inputIndex] = fetched
                    while applyOffset < chunk.count,
                          let first = resolved[chunk[applyOffset].0] {
                        if case let .failure(index) = first {
                            resolved.removeValue(forKey: index)
                            applyOffset += 1
                            failed += 1
                            completed += 1
                            await onProgress?(completed, total, nil)
                            continue
                        }
                        var applyBatch: [PreparedSubscription] = []
                        while applyOffset < chunk.count,
                              applyBatch.count < Self.subscribeSaveBatchSize,
                              let ready = resolved[chunk[applyOffset].0],
                              case let .success(input) = ready {
                            resolved.removeValue(forKey: input.inputIndex)
                            applyBatch.append(input)
                            applyOffset += 1
                        }
                        do {
                            let commit = try await commitPreparedBatch(
                                applyBatch, inboxSeedCount: inboxSeedCount,
                                maximumFollowedCount: maximumFollowedCount,
                                capBehavior: .skip
                            )
                            for indexed in commit.results {
                                resultByIndex[indexed.inputIndex] = indexed.result
                            }
                            skippedForCap += commit.skippedForCap
                            mutated = mutated || commit.mutated
                        } catch is CancellationError {
                            group.cancelAll()
                            return
                        } catch {
                            var unresolvedFailures = 0
                            for input in applyBatch {
                                do {
                                    if let confirmed = try await confirmedExistingSubscription(
                                        feedURL: input.feedURL
                                    ) {
                                        resultByIndex[input.inputIndex] = confirmed.result
                                    } else {
                                        unresolvedFailures += 1
                                    }
                                } catch { unresolvedFailures += 1 }
                            }
                            failed += unresolvedFailures
                            AppLog.subscriptions.error(
                                "OPML import batch failed: \(error.localizedDescription, privacy: .public)"
                            )
                        }
                        for input in applyBatch {
                            completed += 1
                            let title = resultByIndex[input.inputIndex].flatMap { result in
                                (try? PodcastIdentityService(context: modelContext)
                                    .existingAnyState(feedURL: result.feedURL))?.title
                            }
                            await onProgress?(completed, total, title)
                        }
                    }
                }
            }
        }

        return BulkSubscribeReport(
            results: resultByIndex.keys.sorted().compactMap { resultByIndex[$0] },
            skippedForCap: skippedForCap, failed: failed,
            mutated: mutated
        )
    }

    private static func fetchForImport(_ url: String, feed: FeedFetching) async -> ParsedFeed? {
        await withTaskGroup(of: ParsedFeed?.self) { group in
            group.addTask { try? await feed.fetch(url) }
            group.addTask {
                try? await Task.sleep(for: Self.subscribeFetchTimeout)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    private struct PreparedSubscription: Sendable {
        let inputIndex: Int
        let feedURL: String
        let parsed: ParsedFeed
        let initialEpisodeLimit: Int?
    }

    private enum PreparedFetchResult: Sendable {
        case success(PreparedSubscription)
        case failure(Int)

        var inputIndex: Int {
            switch self {
            case let .success(input): input.inputIndex
            case let .failure(index): index
            }
        }
    }

    private struct IndexedSubscribeResult {
        let inputIndex: Int
        let result: SubscribeResult
    }

    private struct CommittedBatch {
        let results: [IndexedSubscribeResult]
        let skippedForCap: Int
        let mutated: Bool
    }

    private enum CapBehavior { case throwError, skip }

    private struct BulkCapacitySnapshot {
        let followed: [String: (result: SubscribeResult, title: String)]
        let availableSlots: Int
    }

    private func authoritativeBulkCapacitySnapshot(
        feedURLs: [String],
        maximumFollowedCount: Int?
    ) async throws -> BulkCapacitySnapshot {
        await SubscriptionCapacityWriteGate.shared.acquire()
        if Task.isCancelled {
            await SubscriptionCapacityWriteGate.shared.release()
            throw CancellationError()
        }
        await PodcastIdentityWriteGate.shared.acquire(feedURLs: feedURLs)
        do {
            try Task.checkCancellation()
            if !modelContext.hasChanges { modelContext.rollback() }
            let identity = PodcastIdentityService(context: modelContext)
            let current = try identity.existingAnyStateByCanonicalFeedURL(for: feedURLs)
            var followed: [String: (result: SubscribeResult, title: String)] = [:]
            for feedURL in feedURLs {
                guard let podcast = current[feedURL], podcast.isFollowed else { continue }
                let outcome = SubscribeOutcome(
                    podcast: podcast, episodes: [], alreadySubscribed: true
                )
                followed[feedURL] = (outcome.result(), podcast.title)
            }
            let availableSlots = if let maximumFollowedCount {
                max(0, maximumFollowedCount - (try PodcastQuery.followedCount(in: modelContext)))
            } else {
                Int.max
            }
            await PodcastIdentityWriteGate.shared.release(feedURLs: feedURLs)
            await SubscriptionCapacityWriteGate.shared.release()
            return BulkCapacitySnapshot(
                followed: followed, availableSlots: availableSlots
            )
        } catch {
            await PodcastIdentityWriteGate.shared.release(feedURLs: feedURLs)
            await SubscriptionCapacityWriteGate.shared.release()
            throw error
        }
    }

    private func confirmedExistingSubscription(
        feedURL: String
    ) async throws -> (result: SubscribeResult, title: String)? {
        await PodcastIdentityWriteGate.shared.acquire(feedURLs: [feedURL])
        do {
            try Task.checkCancellation()
            if !modelContext.hasChanges { modelContext.rollback() }
            guard let podcast = try PodcastIdentityService(context: modelContext)
                .existingFollowed(feedURL: feedURL) else {
                await PodcastIdentityWriteGate.shared.release(feedURLs: [feedURL])
                return nil
            }
            let result = SubscribeOutcome(
                podcast: podcast, episodes: [], alreadySubscribed: true
            ).result()
            let title = podcast.title
            await PodcastIdentityWriteGate.shared.release(feedURLs: [feedURL])
            return (result, title)
        } catch {
            modelContext.rollback()
            await PodcastIdentityWriteGate.shared.release(feedURLs: [feedURL])
            throw error
        }
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

        /// `SubscribeResult.episodeIDs` is consumed ONLY by the auto-download
        /// pass, which keeps just the newest `autoDownloadCount` (UI max 10) per
        /// podcast. Capping the IDs here — on the actor, where the episodes are
        /// already in memory and cheap to sort — means the main context resolves
        /// at most this many episodes per feed instead of re-fetching every
        /// episode of every imported feed one-by-one. That per-episode main-actor
        /// resolution storm is what stalled and spiked memory on a large OPML
        /// import (the build-150 332-feed crash, #696).
        static let autoDownloadIDCap = 10

        func result() -> SubscribeResult {
            let recentIDs = episodes
                .sorted { ($0.pubDate ?? .distantPast) > ($1.pubDate ?? .distantPast) }
                .prefix(Self.autoDownloadIDCap)
                .map(\.persistentModelID)
            return SubscribeResult(
                feedURL: podcast.feedURL,
                podcastID: podcast.persistentModelID,
                episodeIDs: Array(recentIDs),
                alreadySubscribed: alreadySubscribed
            )
        }
    }

    private func commitPreparedBatch(
        _ prepared: [PreparedSubscription],
        inboxSeedCount: Int,
        maximumFollowedCount: Int?,
        capBehavior: CapBehavior
    ) async throws -> CommittedBatch {
        guard !prepared.isEmpty else {
            return CommittedBatch(results: [], skippedForCap: 0, mutated: false)
        }
        let feedURLs = prepared.map(\.feedURL)

        try await repairSubscriptionIdentities(feedURLs: feedURLs)

        await SubscriptionCapacityWriteGate.shared.acquire()
        if Task.isCancelled {
            await SubscriptionCapacityWriteGate.shared.release()
            throw CancellationError()
        }
        await PodcastIdentityWriteGate.shared.acquire(feedURLs: feedURLs)
        do {
            try Task.checkCancellation()
            if !modelContext.hasChanges { modelContext.rollback() }
            let identity = PodcastIdentityService(context: modelContext)
            var followedCount = try PodcastQuery.followedCount(in: modelContext)
            var staged: [(Int, SubscribeOutcome)] = []
            var skippedForCap = 0
            var mutated = false

            for input in prepared.sorted(by: { $0.inputIndex < $1.inputIndex }) {
                if let followed = try identity.existingFollowed(feedURL: input.feedURL) {
                    staged.append((input.inputIndex, SubscribeOutcome(
                        podcast: followed, episodes: [], alreadySubscribed: true
                    )))
                    continue
                }
                if let maximumFollowedCount, followedCount >= maximumFollowedCount {
                    if capBehavior == .throwError {
                        throw SubscriptionError.podcastCapReached(
                            currentCount: followedCount, limit: maximumFollowedCount
                        )
                    }
                    skippedForCap += 1
                    continue
                }
                let outcome = try stageSubscription(
                    input, inboxSeedCount: inboxSeedCount
                )
                staged.append((input.inputIndex, outcome))
                followedCount += 1
                mutated = true
            }

            try saveIfNeeded()
            let results = staged.map {
                IndexedSubscribeResult(inputIndex: $0.0, result: $0.1.result())
            }
            let refreshedFeedURLs = staged.compactMap {
                $0.1.alreadySubscribed ? nil : $0.1.podcast.feedURL
            }
            await PodcastIdentityWriteGate.shared.release(feedURLs: feedURLs)
            await SubscriptionCapacityWriteGate.shared.release()
            stampRefreshedAtBestEffort(feedURLs: refreshedFeedURLs)
            return CommittedBatch(
                results: results, skippedForCap: skippedForCap, mutated: mutated
            )
        } catch {
            modelContext.rollback()
            await PodcastIdentityWriteGate.shared.release(feedURLs: feedURLs)
            await SubscriptionCapacityWriteGate.shared.release()
            throw error
        }
    }

    private func repairSubscriptionIdentities(feedURLs: [String]) async throws {
        await PodcastIdentityWriteGate.shared.acquire(feedURLs: feedURLs)
        do {
            try Task.checkCancellation()
            if !modelContext.hasChanges { modelContext.rollback() }
            let report = try IdentityRepairService(context: modelContext)
                .repair(feedURLs: feedURLs)
            if report.didChange { try saveIfNeeded() }
            await PodcastIdentityWriteGate.shared.release(feedURLs: feedURLs)
        } catch {
            modelContext.rollback()
            await PodcastIdentityWriteGate.shared.release(feedURLs: feedURLs)
            throw error
        }
    }

    private func stageSubscription(
        _ input: PreparedSubscription,
        inboxSeedCount: Int
    ) throws -> SubscribeOutcome {
        let canonical = FeedURLIdentity.canonical(input.feedURL)
        let parsed = input.parsed
        let parsedEpisodes = Self.initialSubscriptionEpisodes(
            parsed.episodes, limit: input.initialEpisodeLimit
        )
        let identity = PodcastIdentityService(context: modelContext)
        let resolved = try identity.fetchOrCreate(feedURL: canonical) { feedURL in
            Podcast(feedURL: feedURL, title: parsed.title.isEmpty ? "Untitled podcast" : parsed.title)
        }
        let podcast = resolved.podcast
        podcast.feedURL = canonical
        podcast.subscriptionStateRaw = nil
        if !parsed.title.isEmpty { podcast.title = parsed.title }
        if let value = parsed.author { podcast.author = value }
        if let value = parsed.description { podcast.podcastDescription = value }
        if let value = parsed.artworkURL { podcast.artworkURL = value }
        if let value = parsed.websiteURL { podcast.websiteURL = value }
        if let value = parsed.language { podcast.language = value }
        if let value = parsed.category { podcast.category = value }
        if podcast.inboxMaxEpisodes == nil,
           let savedCap = storedInboxCap(forFeedURL: canonical) {
            podcast.inboxMaxEpisodes = savedCap
        }

        var existingByGUID: [String: Episode] = [:]
        for start in stride(from: 0, to: parsedEpisodes.count, by: Self.olderEpisodeIdentityChunkSize) {
            let end = min(start + Self.olderEpisodeIdentityChunkSize, parsedEpisodes.count)
            for episode in try targetedEpisodes(
                in: podcast, matchingGUIDs: parsedEpisodes[start..<end].map(\.guid)
            ) where existingByGUID[episode.guid] == nil {
                existingByGUID[episode.guid] = episode
            }
        }
        var inserted: [Episode] = []
        for item in parsedEpisodes {
            if let episode = existingByGUID[item.guid] {
                Self.mergeFeedMetadata(item, into: episode)
            } else {
                let episode = Self.makeEpisode(from: item)
                episode.podcast = podcast
                episode.inboxDismissed = true
                modelContext.insert(episode)
                existingByGUID[item.guid] = episode
                inserted.append(episode)
            }
        }
        let now = Date.now
        seedInbox(
            inserted, seedCount: inboxSeedCount,
            perPodcastCap: podcast.inboxMaxEpisodes, now: now
        )
        if let latest = Self.latestNonFuturePubDate(parsedEpisodes, now: now) {
            podcast.lastSeenPubDate = [podcast.lastSeenPubDate, latest].compactMap { $0 }.max()
        } else if podcast.lastSeenPubDate == nil {
            podcast.lastSeenPubDate = now
        }
        try PendingCloudUnfollowIntent.clear(feedURL: canonical, in: modelContext)
        try PendingCloudRemoteActivationIntent.clear(feedURL: canonical, in: modelContext)
        try PendingCloudFollowIntent.set(feedURL: canonical, in: modelContext)
        AppLog.subscriptions.info(
            "Subscribed to \(podcast.title, privacy: .public) with \(parsedEpisodes.count) feed episodes"
        )
        return SubscribeOutcome(
            podcast: podcast, episodes: inserted, alreadySubscribed: false
        )
    }

    private func stampRefreshedAtBestEffort(feedURLs: [String]) {
        guard !feedURLs.isEmpty else { return }
        let now = Date.now
        do {
            let identity = PodcastIdentityService(context: modelContext)
            for feedURL in feedURLs {
                if let podcast = try identity.existingFollowed(feedURL: feedURL) {
                    LocalStateStore.setRefreshedAt(now, on: podcast, in: modelContext)
                }
            }
            if modelContext.hasChanges { try saveWithSignpost() }
        } catch {
            modelContext.rollback()
            AppLog.subscriptions.error(
                "Subscription refreshed-state save failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private static func initialSubscriptionEpisodes(
        _ episodes: [ParsedEpisode], limit: Int?
    ) -> [ParsedEpisode] {
        let complete = deduplicatedEpisodes(episodes)
        guard let limit else { return complete }
        return Array(complete.sorted {
            ($0.pubDate ?? .distantPast) > ($1.pubDate ?? .distantPast)
        }.prefix(limit))
    }

    private static func mergeFeedMetadata(_ item: ParsedEpisode, into episode: Episode) {
        if !item.title.isEmpty { episode.title = item.title }
        if !item.audioURL.isEmpty { episode.audioURL = item.audioURL }
        if let value = item.description { episode.episodeDescription = value }
        if let value = item.durationSeconds { episode.durationSeconds = value }
        if let value = item.pubDate { episode.pubDate = value }
        if let value = item.artworkURL { episode.artworkURL = value }
        if let value = item.episodeNumber { episode.episodeNumber = value }
        if let value = item.seasonNumber { episode.seasonNumber = value }
        if let value = item.chapterURL { episode.chapterURL = value }
        if let value = item.transcriptURL { episode.transcriptURL = value }
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
        guard let raw = AppSettingIdentity.value(for: key, in: modelContext),
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
        let inboxReentryEpisodes: [Episode]
        let insertedCount: Int

        func result() -> RefreshOutcome {
            var outcome = refreshOutcome
            outcome.newEpisodeIDs = newEpisodes.map(\.persistentModelID)
            outcome.inboxReentryEpisodeIDs = inboxReentryEpisodes.map(\.persistentModelID)
            return outcome
        }
    }

    private struct OrdinaryCandidateSelection {
        let candidates: [ParsedEpisode]
        let filteredGUIDs: Set<String>
        let totalNewCount: Int
        let keptCountBeforeLimit: Int
        let filteredCountBeforeLimit: Int
        let warnsWhenAllFiltered: Bool

        var rejectedAllNewCandidates: Bool {
            warnsWhenAllFiltered && totalNewCount > 0
                && keptCountBeforeLimit == 0 && filteredCountBeforeLimit > 0
        }

        var keptOverflowCount: Int {
            max(0, keptCountBeforeLimit - FeedRefreshActor.ordinaryRefreshNewEpisodeLimit)
        }

        var filteredOverflowCount: Int {
            max(0, filteredCountBeforeLimit - FeedRefreshActor.ordinaryRefreshFilteredEpisodeLimit)
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
        // A malformed feed can contain the same natural key more than once in a
        // single response. Deduplicate before any insert: a snapshot of the
        // already-persisted GUIDs cannot protect against two new rows in this
        // same unsaved batch (#778).
        let parsedEpisodes = Self.deduplicatedEpisodes(parsed.episodes)

        // First refresh of a freshly-migrated shell (no episodes AND no mark):
        // backfill the whole catalog pre-dismissed and seed the mark. Guarded on
        // episodes.isEmpty so a normally-subscribed podcast never takes this path.
        let hasStoredEpisodes = hasEpisodes(for: podcast)
        if !hasStoredEpisodes && podcast.lastSeenPubDate == nil {
            for item in parsedEpisodes {
                let episode = Self.makeEpisode(from: item)
                episode.podcast = podcast
                episode.inboxDismissed = true
                modelContext.insert(episode)
            }
            podcast.lastSeenPubDate = Self.latestNonFuturePubDate(parsedEpisodes, now: now) ?? now
            LocalStateStore.setRefreshedAt(now, on: podcast, in: modelContext)
            AppLog.subscriptions.info("Backfilled \(podcast.title, privacy: .public): \(parsedEpisodes.count) episode(s)")
            // Backfilled/pre-existing catalog episodes must NOT trigger
            // auto-download, matching the existing `wasBackfill` notification gate.
            return ApplyOutcome(
                refreshOutcome: .backfill,
                newEpisodes: [],
                inboxReentryEpisodes: [],
                insertedCount: parsedEpisodes.count
            )
        }

        // Compact CloudKit synchronization deliberately transfers subscription
        // metadata without the refetchable episode catalog. Such a podcast has a
        // high-water mark copied from the source device but no episodes locally.
        // Running the ordinary diff over the full feed would eagerly rebuild an
        // unbounded history; inserting none would leave a clean second device
        // with an unusable empty podcast. Seed only the newest ten. Rows at or
        // before the transferred mark are backlog and stay dismissed; genuinely
        // newer rows retain the normal Inbox/notification semantics.
        if !hasStoredEpisodes, podcast.lastSeenPubDate != nil {
            return seedSyncedShell(
                from: parsedEpisodes,
                podcast: podcast,
                autoQueueEnabled: autoQueueEnabled,
                now: now
            )
        }

        // Clamp an already-future mark back to now so a previously-poisoned mark
        // can't keep real new episodes out of the inbox (#296).
        let mark = min(podcast.lastSeenPubDate ?? .distantPast, now)
        // Automatic refresh is not a historical-catalog rebuild. Keep only the
        // newest ten genuinely-new, non-future publications. This preserves all
        // existing history while bounding relationship maintenance for feeds
        // whose GUID format or retained catalog has changed.
        let selection = ordinaryRefreshSelection(
            from: parsedEpisodes,
            podcast: podcast,
            now: now
        )
        let candidateEpisodes = selection.candidates
        let existingEpisodes = episodes(
            in: podcast,
            matchingGUIDs: candidateEpisodes.map(\.guid)
        )
        let existingGUIDs = Set(existingEpisodes.map(\.guid))
        // Gate matches the former `podcast.autoQueue && queue != nil`: with no
        // queue capability, an autoQueue podcast's new episodes go to the inbox.
        let autoQueueOn = podcast.autoQueue && autoQueueEnabled
        var added = 0
        var autoQueued: [Episode] = []
        var newestNewGUID: String?
        var newestNewPub = Date.distantPast
        var newEpisodes: [Episode] = []
        var filtered = 0

        // Lookup by guid for the republish pass below (#397), built once instead
        // of a per-item linear scan.
        let existingByGUID = Dictionary(
            existingEpisodes.map { ($0.guid, $0) }, uniquingKeysWith: { first, _ in first }
        )
        let inboxReentries = resurfaceRepublished(
            candidateEpisodes.filter { !selection.filteredGUIDs.contains($0.guid) },
            existingByGUID: existingByGUID,
            now: now
        )

        for item in candidateEpisodes where !existingGUIDs.contains(item.guid) {
            let episode = Self.makeEpisode(from: item)
            episode.podcast = podcast
            if selection.filteredGUIDs.contains(item.guid) {
                // Version 1's filtered outcome is deliberately reversible using
                // the existing Library row action: retain a normal new episode,
                // but keep it out of both Inbox and auto-queue.
                episode.inboxDismissed = true
                modelContext.insert(episode)
                filtered += 1
                continue
            }
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

        if selection.keptCountBeforeLimit > Self.ordinaryRefreshNewEpisodeLimit
            || selection.filteredCountBeforeLimit > Self.ordinaryRefreshFilteredEpisodeLimit {
            AppLog.subscriptions.info(
                "Refresh insertion budget for \(podcast.title, privacy: .public): kept=\(selection.keptCountBeforeLimit) filtered=\(selection.filteredCountBeforeLimit)"
            )
        }
        if selection.rejectedAllNewCandidates {
            let key = SettingsKey.episodeFilterSafetyWarning(feedURL: podcast.feedURL)
            try? LocalAppSettingIdentity.setValue(
                "\(now.timeIntervalSince1970)|\(selection.totalNewCount)",
                for: key,
                in: modelContext
            )
            AppLog.subscriptions.error(
                "Episode filters excluded all \(selection.totalNewCount) new candidate(s) for \(podcast.title, privacy: .public)"
            )
        }

        // Advance the mark to the newest non-future pub date; never retreat, never
        // to a future date (#296).
        podcast.lastSeenPubDate = max(mark, Self.latestNonFuturePubDate(parsedEpisodes, now: now) ?? mark)
        LocalStateStore.setRefreshedAt(now, on: podcast, in: modelContext)

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
            refreshOutcome: RefreshOutcome(
                added: added,
                wasBackfill: false,
                newestNewEpisodeGUID: newestNewGUID,
                filteredCount: filtered,
                rejectedAllNewCandidates: selection.rejectedAllNewCandidates,
                keptOverflowCount: selection.keptOverflowCount,
                filteredOverflowCount: selection.filteredOverflowCount
            ),
            newEpisodes: newEpisodes,
            inboxReentryEpisodes: inboxReentries,
            insertedCount: added + filtered
        )
    }

    private func hasEpisodes(for podcast: Podcast) -> Bool {
        let podcastID = podcast.persistentModelID
        let descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate { $0.podcast?.persistentModelID == podcastID }
        )
        return ((try? modelContext.fetchCount(descriptor)) ?? 0) > 0
    }

    private func ordinaryRefreshCandidates(
        from parsedEpisodes: [ParsedEpisode],
        podcast: Podcast,
        now: Date
    ) -> [ParsedEpisode] {
        ordinaryRefreshSelection(from: parsedEpisodes, podcast: podcast, now: now).candidates
    }

    private func ordinaryRefreshSelection(
        from parsedEpisodes: [ParsedEpisode],
        podcast: Podcast,
        now: Date
    ) -> OrdinaryCandidateSelection {
        let mark = min(podcast.lastSeenPubDate ?? .distantPast, now)
        let allNew = parsedEpisodes
            .filter {
                let pub = $0.pubDate ?? .distantPast
                return pub > mark && pub <= now
            }
            .sorted { ($0.pubDate ?? .distantPast) > ($1.pubDate ?? .distantPast) }
        let raw = AppSettingIdentity.value(
            for: SettingsKey.episodeFilterConfiguration(feedURL: podcast.feedURL),
            in: modelContext
        )
        let configuration = EpisodeFilterCodec.decode(raw)
        guard configuration.isActiveAtIngest else {
            return OrdinaryCandidateSelection(
                candidates: Array(allNew.prefix(Self.ordinaryRefreshNewEpisodeLimit)),
                filteredGUIDs: [],
                totalNewCount: allNew.count,
                keptCountBeforeLimit: allNew.count,
                filteredCountBeforeLimit: 0,
                warnsWhenAllFiltered: false
            )
        }
        let kept = allNew.filter {
            configuration.shouldKeep(title: $0.title, durationSeconds: $0.durationSeconds)
        }
        let filtered = allNew.filter {
            !configuration.shouldKeep(title: $0.title, durationSeconds: $0.durationSeconds)
        }
        let selectedKept = kept.prefix(Self.ordinaryRefreshNewEpisodeLimit)
        let selectedFiltered = filtered.prefix(Self.ordinaryRefreshFilteredEpisodeLimit)
        let selected = (Array(selectedKept) + Array(selectedFiltered)).sorted {
            ($0.pubDate ?? .distantPast) > ($1.pubDate ?? .distantPast)
        }
        return OrdinaryCandidateSelection(
            candidates: selected,
            filteredGUIDs: Set(selectedFiltered.map(\.guid)),
            totalNewCount: allNew.count,
            keptCountBeforeLimit: kept.count,
            filteredCountBeforeLimit: filtered.count,
            warnsWhenAllFiltered: configuration.mode == .keepMatching
        )
    }

    /// Fetch only rows that can participate in this refresh. In particular, do
    /// not fault `podcast.episodes`: the real device has one 45,436-row inverse
    /// relationship, and materializing it caused the build-178 hang samples.
    private func targetedEpisodes(
        in podcast: Podcast, matchingGUIDs guids: [String]
    ) throws -> [Episode] {
        guard !guids.isEmpty else { return [] }
        let podcastID = podcast.persistentModelID
        let descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate {
                $0.podcast?.persistentModelID == podcastID && guids.contains($0.guid)
            }
        )
        return try modelContext.fetch(descriptor)
    }

    private func episodes(in podcast: Podcast, matchingGUIDs guids: [String]) -> [Episode] {
        (try? targetedEpisodes(in: podcast, matchingGUIDs: guids)) ?? []
    }

    private func seedSyncedShell(
        from parsedEpisodes: [ParsedEpisode],
        podcast: Podcast,
        autoQueueEnabled: Bool,
        now: Date
    ) -> ApplyOutcome {
        let mark = min(podcast.lastSeenPubDate ?? .distantPast, now)
        let selection = ordinaryRefreshSelection(
            from: parsedEpisodes,
            podcast: podcast,
            now: now
        )
        let selectedNewGUIDs = Set(selection.candidates.map(\.guid))
        let backlogFillCount = max(
            0, Self.syncedShellInitialEpisodeLimit - selection.candidates.count
        )
        let backlog = parsedEpisodes
            .filter { !selectedNewGUIDs.contains($0.guid) }
            .sorted { ($0.pubDate ?? .distantPast) > ($1.pubDate ?? .distantPast) }
            .prefix(backlogFillCount)
        let seed = (selection.candidates + Array(backlog)).sorted {
            ($0.pubDate ?? .distantPast) > ($1.pubDate ?? .distantPast)
        }
        let autoQueueOn = podcast.autoQueue && autoQueueEnabled
        var genuinelyNew: [Episode] = []
        var autoQueued: [Episode] = []
        var newestNewGUID: String?
        var newestNewPub = Date.distantPast
        var filtered = 0

        for item in seed {
            let episode = Self.makeEpisode(from: item)
            episode.podcast = podcast
            let pub = item.pubDate ?? .distantPast
            let isNewEpisode = pub > mark && pub <= now
            if isNewEpisode, selection.filteredGUIDs.contains(item.guid) {
                episode.inboxDismissed = true
                modelContext.insert(episode)
                filtered += 1
                continue
            }
            episode.inboxDismissed = !isNewEpisode || autoQueueOn
            modelContext.insert(episode)
            if isNewEpisode {
                genuinelyNew.append(episode)
                if pub >= newestNewPub {
                    newestNewPub = pub
                    newestNewGUID = episode.guid
                }
                if autoQueueOn { autoQueued.append(episode) }
            }
        }

        podcast.lastSeenPubDate = max(
            mark,
            Self.latestNonFuturePubDate(parsedEpisodes, now: now) ?? mark
        )
        LocalStateStore.setRefreshedAt(now, on: podcast, in: modelContext)
        if !autoQueued.isEmpty {
            enqueueAtEnd(autoQueued)
            enforceQueueCap(for: podcast)
        }
        if selection.rejectedAllNewCandidates {
            let key = SettingsKey.episodeFilterSafetyWarning(feedURL: podcast.feedURL)
            try? LocalAppSettingIdentity.setValue(
                "\(now.timeIntervalSince1970)|\(selection.totalNewCount)",
                for: key,
                in: modelContext
            )
            AppLog.subscriptions.error(
                "Episode filters excluded all \(selection.totalNewCount) new candidate(s) while seeding \(podcast.title, privacy: .public)"
            )
        }
        AppLog.subscriptions.info(
            "Seeded synced subscription \(podcast.title, privacy: .public) with \(seed.count) recent episode(s); \(genuinelyNew.count) genuinely new"
        )
        return ApplyOutcome(
            refreshOutcome: RefreshOutcome(
                added: genuinelyNew.count,
                wasBackfill: false,
                newestNewEpisodeGUID: newestNewGUID,
                filteredCount: filtered,
                rejectedAllNewCandidates: selection.rejectedAllNewCandidates,
                keptOverflowCount: selection.keptOverflowCount,
                filteredOverflowCount: selection.filteredOverflowCount
            ),
            newEpisodes: genuinelyNew,
            inboxReentryEpisodes: [],
            insertedCount: seed.count
        )
    }

    /// Collapses duplicate natural keys inside one parsed response before the
    /// actor creates any `Episode` objects. Prefer the newest publication date;
    /// for equal dates, use a complete stable payload signature so reversing the
    /// feed's item order still selects the same row.
    private static func deduplicatedEpisodes(_ episodes: [ParsedEpisode]) -> [ParsedEpisode] {
        var order: [String] = []
        var winnerByGUID: [String: ParsedEpisode] = [:]
        for episode in episodes {
            guard let current = winnerByGUID[episode.guid] else {
                order.append(episode.guid)
                winnerByGUID[episode.guid] = episode
                continue
            }
            let candidateDate = episode.pubDate ?? .distantPast
            let currentDate = current.pubDate ?? .distantPast
            if candidateDate > currentDate
                || (candidateDate == currentDate
                    && stableSignature(for: episode) < stableSignature(for: current)) {
                winnerByGUID[episode.guid] = episode
            }
        }
        return order.compactMap { winnerByGUID[$0] }
    }

    private static func stableSignature(for episode: ParsedEpisode) -> String {
        let separator = "\u{1F}"
        return [
            episode.audioURL,
            episode.title,
            episode.description ?? "",
            episode.artworkURL ?? "",
            episode.durationSeconds.map(String.init) ?? "",
            episode.episodeNumber.map(String.init) ?? "",
            episode.seasonNumber.map(String.init) ?? "",
            episode.chapterURL ?? "",
            episode.transcriptURL ?? "",
            episode.episodeType ?? "",
        ].joined(separator: separator)
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
    ) -> [Episode] {
        var resurfaced: [Episode] = []
        for item in items {
            guard let existing = existingByGUID[item.guid] else { continue }
            guard let newPub = item.pubDate, newPub <= now else { continue }
            let storedPub = existing.pubDate ?? .distantPast
            guard newPub > storedPub else { continue }
            guard existing.status != .played, existing.queueItem == nil else { continue }

            existing.pubDate = newPub
            existing.status = .newEpisode
            existing.inboxDismissed = false
            resurfaced.append(existing)
        }
        return resurfaced
    }

    /// Appends episodes to the end of the queue on the background context. Mirrors
    /// `QueueRepository.add` (idempotent per episode; status -> .inQueue; dense
    /// positions) without depending on the @MainActor repository.
    private func enqueueAtEnd(_ episodes: [Episode]) {
        let descriptor = FetchDescriptor<QueueItem>(sortBy: [SortDescriptor(\.position)])
        var items = ((try? modelContext.fetch(descriptor)) ?? []).filter { $0.episode != nil }
        var stagedFollowedAddition = false
        for episode in episodes where episode.queueItem == nil {
            stagedFollowedAddition = PendingCloudQueueMutation.stageMembership(
                episode: episode,
                isQueued: true,
                in: modelContext
            ) || stagedFollowedAddition
            let item = QueueItem(episode: episode, position: items.count)
            modelContext.insert(item)
            episode.status = .inQueue
            items.append(item)
        }
        if stagedFollowedAddition {
            PendingCloudQueueMutation.stageOrdering(in: modelContext)
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

        var stagedFollowedRemoval = false
        for item in queued where evictIDs.contains(item.persistentModelID) {
            // Dequeue only: keep the episode in the library, dismissed as
            // auto-queue left it, so it neither floods the inbox nor is deleted.
            if let episode = item.episode {
                stagedFollowedRemoval = PendingCloudQueueMutation.stageMembership(
                    episode: episode,
                    isQueued: false,
                    in: modelContext
                ) || stagedFollowedRemoval
                episode.status = .newEpisode
            }
            modelContext.delete(item)
        }
        if stagedFollowedRemoval {
            PendingCloudQueueMutation.stageOrdering(in: modelContext)
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
        guard let stored = LocalAppSettingIdentity.value(for: key, in: modelContext),
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

    private func saveIfNeeded() throws {
        guard modelContext.hasChanges else { return }
#if DEBUG
        if forcedSaveFailuresForTesting > 0 {
            forcedSaveFailuresForTesting -= 1
            throw NSError(
                domain: "FeedRefreshActor.ForcedSaveFailure", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Forced save failure for testing"]
            )
        }
#endif
        try saveWithSignpost()
    }

    private func saveWithSignpost() throws {
        let saveInterval = PerformanceSignposts.signposter.beginInterval("PersistenceSave")
        defer {
            PerformanceSignposts.signposter.endInterval("PersistenceSave", saveInterval)
        }
        try modelContext.save()
    }

    @discardableResult
    private func saveIfNeededOrLog(
        correlationID: String? = nil,
        batchIndex: Int? = nil,
        feedCount: Int = 0,
        intendedInsertions: Int = 0
    ) -> Bool {
        do {
            try saveIfNeeded()
            if let correlationID, let batchIndex {
                AppLog.subscriptions.info(
                    "refresh=\(correlationID, privacy: .public) batch=\(batchIndex) feeds=\(feedCount) save=success durableInsertions=\(intendedInsertions)"
                )
            }
            return true
        } catch {
            if let correlationID, let batchIndex {
                AppLog.subscriptions.error(
                    "refresh=\(correlationID, privacy: .public) batch=\(batchIndex) feeds=\(feedCount) save=failure intendedInsertions=\(intendedInsertions) error=\(Self.errorDetail(error), privacy: .public)"
                )
            } else {
                AppLog.subscriptions.error(
                    "Feed refresh save failed: \(Self.errorDetail(error), privacy: .public)"
                )
            }
            modelContext.rollback()
            return false
        }
    }

    private static func availableCapacityForImportantUsage() -> Int64 {
        let directory = ModelContainerFactory.storeURL.deletingLastPathComponent()
        return (try? directory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage) ?? -1
    }

    private static func opaqueFeedID(_ feedURL: String, salt: String) -> String {
        var hasher = Hasher()
        hasher.combine(salt)
        hasher.combine(FeedURLIdentity.canonical(feedURL))
        return String(UInt(bitPattern: hasher.finalize()), radix: 16)
    }

    private static func epoch(_ date: Date?) -> Int64 {
        guard let date else { return -1 }
        return Int64(date.timeIntervalSince1970)
    }

    private static func errorDetail(_ error: Error, depth: Int = 0) -> String {
        let nsError = error as NSError
        var pieces = [
            "\(nsError.domain)(\(nsError.code)): \(sanitized(nsError.localizedDescription))"
        ]
        guard depth < 4 else { return pieces.joined(separator: " | ") }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            pieces.append("underlying=\(errorDetail(underlying, depth: depth + 1))")
        }
        if let detailed = nsError.userInfo["NSDetailedErrors"] as? [Error] {
            pieces.append(contentsOf: detailed.prefix(4).map {
                "detail=\(errorDetail($0, depth: depth + 1))"
            })
        }
        return pieces.joined(separator: " | ")
    }

    private static func sanitized(_ text: String) -> String {
        var value = text
        let patterns = [
            #"https?://[^\s]+"#,
            #"file://[^\s]+"#,
            #"/[A-Za-z0-9._~!$&'()*+,;=:@%/-]+"#,
            #"[0-9A-Fa-f]{8}-[0-9A-Fa-f-]{27,}"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(value.startIndex..., in: value)
            value = regex.stringByReplacingMatches(
                in: value, range: range, withTemplate: "<redacted>"
            )
        }
        return value
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
