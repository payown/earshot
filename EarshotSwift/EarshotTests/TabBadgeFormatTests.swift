import XCTest
@testable import Earshot

/// Unit tests for the Inbox tab badge formatting. Pure functions, no tab bar.
/// These back the native `UITabBarItem.badgeValue` (visible bubble) and
/// `accessibilityValue` (VoiceOver) so the count announces exactly once.
final class TabBadgeFormatTests: XCTestCase {

    // MARK: badgeText (the visible red bubble)

    func testBadgeTextZeroIsNil() {
        XCTAssertNil(TabBadgeFormat.badgeText(0))
    }

    func testBadgeTextNegativeIsNil() {
        XCTAssertNil(TabBadgeFormat.badgeText(-1))
    }

    func testBadgeTextOne() {
        XCTAssertEqual(TabBadgeFormat.badgeText(1), "1")
    }

    func testBadgeTextMany() {
        XCTAssertEqual(TabBadgeFormat.badgeText(5), "5")
    }

    // MARK: truncated (bounded candidate query hit InboxBadge.cap) — #699

    func testBadgeTextTruncatedAppendsPlus() {
        XCTAssertEqual(TabBadgeFormat.badgeText(500, truncated: true), "500+")
    }

    func testBadgeTextTruncatedRespectsActualCount() {
        // inbox(from:) may filter the capped candidate set below the cap; the "+"
        // still signals "at least this many", not the cap literal.
        XCTAssertEqual(TabBadgeFormat.badgeText(480, truncated: true), "480+")
    }

    func testBadgeTextNotTruncatedHasNoPlus() {
        XCTAssertEqual(TabBadgeFormat.badgeText(500, truncated: false), "500")
    }

    func testBadgeTextTruncatedZeroStillNil() {
        // Defensive: no bubble when there's nothing to show, cap flag notwithstanding.
        XCTAssertNil(TabBadgeFormat.badgeText(0, truncated: true))
    }
}
