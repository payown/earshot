import StoreKit
import StoreKitTest
import XCTest
@testable import Earshot

/// Exercises ``PaywallViewModel/loadProducts()`` — the one part of #632 that
/// necessarily touches live StoreKit (`Product.products(for:)`, via
/// ``ProductCatalogService``) — against a real `SKTestSession` loaded from
/// `Configuration.storekit`, mirroring `ProductCatalogServiceTests`' setup
/// exactly (#631).
///
/// The purchase flow itself (`purchase(_:entitlements:)`) is NOT covered here
/// — driving a real `product.purchase()` through `SKTestSession`'s
/// transaction simulation is a separate, heavier undertaking. All of its
/// supporting logic (announcement text/assertiveness, outcome→UI mapping
/// inputs) is StoreKit-free and fully covered by `PaywallLogicTests` instead.
final class PaywallViewModelTests: XCTestCase {
    private var session: SKTestSession!

    private static let configurationURL: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // EarshotTests/
            .deletingLastPathComponent() // repo root (Earshot/ and EarshotTests/ are siblings here)
            .appendingPathComponent("Earshot/Testing/Configuration.storekit")
    }()

    override func setUpWithError() throws {
        try super.setUpWithError()
        session = try SKTestSession(contentsOf: Self.configurationURL)
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
    }

    override func tearDownWithError() throws {
        session = nil
        try super.tearDownWithError()
    }

    @MainActor
    func testLoadProductsPopulatesAllThreeDisplaysInCatalogOrder() async throws {
        let model = PaywallViewModel()
        await model.loadProducts()

        XCTAssertEqual(model.loadState, .loaded)
        XCTAssertEqual(model.displays.map(\.product), [.plusMonthly, .plusYearly, .plusLifetime])
    }

    @MainActor
    func testLoadProductsMapsMonthlyAndYearlyAsSubscriptionsAndLifetimeAsNot() async throws {
        let model = PaywallViewModel()
        await model.loadProducts()

        XCTAssertNotNil(model.monthlyDisplay?.subscriptionPeriod)
        XCTAssertNotNil(model.yearlyDisplay?.subscriptionPeriod)
        XCTAssertNil(model.lifetimeDisplay?.subscriptionPeriod, "lifetime must never carry a subscription period")
    }

    @MainActor
    func testBestValueBadgeIsComputedFromLiveConfigurationPrices() async throws {
        let model = PaywallViewModel()
        await model.loadProducts()

        // Configuration.storekit prices $2.99/mo and $19.99/yr — matches
        // PaywallLogicTests' hand-built fixture math (~44% floored).
        XCTAssertEqual(model.bestValueBadge, "Best value — about 44% off monthly")
    }
}
