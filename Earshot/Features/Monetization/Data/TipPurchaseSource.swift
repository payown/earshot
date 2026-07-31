import Foundation
import StoreKit

/// One completed call to `Product.purchase()`, reduced to a StoreKit-free
/// ``RawPurchaseResult`` plus (only when verified) a closure that finishes
/// the underlying transaction.
///
/// `finish` is `nil` for every outcome except a verified purchase — mirrors
/// ``TipJarDecisionLogic/shouldFinish(for:)`` at the type level so a caller
/// can't accidentally invoke `finish` on a result that should never be
/// finished. The live implementation is also the only place a real
/// `StoreKit.Transaction` exists; everything downstream (``TipJarViewModel``)
/// only ever sees this closure, never the transaction itself.
struct TipPurchaseAttempt: Sendable {
    let result: RawPurchaseResult
    let finish: (@Sendable () async -> Void)?
}

/// Everything ``TipJarViewModel`` needs from StoreKit 2 to run one tip
/// purchase, behind a protocol so tests can supply a fake purchase result
/// instead of a real/simulated App Store environment (#636). Deliberately
/// takes and returns no `StoreKit.Product`/`StoreKit.Transaction` types in its
/// interface — see ``EntitlementTransactionSource`` for the same pattern
/// applied to entitlement resync.
protocol TipPurchaseSource: Sendable {
    /// Fetches the StoreKit `Product` for `product` and purchases it.
    /// Propagates any error the fetch or `Product.purchase()` throws (no
    /// network, StoreKit unavailable, etc.) — a thrown error never produces a
    /// ``TipPurchaseAttempt``, so there is never a `finish` closure to call in
    /// that case.
    func purchase(_ product: EarshotPlusProduct) async throws -> TipPurchaseAttempt
}

/// Live adapter over `Product.purchase()`. This is the ONLY type in the app
/// that touches `Product.PurchaseResult` / `VerificationResult<Transaction>`
/// for the tip jar. It does no finish-or-not decision-making of its own —
/// every result is reduced to a StoreKit-free ``RawPurchaseResult`` and handed
/// back to ``TipJarViewModel``, which consults ``TipJarDecisionLogic`` (pure,
/// unit-testable) for that.
///
/// No backend, no server-side receipt validation (same scope as #634):
/// verification is StoreKit 2's local, on-device cryptographic check only.
struct StoreKitTipPurchaseSource: TipPurchaseSource {
    private let catalog: ProductCatalogService

    init(catalog: ProductCatalogService = ProductCatalogService()) {
        self.catalog = catalog
    }

    func purchase(_ product: EarshotPlusProduct) async throws -> TipPurchaseAttempt {
        let products = try await catalog.fetch([product])
        guard let storeKitProduct = products[product] else {
            // ProductCatalogService.fetch throws CatalogError.productsNotFound
            // before returning a partial dictionary, so this branch is
            // unreachable in practice — kept only to avoid a force-unwrap.
            throw ProductCatalogService.CatalogError.productsNotFound([product])
        }
        let result = try await storeKitProduct.purchase()
        return Self.attempt(from: result)
    }

    private static func attempt(from result: Product.PurchaseResult) -> TipPurchaseAttempt {
        switch result {
        case .success(let verification):
            switch verification {
            case .verified(let transaction):
                return TipPurchaseAttempt(
                    result: .verified(productID: transaction.productID),
                    finish: { await transaction.finish() }
                )
            case .unverified(let transaction, let error):
                return TipPurchaseAttempt(
                    result: .unverified(productID: transaction.productID, reason: error.localizedDescription),
                    finish: nil
                )
            }
        case .userCancelled:
            return TipPurchaseAttempt(result: .userCancelled, finish: nil)
        case .pending:
            return TipPurchaseAttempt(result: .pending, finish: nil)
        @unknown default:
            // Unknown future StoreKit case: treat like `.pending` rather than
            // guessing at success — never finish an outcome we don't
            // recognize.
            return TipPurchaseAttempt(result: .pending, finish: nil)
        }
    }
}
