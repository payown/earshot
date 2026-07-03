import XCTest
@testable import Earshot

/// Verifies the launch reconciliation logic that resets downloads stranded at
/// `.downloading` by an app kill (#544).
final class DownloadReconciliationTests: XCTestCase {
    func testOrphansAreThoseWithoutALiveTask() {
        let orphans = DownloadReconciliation.orphanedGUIDs(
            markedDownloading: ["a", "b", "c"], liveTaskGUIDs: ["b"])
        XCTAssertEqual(orphans.sorted(), ["a", "c"])
    }

    func testNoneOrphanedWhenEveryDownloadHasALiveTask() {
        XCTAssertTrue(
            DownloadReconciliation.orphanedGUIDs(
                markedDownloading: ["a", "b"], liveTaskGUIDs: ["a", "b"]).isEmpty)
    }

    func testAllOrphanedWhenNoLiveTasks() {
        XCTAssertEqual(
            DownloadReconciliation.orphanedGUIDs(
                markedDownloading: ["a", "b"], liveTaskGUIDs: []).sorted(),
            ["a", "b"])
    }

    func testEmptyMarkedSetYieldsNoOrphans() {
        XCTAssertTrue(
            DownloadReconciliation.orphanedGUIDs(
                markedDownloading: [], liveTaskGUIDs: ["a"]).isEmpty)
    }

    func testPreservesOrderOfMarkedInput() {
        XCTAssertEqual(
            DownloadReconciliation.orphanedGUIDs(
                markedDownloading: ["c", "a", "b"], liveTaskGUIDs: ["a"]),
            ["c", "b"])
    }
}
