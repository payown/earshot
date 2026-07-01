import XCTest
@testable import Earshot

/// Pure rules for hiding/restoring Quick Actions (#524). No SwiftData, no view.
final class QuickActionVisibilityLogicTests: XCTestCase {
    private let ordered = ["a", "b", "c"]

    func testVisibleKeysDropsHiddenAndKeepsOrder() {
        XCTAssertEqual(
            QuickActionVisibilityLogic.visibleKeys(ordered: ordered, hidden: ["b"]),
            ["a", "c"]
        )
    }

    func testVisibleKeysWithNothingHiddenReturnsAll() {
        XCTAssertEqual(
            QuickActionVisibilityLogic.visibleKeys(ordered: ordered, hidden: []),
            ordered
        )
    }

    func testDefaultKeyIsFirstVisible() {
        XCTAssertEqual(
            QuickActionVisibilityLogic.defaultKey(ordered: ordered, hidden: []),
            "a"
        )
    }

    func testDefaultKeyRecomputesWhenFirstIsHidden() {
        XCTAssertEqual(
            QuickActionVisibilityLogic.defaultKey(ordered: ordered, hidden: ["a"]),
            "b"
        )
    }

    func testCanHideNonLastVisibleIsAllowed() {
        XCTAssertTrue(QuickActionVisibilityLogic.canHide("a", ordered: ordered, hidden: []))
        XCTAssertTrue(QuickActionVisibilityLogic.canHide("a", ordered: ordered, hidden: ["b"]))
    }

    func testCanHideLastVisibleIsRefused() {
        // Only "c" remains visible; hiding it would empty the set.
        XCTAssertFalse(
            QuickActionVisibilityLogic.canHide("c", ordered: ordered, hidden: ["a", "b"])
        )
    }

    func testCanHideAlreadyHiddenKeyIsRefused() {
        XCTAssertFalse(
            QuickActionVisibilityLogic.canHide("b", ordered: ordered, hidden: ["b"])
        )
    }

    func testCanHideUnknownKeyIsRefused() {
        XCTAssertFalse(
            QuickActionVisibilityLogic.canHide("zzz", ordered: ordered, hidden: [])
        )
    }

    func testCanRestoreOnlyWhenHidden() {
        XCTAssertTrue(QuickActionVisibilityLogic.canRestore("b", hidden: ["b"]))
        XCTAssertFalse(QuickActionVisibilityLogic.canRestore("a", hidden: ["b"]))
    }

    func testSingleActionSetCannotHideItsOnlyAction() {
        XCTAssertFalse(QuickActionVisibilityLogic.canHide("a", ordered: ["a"], hidden: []))
    }
}
