import XCTest
@testable import Earshot

final class ListDetailLayoutPolicyTests: XCTestCase {
    func testPanesFollowAvailableWindowWidth() {
        XCTAssertFalse(ListDetailLayoutPolicy.usesTwoPanes(width: 390, accessibilityText: false))
        XCTAssertFalse(ListDetailLayoutPolicy.usesTwoPanes(width: 760, accessibilityText: false))
        XCTAssertTrue(ListDetailLayoutPolicy.usesTwoPanes(width: 951, accessibilityText: false))
        XCTAssertFalse(ListDetailLayoutPolicy.usesTwoPanes(width: 951, accessibilityText: true))
        XCTAssertTrue(ListDetailLayoutPolicy.usesTwoPanes(width: 1_200, accessibilityText: true))
    }
}
