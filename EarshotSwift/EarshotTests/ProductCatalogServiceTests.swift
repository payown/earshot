import StoreKit
import StoreKitTest
import XCTest
@testable import Earshot

/// Exercises ``ProductCatalogService`` against a real `SKTestSession` loaded
/// directly from `Earshot/Testing/Configuration.storekit`. Loading the file
/// by URL (rather than relying on the scheme's Test-action StoreKit
/// configuration, which XcodeGen only wires for the Run action — see
/// project.yml) makes this deterministic in both Xcode and `xcodebuild test`
/// / CI, independent of scheme-generation quirks.
///
/// This also doubles as validation that `Configuration.storekit` itself is
/// well-formed and matches ``EarshotPlusProduct`` — a malformed or
/// mismatched config file would make these fetches return nothing (or throw
/// `productsNotFound`), not just fail to compile.
final class ProductCatalogServiceTests: XCTestCase {
    private var session: SKTestSession!

    /// Locates `Configuration.storekit` on disk relative to this test file,
    /// so the lookup doesn't depend on the file being a bundled resource
    /// (it deliberately isn't — see project.yml, it's excluded from the
    /// app target's Resources build phase and only referenced by path).
    private static let configurationURL: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // EarshotTests/
            .deletingLastPathComponent() // EarshotSwift/
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

    func testFetchAllReturnsAllSixCatalogProducts() async throws {
        let service = ProductCatalogService()
        let products = try await service.fetchAll()

        XCTAssertEqual(products.count, EarshotPlusProduct.allCases.count)
        for entry in EarshotPlusProduct.allCases {
            XCTAssertNotNil(products[entry], "missing StoreKit product for \(entry.rawValue)")
        }
    }

    func testFetchEarshotPlusProductsReturnsOnlyThoseThree() async throws {
        let service = ProductCatalogService()
        let products = try await service.fetchEarshotPlusProducts()

        XCTAssertEqual(Set(products.keys), Set(EarshotPlusProduct.earshotPlusProducts))
    }

    func testFetchTipProductsReturnsOnlyThoseThree() async throws {
        let service = ProductCatalogService()
        let products = try await service.fetchTipProducts()

        XCTAssertEqual(Set(products.keys), Set(EarshotPlusProduct.tipProducts))
    }

    func testMonthlyAndYearlyResolveAsAutoRenewableSubscriptions() async throws {
        let service = ProductCatalogService()
        let products = try await service.fetch([.plusMonthly, .plusYearly])

        XCTAssertEqual(products[.plusMonthly]?.type, .autoRenewable)
        XCTAssertEqual(products[.plusYearly]?.type, .autoRenewable)
        XCTAssertEqual(products[.plusMonthly]?.subscription?.subscriptionGroupID, products[.plusYearly]?.subscription?.subscriptionGroupID)
    }

    func testLifetimeResolvesAsNonConsumable() async throws {
        let service = ProductCatalogService()
        let products = try await service.fetch([.plusLifetime])

        XCTAssertEqual(products[.plusLifetime]?.type, .nonConsumable)
        XCTAssertNil(products[.plusLifetime]?.subscription, "lifetime must not be in a subscription group")
    }

    func testTipsResolveAsConsumable() async throws {
        let service = ProductCatalogService()
        let products = try await service.fetchTipProducts()

        for entry in EarshotPlusProduct.tipProducts {
            XCTAssertEqual(products[entry]?.type, .consumable)
            XCTAssertNil(products[entry]?.subscription, "tips must not be in a subscription group")
        }
    }

    func testFetchWithEmptyListReturnsEmptyDictionaryWithoutThrowing() async throws {
        let service = ProductCatalogService()
        let products = try await service.fetch([])
        XCTAssertTrue(products.isEmpty)
    }
}
