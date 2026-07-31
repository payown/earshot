import Foundation
import StoreKit

/// Thin async wrapper around StoreKit 2's `Product.products(for:)`. Nothing
/// downstream should call `Product.products(for:)` with a raw string ID —
/// go through here so every lookup is anchored to ``EarshotPlusProduct``.
///
/// This only fetches StoreKit `Product` metadata (display name, price,
/// etc.) from the App Store — or, in Debug/Simulator, from whichever
/// `.storekit` configuration is active for the running scheme
/// (`Earshot/Testing/Configuration.storekit`). It does not determine
/// whether the current user owns any product (that's #634, entitlement
/// checking) and it does not perform a purchase or any receipt validation —
/// this app has no backend and does all verification on-device via
/// StoreKit 2 (see #631).
struct ProductCatalogService: Sendable {
    /// Thrown when StoreKit resolves some, but not all, of the requested
    /// product IDs. `Product.products(for:)` itself doesn't throw for
    /// unknown IDs — it just omits them from the result — so this wrapper
    /// checks the returned set and surfaces the gap as an error instead of
    /// silently handing back a partial catalog.
    enum CatalogError: Error, Sendable, Equatable {
        case productsNotFound(Set<EarshotPlusProduct>)
    }

    init() {}

    /// Fetches StoreKit `Product`s for the given catalog entries. Propagates
    /// any error `Product.products(for:)` throws (e.g. no network,
    /// StoreKit unavailable), and throws
    /// ``CatalogError/productsNotFound(_:)`` if any requested ID didn't come
    /// back at all.
    func fetch(_ ids: [EarshotPlusProduct]) async throws -> [EarshotPlusProduct: Product] {
        guard !ids.isEmpty else { return [:] }

        let requested = Set(ids)
        let rawIDs = Set(requested.map(\.rawValue))
        let products = try await Product.products(for: rawIDs)

        var resolved: [EarshotPlusProduct: Product] = [:]
        for product in products {
            guard let match = EarshotPlusProduct(rawValue: product.id) else {
                // A product came back from StoreKit that isn't in our catalog
                // enum. This should never happen since we only ever request
                // IDs from EarshotPlusProduct, but skip rather than crash.
                continue
            }
            resolved[match] = product
        }

        let missing = requested.subtracting(resolved.keys)
        guard missing.isEmpty else {
            AppLog.monetization.error(
                "StoreKit fetch missing products: \(missing.map(\.rawValue).joined(separator: ", "), privacy: .public)"
            )
            throw CatalogError.productsNotFound(missing)
        }

        return resolved
    }

    /// Fetches every product in the catalog: both Earshot Plus entitlement
    /// products (subscriptions + lifetime) and the tip jar consumables.
    func fetchAll() async throws -> [EarshotPlusProduct: Product] {
        try await fetch(EarshotPlusProduct.allCases)
    }

    /// Fetches only the products that unlock Earshot Plus (monthly, yearly,
    /// lifetime) — excludes tip jar consumables.
    func fetchEarshotPlusProducts() async throws -> [EarshotPlusProduct: Product] {
        try await fetch(EarshotPlusProduct.earshotPlusProducts)
    }

    /// Fetches only the tip jar consumables — excludes Earshot Plus
    /// entitlement products.
    func fetchTipProducts() async throws -> [EarshotPlusProduct: Product] {
        try await fetch(EarshotPlusProduct.tipProducts)
    }
}
