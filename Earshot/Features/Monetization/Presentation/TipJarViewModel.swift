import Foundation
import Observation
import StoreKit

/// View model for the tip jar (#636): fetches the three consumable tip
/// products, drives a purchase for a tapped preset, and announces the
/// outcome to VoiceOver. Available to every user regardless of Earshot Plus
/// entitlement — this type must never read ``EntitlementStore/isEntitled`` or
/// otherwise gate any of its behavior on entitlement state.
///
/// StoreKit 2 consumables are not tracked by `Transaction.currentEntitlements`
/// and are deliberately left unfinished by
/// `StoreKitEntitlementSource.processUpdate(_:)` (see that file's doc
/// comment) — finishing a tip transaction is this type's job, and only after
/// the thank-you has already been delivered. ``purchase(_:)`` below sets
/// ``lastOutcome``/``lastOutcomeProduct`` (which the view renders as the
/// thank-you and which drives the matching VoiceOver announcement) strictly
/// before awaiting the attempt's `finish` closure — see ``apply(_:for:)``.
@MainActor
@Observable
final class TipJarViewModel {
    enum ProductsState: Equatable {
        case idle
        case loading
        case loaded([EarshotPlusProduct: Product])
        case failed
    }

    private(set) var productsState: ProductsState = .idle
    /// The tip product currently mid-purchase, or `nil` when no purchase is
    /// in flight. Drives the per-button busy state and disables every preset
    /// button while set — StoreKit does not support overlapping purchase
    /// calls cleanly, and a second tap mid-flight risks a duplicate purchase
    /// sheet.
    private(set) var purchasingProduct: EarshotPlusProduct?
    /// The result of the most recently completed purchase attempt, or `nil`
    /// before any attempt this session. `.success` is what the view renders
    /// as the thank-you.
    private(set) var lastOutcome: TipJarOutcome?
    /// The product ``lastOutcome`` describes. Needed alongside `lastOutcome`
    /// to build a price-specific thank-you/status message.
    private(set) var lastOutcomeProduct: EarshotPlusProduct?

    @ObservationIgnored private let catalog: ProductCatalogService
    @ObservationIgnored private let purchaseSource: TipPurchaseSource

    init(
        catalog: ProductCatalogService = ProductCatalogService(),
        purchaseSource: TipPurchaseSource = StoreKitTipPurchaseSource()
    ) {
        self.catalog = catalog
        self.purchaseSource = purchaseSource
    }

    /// The message to show as on-screen status text after a purchase
    /// attempt, and the same text used for the VoiceOver announcement in
    /// ``apply(_:for:)`` — one source of truth so the visible confirmation
    /// and the spoken one never drift apart. `nil` before any attempt.
    var outcomeMessage: String? {
        guard let lastOutcome, let lastOutcomeProduct else { return nil }
        switch lastOutcome {
        case .success:
            if let price = displayPrice(for: lastOutcomeProduct) {
                return "Thank you for your \(price) tip."
            }
            return "Thank you for your tip."
        case .cancelled:
            return "Tip cancelled."
        case .pending:
            return "Purchase pending approval."
        case .failed:
            return "Tip failed. Try again."
        }
    }

    func loadProducts() async {
        productsState = .loading
        do {
            let products = try await catalog.fetchTipProducts()
            productsState = .loaded(products)
        } catch {
            AppLog.monetization.error("Tip jar: failed to load products: \(error.localizedDescription, privacy: .public)")
            productsState = .failed
        }
    }

    /// Purchases `product`. No-ops if a purchase is already in flight for any
    /// product (see ``purchasingProduct``).
    func purchase(_ product: EarshotPlusProduct) async {
        guard purchasingProduct == nil else { return }
        purchasingProduct = product
        lastOutcome = nil
        lastOutcomeProduct = nil
        Announcer.announce(purchasingMessage(for: product), assertive: true)

        do {
            let attempt = try await purchaseSource.purchase(product)
            await apply(attempt, for: product)
        } catch {
            AppLog.monetization.error(
                "Tip jar: purchase threw for \(product.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            lastOutcomeProduct = product
            lastOutcome = .failed
            Announcer.announce(outcomeMessage ?? "Tip failed. Try again.", assertive: true)
        }

        purchasingProduct = nil
    }

    /// Applies one completed purchase attempt: sets the outcome (which the
    /// view renders as the thank-you/status text) and announces it, THEN —
    /// only for a verified purchase — finishes the transaction. This order is
    /// the load-bearing part of #636: finishing must never happen before the
    /// thank-you has been set, and must never happen at all for an
    /// unverified, cancelled, or pending result.
    private func apply(_ attempt: TipPurchaseAttempt, for product: EarshotPlusProduct) async {
        if case .unverified(let productID, let reason) = attempt.result {
            AppLog.monetization.error(
                "Tip jar: unverified transaction for \(productID, privacy: .public): \(reason, privacy: .public); not finishing"
            )
        }

        lastOutcomeProduct = product
        lastOutcome = TipJarDecisionLogic.outcome(for: attempt.result)
        Announcer.announce(outcomeMessage ?? "", assertive: true)

        guard TipJarDecisionLogic.shouldFinish(for: attempt.result) else { return }
        await attempt.finish?()
    }

    private func displayPrice(for product: EarshotPlusProduct) -> String? {
        guard case .loaded(let products) = productsState else { return nil }
        return products[product]?.displayPrice
    }

    private func purchasingMessage(for product: EarshotPlusProduct) -> String {
        if let price = displayPrice(for: product) {
            return "Purchasing \(price) tip."
        }
        return "Purchasing tip."
    }
}
