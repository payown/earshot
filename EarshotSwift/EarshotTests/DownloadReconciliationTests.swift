import XCTest
@testable import Earshot

/// Verifies the launch reconciliation logic that resets downloads stranded at
/// `.downloading` by an app kill (#544), updated for composite task keys (#576):
/// each episode is identified by BOTH its composite `"feedURL|guid"` key (what
/// post-#576 builds write as `taskDescription`) and its bare guid (what earlier
/// builds wrote), and counts as live when EITHER matches a live task.
final class DownloadReconciliationTests: XCTestCase {

    private func identity(_ feedURL: String, _ guid: String) -> (composite: String, bare: String) {
        (composite: "\(feedURL)|\(guid)", bare: guid)
    }

    func testOrphansAreThoseWithoutALiveTask() {
        // Acceptance criterion: #576 — indices of episodes with no live task.
        let orphans = DownloadReconciliation.orphanedIndices(
            markedDownloading: [
                identity("https://f", "a"),
                identity("https://f", "b"),
                identity("https://f", "c"),
            ],
            liveTaskKeys: ["https://f|b"])
        XCTAssertEqual(orphans, [0, 2])
    }

    func testLegacyBareGuidTaskDescriptionStillCountsAsLive() {
        // Acceptance criterion: #576 backward compat — a transfer enqueued by a
        // pre-#576 build carries a BARE guid as its taskDescription. The episode
        // must still count as live (not be reset to .failed) when only that bare
        // form matches.
        let orphans = DownloadReconciliation.orphanedIndices(
            markedDownloading: [identity("https://feed.example/rss", "ep-1")],
            liveTaskKeys: ["ep-1"])
        XCTAssertTrue(orphans.isEmpty,
                      "A live pre-update bare-guid task must protect its episode from reset")
    }

    func testNoneOrphanedWhenEveryDownloadHasALiveTask() {
        // Mixed live forms: one matched by composite, one by bare legacy guid.
        XCTAssertTrue(
            DownloadReconciliation.orphanedIndices(
                markedDownloading: [identity("https://f", "a"), identity("https://f", "b")],
                liveTaskKeys: ["https://f|a", "b"]).isEmpty)
    }

    func testAllOrphanedWhenNoLiveTasks() {
        XCTAssertEqual(
            DownloadReconciliation.orphanedIndices(
                markedDownloading: [identity("https://f", "a"), identity("https://f", "b")],
                liveTaskKeys: []),
            [0, 1])
    }

    func testEmptyMarkedSetYieldsNoOrphans() {
        XCTAssertTrue(
            DownloadReconciliation.orphanedIndices(
                markedDownloading: [], liveTaskKeys: ["a"]).isEmpty)
    }

    func testIndicesFollowMarkedInputOrder() {
        let orphans = DownloadReconciliation.orphanedIndices(
            markedDownloading: [
                identity("https://f", "c"),
                identity("https://f", "a"),
                identity("https://f", "b"),
            ],
            liveTaskKeys: ["a"])
        XCTAssertEqual(orphans, [0, 2], "Positions track the caller's array, in order")
    }

    func testDuplicateKeysYieldDistinctIndices() {
        // Two episodes that (defensively) share the same keys must each be
        // reported — returning indices instead of keys prevents conflation.
        let orphans = DownloadReconciliation.orphanedIndices(
            markedDownloading: [identity("https://f", "dup"), identity("https://f", "dup")],
            liveTaskKeys: [])
        XCTAssertEqual(orphans, [0, 1])
    }
}
