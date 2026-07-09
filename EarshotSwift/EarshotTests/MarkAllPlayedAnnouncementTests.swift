import XCTest
@testable import Earshot

/// Unit tests for the pure ``MarkAllPlayedAnnouncement`` VoiceOver wording
/// used by `EpisodeListView`'s bulk "Mark all as played" action (#640).
final class MarkAllPlayedAnnouncementTests: XCTestCase {

    func testSingular() {
        XCTAssertEqual(MarkAllPlayedAnnouncement.text(count: 1), "Marked 1 episode as played")
    }

    func testPlural() {
        XCTAssertEqual(MarkAllPlayedAnnouncement.text(count: 2), "Marked 2 episodes as played")
    }

    func testZeroIsPluralWording() {
        // Unreachable in production (the toolbar button and rotor action are
        // both gated on unplayedCount > 0), but the wording should still be
        // grammatically correct if it's ever hit.
        XCTAssertEqual(MarkAllPlayedAnnouncement.text(count: 0), "Marked 0 episodes as played")
    }

    func testLargeCountIsCommaGrouped() {
        XCTAssertEqual(MarkAllPlayedAnnouncement.text(count: 1204), "Marked 1,204 episodes as played")
    }

    func testVeryLargeCountIsCommaGrouped() {
        XCTAssertEqual(MarkAllPlayedAnnouncement.text(count: 1_000_000), "Marked 1,000,000 episodes as played")
    }
}
