import XCTest
import SwiftData
@testable import Earshot

final class DownloadStorageTextTests: XCTestCase {
    @MainActor
    func testCancelledSizeWaiterDoesNotThrottleOrDuplicateItsScan() async {
        let coordinator = DownloadStorageSizeCoordinator()
        var calls = 0
        var continuation: CheckedContinuation<Int64, Never>?
        let scan: @MainActor () async -> Int64 = {
            calls += 1
            return await withCheckedContinuation { continuation = $0 }
        }
        let first = Task { @MainActor in
            await coordinator.size(for: ["a.mp3"], scan: scan)
        }
        while continuation == nil { await Task.yield() }
        first.cancel()

        let finished = expectation(description: "replacement waiter finishes promptly")
        var secondResult: Int64?
        let second = Task { @MainActor in
            secondResult = await coordinator.size(for: ["a.mp3"], scan: scan)
            finished.fulfill()
        }
        await Task.yield()
        continuation?.resume(returning: 123)
        await fulfillment(of: [finished], timeout: 2)
        second.cancel()
        _ = await second.value
        let firstResult = await first.value
        XCTAssertNil(firstResult)
        XCTAssertEqual(secondResult, 123)
        XCTAssertEqual(calls, 1)
    }

    @MainActor
    func testChangedPathsRetryAfterCancelledWaiter() async {
        let coordinator = DownloadStorageSizeCoordinator()
        var calls = 0
        var continuation: CheckedContinuation<Int64, Never>?
        let retried = expectation(description: "changed paths start a fresh scan")
        let scan: @MainActor () async -> Int64 = {
            calls += 1
            if calls == 2 { retried.fulfill() }
            return await withCheckedContinuation { continuation = $0 }
        }
        let first = Task { @MainActor in
            await coordinator.size(for: ["old.mp3"], scan: scan)
        }
        while continuation == nil { await Task.yield() }
        first.cancel()
        let second = Task { @MainActor in
            await coordinator.size(for: ["new.mp3"], scan: scan)
        }
        await Task.yield()
        continuation?.resume(returning: 100)
        continuation = nil
        await fulfillment(of: [retried], timeout: 2)
        if let continuation { continuation.resume(returning: 200) }
        else { second.cancel() }
        let firstResult = await first.value
        let secondResult = await second.value
        XCTAssertNil(firstResult)
        XCTAssertEqual(secondResult, 200)
        XCTAssertEqual(calls, 2)
    }

    @MainActor
    func testForcedSizeRefreshDoesNotReuseScanStartedBeforeClear() async {
        let coordinator = DownloadStorageSizeCoordinator()
        coordinator.recordCompletedScan()
        var calls = 0
        var continuation: CheckedContinuation<Int64, Never>?
        let firstStarted = expectation(description: "first scan started")
        let secondStarted = expectation(description: "post-clear scan started")
        let scan: @MainActor () async -> Int64 = {
            calls += 1
            if calls == 1 { firstStarted.fulfill() } else { secondStarted.fulfill() }
            return await withCheckedContinuation { continuation = $0 }
        }
        let first = Task { @MainActor in
            await coordinator.size(for: ["same.mp3"], forceRequest: 1, scan: scan)
        }
        await fulfillment(of: [firstStarted], timeout: 2)
        first.cancel()
        let second = Task { @MainActor in
            await coordinator.size(for: ["same.mp3"], forceRequest: 2, scan: scan)
        }
        await Task.yield()
        continuation?.resume(returning: 100)
        continuation = nil
        await fulfillment(of: [secondStarted], timeout: 2)
        continuation?.resume(returning: 0)
        let firstResult = await first.value
        let secondResult = await second.value
        XCTAssertNil(firstResult)
        XCTAssertEqual(secondResult, 0)
        XCTAssertEqual(calls, 2)
    }

    @MainActor
    func testStorageSnapshotWaitersCoalesceAndRefreshAfterNewSave() async {
        let coordinator = DownloadStorageSnapshotCoordinator()
        var calls = 0
        var continuation: CheckedContinuation<DownloadStorageSnapshot?, Never>?
        let firstStarted = expectation(description: "first snapshot started")
        let secondStarted = expectation(description: "fresh snapshot started")
        let load: @MainActor () async -> DownloadStorageSnapshot? = {
            calls += 1
            if calls == 1 { firstStarted.fulfill() } else { secondStarted.fulfill() }
            return await withCheckedContinuation { continuation = $0 }
        }
        let firstRevision = coordinator.invalidate()
        let first = Task { @MainActor in await coordinator.snapshot(for: firstRevision, load: load) }
        await fulfillment(of: [firstStarted], timeout: 2)
        let secondRevision = coordinator.invalidate()
        let second = Task { @MainActor in await coordinator.snapshot(for: secondRevision, load: load) }
        await Task.yield()
        let old = DownloadStorageSnapshot(counts: .init(downloadedCount: 1, activeCount: 0),
                                          paths: ["old.mp3"], executedStoreWorkOnMainThread: false)
        continuation?.resume(returning: old)
        continuation = nil
        await fulfillment(of: [secondStarted], timeout: 2)
        let new = DownloadStorageSnapshot(counts: .init(downloadedCount: 2, activeCount: 0),
                                          paths: ["new.mp3"], executedStoreWorkOnMainThread: false)
        continuation?.resume(returning: new)
        let firstResult = await first.value
        let secondResult = await second.value
        XCTAssertNil(firstResult)
        XCTAssertEqual(secondResult, new)
        XCTAssertEqual(calls, 2)
    }

    @MainActor
    func testStorageSaveMetadataIgnoresPositionUpdatesButObservesMembershipChanges() throws {
        let context = TestStore.freshContext()
        let row = LocalEpisodeState(podcastFeedURL: "https://example.com/feed", episodeGUID: "one")
        let episode = Episode(guid: "one", title: "One", audioURL: "https://example.com/audio")
        context.insert(row)
        context.insert(episode)
        try context.save()
        for key in [ModelContext.NotificationKey.insertedIdentifiers, .updatedIdentifiers, .deletedIdentifiers] {
            let local = Notification(name: ModelContext.didSave, userInfo: [key.rawValue: [row.persistentModelID]])
            XCTAssertTrue(DownloadStorageChange.affectsSnapshot(local))
            let episodeSave = Notification(name: ModelContext.didSave, userInfo: [key.rawValue: [episode.persistentModelID]])
            XCTAssertEqual(DownloadStorageChange.affectsSnapshot(episodeSave), key != .updatedIdentifiers)
        }
    }

    func testClearConfirmationIncludesCountStorageAndActiveDownloads() {
        let text = DownloadStorageText.clearConfirmation(
            summary: DownloadStorageSummary(
                downloadedCount: 831,
                activeCount: 12,
                allocatedBytes: 2_000_000_000
            )
        )

        XCTAssertTrue(text.contains("831 downloaded episodes"))
        XCTAssertTrue(text.contains("12 active downloads"))
        XCTAssertTrue(text.contains("frees about"))
        XCTAssertTrue(text.contains("GB"))
        XCTAssertTrue(text.hasSuffix("This can't be undone."))
    }

    func testClearConfirmationOmitsUnavailableSizeAndZeroActivity() {
        XCTAssertEqual(
            DownloadStorageText.clearConfirmation(
                summary: DownloadStorageSummary(
                    downloadedCount: 1,
                    activeCount: 0,
                    allocatedBytes: 0
                )
            ),
            "This removes 1 downloaded episode from this device. This can't be undone."
        )
    }

    func testCancelConfirmationPromisesCompletedDownloadsAreKept() {
        XCTAssertEqual(
            DownloadStorageText.cancelConfirmation(activeCount: 831),
            "Stops 831 active downloads. Completed downloads are kept."
        )
    }

    func testClearConfirmationWithOnlyActiveDownloadsDoesNotSayZeroEpisodes() {
        XCTAssertEqual(
            DownloadStorageText.clearConfirmation(
                summary: DownloadStorageSummary(
                    downloadedCount: 0,
                    activeCount: 831,
                    allocatedBytes: 0
                )
            ),
            "This cancels 831 active downloads. This can't be undone."
        )
    }
}
