import XCTest
@testable import Earshot

/// Pure catalog tests — no StoreKit I/O. Confirms the six product IDs match
/// what's confirmed for App Store Connect / `Configuration.storekit`, and
/// that the subscription/non-consumable/consumable grouping is correct (see
/// #631).
final class EarshotPlusProductTests: XCTestCase {

    // MARK: Exact product ID strings

    func testProductIDsMatchConfirmedStrings() {
        XCTAssertEqual(EarshotPlusProduct.plusMonthly.rawValue, "media.payown.earshot.plus.monthly")
        XCTAssertEqual(EarshotPlusProduct.plusYearly.rawValue, "media.payown.earshot.plus.yearly")
        XCTAssertEqual(EarshotPlusProduct.plusLifetime.rawValue, "media.payown.earshot.plus.lifetime")
        XCTAssertEqual(EarshotPlusProduct.tipSmall.rawValue, "media.payown.earshot.tip.small")
        XCTAssertEqual(EarshotPlusProduct.tipMedium.rawValue, "media.payown.earshot.tip.medium")
        XCTAssertEqual(EarshotPlusProduct.tipLarge.rawValue, "media.payown.earshot.tip.large")
    }

    func testAllCasesContainsExactlySixProducts() {
        XCTAssertEqual(EarshotPlusProduct.allCases.count, 6)
        XCTAssertEqual(Set(EarshotPlusProduct.allCases.map(\.rawValue)).count, 6, "product IDs must be unique")
    }

    // MARK: Kind classification

    func testMonthlyAndYearlyAreAutoRenewableSubscriptions() {
        XCTAssertEqual(EarshotPlusProduct.plusMonthly.kind, .autoRenewableSubscription)
        XCTAssertEqual(EarshotPlusProduct.plusYearly.kind, .autoRenewableSubscription)
    }

    func testLifetimeIsNonConsumable() {
        XCTAssertEqual(EarshotPlusProduct.plusLifetime.kind, .nonConsumable)
    }

    func testTipsAreConsumable() {
        XCTAssertEqual(EarshotPlusProduct.tipSmall.kind, .consumable)
        XCTAssertEqual(EarshotPlusProduct.tipMedium.kind, .consumable)
        XCTAssertEqual(EarshotPlusProduct.tipLarge.kind, .consumable)
    }

    // MARK: Subscription group membership

    func testMonthlyAndYearlyAreInTheEarshotPlusGroup() {
        XCTAssertEqual(EarshotPlusProduct.plusMonthly.subscriptionGroupName, "Earshot Plus")
        XCTAssertEqual(EarshotPlusProduct.plusYearly.subscriptionGroupName, "Earshot Plus")
    }

    func testLifetimeIsNotInAnySubscriptionGroup() {
        XCTAssertNil(EarshotPlusProduct.plusLifetime.subscriptionGroupName)
    }

    func testTipsAreNotInAnySubscriptionGroup() {
        XCTAssertNil(EarshotPlusProduct.tipSmall.subscriptionGroupName)
        XCTAssertNil(EarshotPlusProduct.tipMedium.subscriptionGroupName)
        XCTAssertNil(EarshotPlusProduct.tipLarge.subscriptionGroupName)
    }

    // MARK: Grouped static lists

    func testEarshotPlusProductsExcludesTips() {
        let ids = Set(EarshotPlusProduct.earshotPlusProducts)
        XCTAssertEqual(ids, [.plusMonthly, .plusYearly, .plusLifetime])
    }

    func testTipProductsExcludesEarshotPlusProducts() {
        let ids = Set(EarshotPlusProduct.tipProducts)
        XCTAssertEqual(ids, [.tipSmall, .tipMedium, .tipLarge])
    }

    func testEarshotPlusProductsAndTipProductsTogetherCoverAllCases() {
        let combined = Set(EarshotPlusProduct.earshotPlusProducts + EarshotPlusProduct.tipProducts)
        XCTAssertEqual(combined, Set(EarshotPlusProduct.allCases))
    }
}
