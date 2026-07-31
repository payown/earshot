import XCTest
@testable import Earshot

/// Exercises ``TipJarDecisionLogic`` (#636) — pure mapping from a
/// ``RawPurchaseResult`` to the outcome the UI should show and whether the
/// underlying transaction should be finished. No StoreKit involved.
final class TipJarDecisionLogicTests: XCTestCase {
    // MARK: outcome(for:)

    func testVerifiedMapsToSuccess() {
        let result = RawPurchaseResult.verified(productID: EarshotPlusProduct.tipSmall.rawValue)
        XCTAssertEqual(TipJarDecisionLogic.outcome(for: result), .success)
    }

    func testUnverifiedMapsToFailed() {
        let result = RawPurchaseResult.unverified(productID: EarshotPlusProduct.tipMedium.rawValue, reason: "bad signature")
        XCTAssertEqual(TipJarDecisionLogic.outcome(for: result), .failed)
    }

    func testUserCancelledMapsToCancelled() {
        XCTAssertEqual(TipJarDecisionLogic.outcome(for: .userCancelled), .cancelled)
    }

    func testPendingMapsToPending() {
        XCTAssertEqual(TipJarDecisionLogic.outcome(for: .pending), .pending)
    }

    // MARK: shouldFinish(for:)

    func testShouldFinishIsTrueOnlyForVerified() {
        XCTAssertTrue(TipJarDecisionLogic.shouldFinish(for: .verified(productID: EarshotPlusProduct.tipLarge.rawValue)))
    }

    func testShouldFinishIsFalseForUnverified() {
        XCTAssertFalse(
            TipJarDecisionLogic.shouldFinish(for: .unverified(productID: EarshotPlusProduct.tipSmall.rawValue, reason: "x"))
        )
    }

    func testShouldFinishIsFalseForUserCancelled() {
        XCTAssertFalse(TipJarDecisionLogic.shouldFinish(for: .userCancelled))
    }

    func testShouldFinishIsFalseForPending() {
        XCTAssertFalse(TipJarDecisionLogic.shouldFinish(for: .pending))
    }
}
