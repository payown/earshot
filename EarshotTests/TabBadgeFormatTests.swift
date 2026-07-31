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
}
