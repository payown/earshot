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

/// Unit tests for ``MarkAllPlayedConfirmationCopy``, the confirmation
/// dialog's title and message wording (#640). SwiftUI's `confirmationDialog`
/// itself has no unit-test precedent anywhere in this app (Unfollow and
/// Clear-inbox aren't tested either) — this covers only the pure string
/// generation the dialog displays, matching the existing bar for pure-logic
/// extraction rather than inventing new UI-interaction test infrastructure.
final class MarkAllPlayedConfirmationCopyTests: XCTestCase {

    // MARK: Title

    // Acceptance criterion: confirmation step before bulk-marking
    func testTitleSingular() {
        XCTAssertEqual(
            MarkAllPlayedConfirmationCopy.title(unplayedCount: 1),
            "Mark all 1 episode as played?"
        )
    }

    // Acceptance criterion: confirmation step before bulk-marking
    func testTitlePlural() {
        XCTAssertEqual(
            MarkAllPlayedConfirmationCopy.title(unplayedCount: 2),
            "Mark all 2 episodes as played?"
        )
    }

    // Acceptance criterion: confirmation step before bulk-marking
    func testTitleLargeCountIsCommaGrouped() {
        XCTAssertEqual(
            MarkAllPlayedConfirmationCopy.title(unplayedCount: 1204),
            "Mark all 1,204 episodes as played?"
        )
    }

    // MARK: Message

    // Acceptance criterion: confirmation step before bulk-marking
    func testMessageSingularNamesThePodcast() {
        XCTAssertEqual(
            MarkAllPlayedConfirmationCopy.message(unplayedCount: 1, podcastTitle: "Radiolab"),
            "This marks all 1 unplayed episode in Radiolab as played. This can't be undone."
        )
    }

    // Acceptance criterion: confirmation step before bulk-marking
    func testMessagePluralNamesThePodcast() {
        XCTAssertEqual(
            MarkAllPlayedConfirmationCopy.message(unplayedCount: 2, podcastTitle: "Radiolab"),
            "This marks all 2 unplayed episodes in Radiolab as played. This can't be undone."
        )
    }

    // Acceptance criterion: confirmation step before bulk-marking
    func testMessageLargeCountIsCommaGrouped() {
        XCTAssertEqual(
            MarkAllPlayedConfirmationCopy.message(unplayedCount: 1204, podcastTitle: "Radiolab"),
            "This marks all 1,204 unplayed episodes in Radiolab as played. This can't be undone."
        )
    }
}
