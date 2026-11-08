import XCTest
@testable import Earshot

final class PlayerLayoutPolicyTests: XCTestCase {
    func testResizingAcrossTwoRegionBoundary() {
        XCTAssertFalse(PlayerLayoutPolicy.usesTwoRegions(width: 390))
        XCTAssertFalse(PlayerLayoutPolicy.usesTwoRegions(width: 699))
        XCTAssertTrue(PlayerLayoutPolicy.usesTwoRegions(width: 700))
        XCTAssertTrue(PlayerLayoutPolicy.usesTwoRegions(width: 900))
    }

    func testAccessibilityTextKeepsDetailsInCompactScrollWhenShort() {
        XCTAssertFalse(PlayerLayoutPolicy.separatesDetails(
            width: 390, height: 600, accessibilityText: true
        ))
        XCTAssertTrue(PlayerLayoutPolicy.separatesDetails(
            width: 390, height: 900, accessibilityText: true
        ))
        XCTAssertTrue(PlayerLayoutPolicy.separatesDetails(
            width: 900, height: 600, accessibilityText: true
        ))
    }
}
