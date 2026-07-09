import XCTest
@testable import Earshot

/// Exercises ``EntitlementEngine`` — the pure grant/deny decision — with hand
/// built ``EntitlementFact`` fixtures. No StoreKit involved at all (#634).
final class EntitlementEngineTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Grants

    func testVerifiedLifetimeFactGrantsEntitlement() {
        let fact = EntitlementFact(product: .plusLifetime)
        XCTAssertTrue(EntitlementEngine.grantsEntitlement(fact, now: now))
        XCTAssertTrue(EntitlementEngine.isEntitled(from: [fact], now: now))
    }

    func testVerifiedActiveMonthlySubscriptionGrantsEntitlement() {
        let fact = EntitlementFact(product: .plusMonthly, expirationDate: now.addingTimeInterval(86_400))
        XCTAssertTrue(EntitlementEngine.grantsEntitlement(fact, now: now))
    }

    func testAnySingleQualifyingFactIsEnoughAmongMultiple() {
        let facts = [
            EntitlementFact(product: .plusMonthly, revocationDate: now.addingTimeInterval(-10)), // revoked
            EntitlementFact(product: .plusLifetime), // not revoked
        ]
        XCTAssertTrue(EntitlementEngine.isEntitled(from: facts, now: now))
    }

    // MARK: Denies

    func testEmptyFactsAreNotEntitled() {
        XCTAssertFalse(EntitlementEngine.isEntitled(from: [], now: now))
    }

    func testRevokedTransactionDowngradesEntitlement() {
        let fact = EntitlementFact(product: .plusLifetime, revocationDate: now.addingTimeInterval(-60))
        XCTAssertFalse(EntitlementEngine.grantsEntitlement(fact, now: now))
        XCTAssertFalse(EntitlementEngine.isEntitled(from: [fact], now: now))
    }

    func testRevokedSubscriptionDowngradesEntitlementEvenIfNotYetExpired() {
        let fact = EntitlementFact(
            product: .plusYearly,
            revocationDate: now.addingTimeInterval(-60),
            expirationDate: now.addingTimeInterval(86_400 * 30)
        )
        XCTAssertFalse(EntitlementEngine.grantsEntitlement(fact, now: now))
    }

    func testExpiredSubscriptionDoesNotGrantEntitlement() {
        let fact = EntitlementFact(product: .plusMonthly, expirationDate: now.addingTimeInterval(-1))
        XCTAssertFalse(EntitlementEngine.grantsEntitlement(fact, now: now))
    }

    func testExpirationExactlyNowDoesNotGrantEntitlement() {
        let fact = EntitlementFact(product: .plusMonthly, expirationDate: now)
        XCTAssertFalse(EntitlementEngine.grantsEntitlement(fact, now: now))
    }

    func testTipProductsNeverGrantEntitlementEvenIfPresentAsAFact() {
        for tip in EarshotPlusProduct.tipProducts {
            let fact = EntitlementFact(product: tip)
            XCTAssertFalse(EntitlementEngine.grantsEntitlement(fact, now: now), "\(tip) must never grant Plus")
        }
    }

    func testOnlyRevokedFactsAmongMultipleResultsInNotEntitled() {
        let facts = [
            EntitlementFact(product: .plusMonthly, revocationDate: now.addingTimeInterval(-10)),
            EntitlementFact(product: .plusYearly, expirationDate: now.addingTimeInterval(-10)),
        ]
        XCTAssertFalse(EntitlementEngine.isEntitled(from: facts, now: now))
    }
}
