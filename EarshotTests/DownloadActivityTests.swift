import XCTest
import SwiftData
@testable import Earshot

@MainActor
final class DownloadActivityTests: XCTestCase {
    private func episodes(_ count: Int, context: ModelContext) throws -> [Episode] {
        let podcast = Podcast(feedURL: "https://activity.test/\(UUID().uuidString)", title: "Activity show")
        context.insert(podcast)
        let result = (0..<count).map { index in
            let episode = Episode(guid: "episode-\(index)", title: "Episode \(index)",
                                  audioURL: "https://activity.test/\(index).mp3")
            episode.podcast = podcast
            context.insert(episode)
            return episode
        }
        try context.save()
        return result
    }

    private func summary(_ context: ModelContext) throws -> DownloadActivitySummary {
        DownloadActivitySummary(records: DownloadActivityRecord.records(
            from: try context.fetch(FetchDescriptor<LocalEpisodeState>())
        ))
    }

    func testNineteenAcceptedRequestsRemainObservableThroughTerminalFailuresAndRetry() async throws {
        let context = TestStore.freshContext()
        let items = try episodes(19, context: context)
        var keys: [String] = []
        let manager = DownloadManager { _, key in keys.append(key) }
        manager.configureForTesting(context: context, isOnWifi: true)
        DownloadManager.setContainerForTesting(context.container)
        defer { DownloadManager.setContainerForTesting(nil) }

        let report = await manager.downloadAll(items)
        XCTAssertEqual(report.accepted, 19)
        XCTAssertEqual(report.downloading, 19)
        XCTAssertEqual(report.completed, 0)
        XCTAssertEqual(keys.count, 19)

        // The background callbacks arrive AFTER enrollment has returned. Nine
        // complete, six fail, and four remain transferring, matching the report.
        await Task.yield()
        for index in 0..<9 {
            let name = "activity-\(UUID().uuidString).mp3"
            let url = try DownloadPaths.downloadsDirectory().appendingPathComponent(name)
            try Data("audio fixture".utf8).write(to: url)
            addTeardownBlock { try? FileManager.default.removeItem(at: url) }
            DownloadManager.handle(PendingDownloadTerminalEvent(
                taskKey: keys[index], outcome: .finished(fileName: name)
            ))
        }
        for index in 9..<15 {
            DownloadManager.handle(PendingDownloadTerminalEvent(taskKey: keys[index], outcome: .failed))
        }
        var current = try summary(context)
        XCTAssertEqual(current.completed, 9)
        XCTAssertEqual(current.failed, 6)
        XCTAssertEqual(current.downloading, 4)
        XCTAssertEqual(current.waiting, 0)

        // Failed state survives a new context, rather than existing only in a
        // temporary progress view or the enrollment report.
        let reopened = ModelContext(context.container)
        XCTAssertEqual(try summary(reopened), current)

        let retry = await manager.downloadAll(items)
        XCTAssertEqual(retry.accepted, 6)
        XCTAssertEqual(retry.skipped, 13)
        XCTAssertEqual(keys.count, 25)
        current = try summary(context)
        XCTAssertEqual(current.completed, 9)
        XCTAssertEqual(current.failed, 0)
        XCTAssertEqual(current.downloading, 10)
    }

    func testWifiWaitingIsNotReportedAsTransferringAndResumesOnlyOnce() async throws {
        let context = TestStore.freshContext()
        let items = try episodes(19, context: context)
        var transfers = 0
        let manager = DownloadManager { _, _ in transfers += 1 }
        manager.configureForTesting(context: context, isOnWifi: false)
        let report = await manager.downloadAll(items)
        XCTAssertEqual(report.accepted, 19)
        XCTAssertEqual(report.waitingForWifi, 19)
        XCTAssertEqual(report.downloading, 0)
        XCTAssertEqual(transfers, 0)
        XCTAssertEqual(try summary(context).waiting, 19)

        manager.configureForTesting(context: context, isOnWifi: true)
        await manager.startPendingDownloads()
        await manager.startPendingDownloads()
        await manager.download(items[0])
        XCTAssertEqual(transfers, 19, "Repeated calls must not duplicate active transfers")
        XCTAssertEqual(try summary(context).downloading, 19)
        manager.configureForTesting(context: context, isOnWifi: false)
        await manager.download(items[0])
        XCTAssertEqual(items[0].downloadStatus, .downloading, "A duplicate request cannot park an existing transfer")
    }

    func testCancelledEnrollmentDoesNotStartTransfersOrLoseDeferredCount() async throws {
        let context = TestStore.freshContext()
        let items = try episodes(60, context: context)
        let manager = DownloadManager { _, _ in XCTFail("Cancelled enrollment must not start transfers") }
        manager.configureForTesting(context: context, isOnWifi: true)
        let task = Task { await manager.downloadAll(items) }
        task.cancel()
        let report = await task.value
        XCTAssertTrue(report.wasCancelled)
        XCTAssertEqual(report.accepted, 0)
        XCTAssertEqual(report.deferred, 10)
        XCTAssertTrue(report.announcement.contains("cancelled before requesting 50"))
        XCTAssertTrue(items.allSatisfy { $0.downloadStatus == .none })
    }

    func testRetryBatchCapsTransfersAndSkipsActiveAndCompletedItems() async throws {
        let context = TestStore.freshContext()
        let items = try episodes(65, context: context)
        for episode in items { ActiveDownload.setDownloadStatus(.failed, on: episode, in: context) }
        ActiveDownload.setDownloadStatus(.downloading, on: items[0], in: context)
        ActiveDownload.setDownloadStatus(.pending, on: items[1], in: context)
        LocalStateStore.setDownloadPath("existing.mp3", on: items[2], in: context)
        ActiveDownload.setDownloadStatus(.downloaded, on: items[2], in: context)
        var transfers = 0
        let manager = DownloadManager { _, _ in transfers += 1 }
        manager.configureForTesting(context: context, isOnWifi: true)
        let report = await manager.downloadAll(items)
        XCTAssertEqual(transfers, 50)
        XCTAssertEqual(report.accepted, 50)
        XCTAssertEqual(report.skipped, 3)
        XCTAssertEqual(report.deferred, 12)
        XCTAssertEqual(try summary(context).failed, 12)
    }

    func testInvalidMediaURLsFailWithoutCreatingTransfers() async throws {
        let context = TestStore.freshContext()
        let items = try episodes(3, context: context)
        for (episode, url) in zip(items, ["", "relative.mp3", "file:///tmp/audio.mp3"]) {
            episode.audioURL = url
        }
        let manager = DownloadManager { _, _ in XCTFail("Invalid media must not create a URLSession task") }
        manager.configureForTesting(context: context, isOnWifi: true)
        let report = await manager.downloadAll(items)
        XCTAssertEqual(report.failed, 3)
        XCTAssertEqual(report.accepted, 0)
        XCTAssertEqual(try summary(context).failed, 3)
    }

    func testCompletedCountExcludesMissingPathsAndUnrequestedSettingsRows() {
        let rows = [
            LocalEpisodeState(podcastFeedURL: "https://test/feed", episodeGUID: "a", downloadStatus: .downloaded),
            LocalEpisodeState(podcastFeedURL: "https://test/feed", episodeGUID: "b", volumeBoost: .off),
            LocalEpisodeState(podcastFeedURL: "https://test/feed", episodeGUID: "c", downloadStatus: .pending),
        ]
        let result = DownloadActivitySummary(records: DownloadActivityRecord.records(from: rows))
        XCTAssertEqual(result.completed, 0)
        XCTAssertEqual(result.waiting, 1)
        XCTAssertEqual(result.failed, 0)
    }

    func testSnapshotHandlesLargeLibraryDuplicatesNamesAndPaginationOffMain() async throws {
        let context = TestStore.freshContext()
        let first = Podcast(feedURL: "https://activity.test/a", title: "Original")
        let second = Podcast(feedURL: "https://activity.test/b", title: "Other",
                             subscriptionStateRaw: PodcastSubscriptionState.catalogOnly.rawValue)
        context.insert(first)
        context.insert(second)
        for index in 0..<300 {
            let guid = String(format: "episode-%04d", index)
            let episode = Episode(guid: guid, title: "A \(index)", audioURL: "https://activity.test/a.mp3")
            episode.podcast = first
            context.insert(episode)
            context.insert(LocalEpisodeState(podcastFeedURL: first.feedURL, episodeGUID: guid,
                                             downloadStatus: index < 200 ? .failed : .downloaded,
                                             downloadPath: index < 200 ? nil : "audio.mp3"))
        }
        let sameGUID = Episode(guid: "episode-0000", title: "B zero", audioURL: "https://activity.test/b.mp3")
        sameGUID.podcast = second
        context.insert(sameGUID)
        context.insert(LocalEpisodeState(podcastFeedURL: second.feedURL, episodeGUID: sameGUID.guid,
                                         downloadStatus: .pending))
        // A duplicate must not alter counts or consume a page slot.
        context.insert(LocalEpisodeState(podcastFeedURL: first.feedURL, episodeGUID: "episode-0000",
                                         downloadStatus: .failed))
        context.insert(LocalEpisodeState(podcastFeedURL: first.feedURL, episodeGUID: "missing-file",
                                         downloadStatus: .downloaded))
        try context.save()
        let names = [EpisodeLocalKey(feedURL: first.feedURL, guid: "").feedURL: "Personal Name",
                     EpisodeLocalKey(feedURL: second.feedURL, guid: "").feedURL: "Ignored Name"]
        let snapshot = try await DownloadActivitySnapshotLoader.load(
            container: context.container, showCompleted: false, limit: 50, podcastNames: names
        )
        XCTAssertFalse(snapshot.executedStoreWorkOnMainThread)
        XCTAssertEqual(snapshot.summary.failed, 200)
        XCTAssertEqual(snapshot.summary.completed, 100)
        XCTAssertEqual(snapshot.summary.waiting, 1)
        XCTAssertEqual(snapshot.visibleCount, 201)
        XCTAssertEqual(snapshot.entries.count, 50)
        XCTAssertEqual(snapshot.failedKeys.count, 50)
        XCTAssertEqual(snapshot.entries.first?.title, "A 0")
        XCTAssertEqual(snapshot.entries.first?.podcast, "Personal Name")
        let all = try await DownloadActivitySnapshotLoader.load(
            container: context.container, showCompleted: true, limit: 500, podcastNames: names
        )
        XCTAssertEqual(all.visibleCount, 301)
        XCTAssertEqual(all.entries.count, 301)
        XCTAssertEqual(all.entries.last?.title, "B zero")
        XCTAssertEqual(all.entries.last?.podcast, "Other")
    }

    func testSnapshotRefreshSeesOtherContextSavesAndHonorsCancellation() async throws {
        let context = TestStore.freshContext()
        let items = try episodes(1, context: context)
        let key = try XCTUnwrap(LocalStateStore.key(for: items[0]))
        context.insert(LocalEpisodeState(podcastFeedURL: key.feedURL, episodeGUID: key.guid,
                                         downloadStatus: .pending))
        try context.save()
        let first = try await DownloadActivitySnapshotLoader.load(
            container: context.container, showCompleted: false, limit: 50, podcastNames: [:]
        )
        XCTAssertEqual(first.summary.waiting, 1)
        let other = ModelContext(context.container)
        let row = try XCTUnwrap(other.fetch(FetchDescriptor<LocalEpisodeState>()).first)
        row.downloadStatus = .failed
        try other.save()
        let updated = try await DownloadActivitySnapshotLoader.load(
            container: context.container, showCompleted: false, limit: 50, podcastNames: [:]
        )
        XCTAssertEqual(updated.summary.failed, 1)
        XCTAssertEqual(updated.entries.first?.status, .failed)
        let cancelled = Task {
            try await DownloadActivitySnapshotLoader.load(
                container: context.container, showCompleted: false, limit: 50, podcastNames: [:]
            )
        }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("Cancelled snapshot must not return a result")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testOlderRefreshCannotReplaceNewerSnapshot() async throws {
        let context = TestStore.freshContext()
        let gate = ActivitySnapshotGate()
        let controller = DownloadActivityLoadController { _, _, limit, _ in
            if limit == 1 { await gate.pause() }
            var summary = DownloadActivitySummary(records: [])
            summary.failed = limit
            return DownloadActivitySnapshot(summary: summary, entries: [], failedKeys: [],
                                            visibleCount: 0, executedStoreWorkOnMainThread: false)
        }
        controller.schedule(container: context.container, showCompleted: false, limit: 1,
                            names: [:], immediate: true)
        let first = try XCTUnwrap(controller.currentTaskForTesting())
        await gate.waitUntilStarted()
        controller.schedule(container: context.container, showCompleted: false, limit: 2,
                            names: [:], immediate: true)
        await controller.waitUntilIdle()
        XCTAssertEqual(controller.snapshot?.summary.failed, 2)
        await gate.release()
        await first.value
        XCTAssertEqual(controller.snapshot?.summary.failed, 2)
    }

    func testDataRefreshesCoalesceWithoutStarvingInitialSnapshot() async throws {
        let context = TestStore.freshContext()
        let gate = ActivityCoalescingGate()
        let controller = DownloadActivityLoadController { _, _, _, _ in
            let generation = await gate.pause()
            var summary = DownloadActivitySummary(records: [])
            summary.failed = generation
            return DownloadActivitySnapshot(summary: summary, entries: [], failedKeys: [],
                                            visibleCount: 0, executedStoreWorkOnMainThread: false)
        }
        controller.schedule(container: context.container, showCompleted: false, limit: 50,
                            names: [:], immediate: true)
        await gate.waitUntilStarted(1)
        for _ in 0..<20 {
            controller.schedule(container: context.container, showCompleted: false, limit: 50, names: [:])
        }
        await gate.release(1)
        await gate.waitUntilStarted(2)
        XCTAssertEqual(controller.snapshot?.summary.failed, 1, "The first read must publish despite ongoing saves")
        await gate.release(2)
        await controller.waitUntilIdle()
        XCTAssertEqual(controller.snapshot?.summary.failed, 2)
        let started = await gate.startedCount()
        XCTAssertEqual(started, 2, "Concurrent saves should coalesce into one follow-up")
    }

    func testFailedRefreshClearsPreviouslyActionableSnapshot() async throws {
        enum SnapshotFailure: Error { case failed }
        let context = TestStore.freshContext()
        let controller = DownloadActivityLoadController { _, _, limit, _ in
            if limit == 2 { throw SnapshotFailure.failed }
            var summary = DownloadActivitySummary(records: [])
            summary.failed = 1
            return DownloadActivitySnapshot(summary: summary, entries: [], failedKeys: [],
                                            visibleCount: 0, executedStoreWorkOnMainThread: false)
        }
        controller.schedule(container: context.container, showCompleted: false, limit: 1,
                            names: [:], immediate: true)
        await controller.waitUntilIdle()
        XCTAssertEqual(controller.snapshot?.summary.failed, 1)
        controller.schedule(container: context.container, showCompleted: false, limit: 2,
                            names: [:], immediate: true)
        await controller.waitUntilIdle()
        XCTAssertNil(controller.snapshot)
        XCTAssertEqual(controller.loadError, "Could not load download details. Reopen Download activity to try again.")
    }

    func testWorkflowGuideShipsOfflineWithUniqueReadableSections() {
        let sections = WorkflowGuideSection.bundled
        XCTAssertGreaterThanOrEqual(sections.count, 7, "The canonical guide must be bundled with the app")
        XCTAssertEqual(Set(sections.map(\.id)).count, sections.count)
        XCTAssertTrue(sections.allSatisfy { !$0.paragraphs.isEmpty })
        XCTAssertTrue(sections.flatMap(\.paragraphs).contains { $0.contains("Read the summary") })
        XCTAssertTrue(sections.flatMap(\.paragraphs).contains { $0.contains("Download N episodes") })
        XCTAssertTrue(sections.flatMap(\.paragraphs).contains {
            $0.contains("If Delete downloads when done is on, Clear inbox also removes those episodes' downloaded audio.")
        })
    }
}

private actor ActivitySnapshotGate {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func pause() async {
        started = true
        for waiter in startWaiters { waiter.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor ActivityCoalescingGate {
    private var started = 0
    private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var releases: [Int: CheckedContinuation<Void, Never>] = [:]

    func pause() async -> Int {
        started += 1
        let number = started
        let ready = startWaiters.filter { $0.0 <= number }
        startWaiters.removeAll { $0.0 <= number }
        for (_, continuation) in ready { continuation.resume() }
        await withCheckedContinuation { releases[number] = $0 }
        return number
    }

    func waitUntilStarted(_ number: Int) async {
        if started >= number { return }
        await withCheckedContinuation { startWaiters.append((number, $0)) }
    }

    func release(_ number: Int) {
        releases.removeValue(forKey: number)?.resume()
    }

    func startedCount() -> Int { started }
}
