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

    func testWorkflowGuideShipsOfflineWithUniqueReadableSections() {
        let sections = WorkflowGuideSection.bundled
        XCTAssertGreaterThanOrEqual(sections.count, 7, "The canonical guide must be bundled with the app")
        XCTAssertEqual(Set(sections.map(\.id)).count, sections.count)
        XCTAssertTrue(sections.allSatisfy { !$0.paragraphs.isEmpty })
        XCTAssertTrue(sections.flatMap(\.paragraphs).contains { $0.contains("Read download status") })
        XCTAssertTrue(sections.flatMap(\.paragraphs).contains { $0.contains("Download N episodes") })
    }
}
