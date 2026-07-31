import Foundation
import Observation
import StoreKit

/// View-model-side state and live StoreKit purchase orchestration for the
/// Earshot Plus paywall (#632). Deliberately kept OUT of
/// `Features/Monetization/Domain` — this codebase's established pattern
/// (``EntitlementFact``/``EntitlementTransactionSource``/#634) is to keep the
/// Domain layer StoreKit-free and confine live StoreKit calls to one adapter
/// type. This is that adapter for the paywall: it owns the `product.purchase()`
/// call and the `Product` → ``PaywallProductDisplay`` mapping, and delegates
/// everything else — the actual product catalog fetch and the post-purchase
/// entitlement recompute — to the existing ``ProductCatalogService`` and
/// ``EntitlementStore`` rather than reimplementing either.
///
/// `loadProducts()` and `purchase(_:entitlements:)` both touch live StoreKit
/// and so inherit the same headless-CI limitation already documented for
/// #631/`ProductCatalogServiceTests` (`SKInternalErrorDomain Code=3` — the
/// local StoreKit test daemon cannot persist session state in this execution
/// environment). All display/copy/announcement logic they depend on
/// (``PaywallLogic``) is pulled out into pure, StoreKit-free functions
/// specifically so that logic is NOT subject to the same limitation and stays
/// fully covered by headless unit tests.
@MainActor
@Observable
final class PaywallViewModel {
    enum LoadState: Equatable, Sendable {
        case loading
        case loaded
        case failed
    }

    /// Whether the product catalog fetch is loading, loaded, or failed.
    private(set) var loadState: LoadState = .loading
    /// The three Earshot Plus products, mapped to StoreKit-free display data,
    /// in catalog order (Monthly, Yearly, Lifetime). Only entries that
    /// resolved from StoreKit are present — a partial catalog failure
    /// surfaces as `.failed` (see ``loadProducts()``), never a silently
    /// incomplete list.
    private(set) var displays: [PaywallProductDisplay] = []
    /// The product currently mid-purchase, or `nil`. Drives the busy state on
    /// that one product's button and disables the rest of the sheet while a
    /// purchase is in flight.
    private(set) var purchasingProduct: EarshotPlusProduct?
    /// Set once a purchase settles into a non-cancellation outcome; drives
    /// the inline success/pending/failed banner. Cancellation never sets
    /// this — see ``PaywallPurchaseOutcome``'s doc comment.
    private(set) var outcome: PaywallPurchaseOutcome?
    /// True only after a verified Lifetime purchase whose post-purchase
    /// entitlement snapshot still contains an active subscription fact.
    private(set) var showsLifetimeCancellationGuidance = false

    private var products: [EarshotPlusProduct: Product] = [:]
    private let catalog: ProductCatalogService

    init(catalog: ProductCatalogService = ProductCatalogService()) {
        self.catalog = catalog
    }

    var monthlyDisplay: PaywallProductDisplay? { displays.first { $0.product == .plusMonthly } }
    var yearlyDisplay: PaywallProductDisplay? { displays.first { $0.product == .plusYearly } }
    var lifetimeDisplay: PaywallProductDisplay? { displays.first { $0.product == .plusLifetime } }

    func display(for product: EarshotPlusProduct) -> PaywallProductDisplay? {
        displays.first { $0.product == product }
    }

    /// The "Best value" badge for the yearly product, or `nil` if it doesn't
    /// honestly earn one right now (see ``PaywallLogic/bestValueBadge``).
    var bestValueBadge: String? {
        PaywallLogic.bestValueBadge(monthly: monthlyDisplay, yearly: yearlyDisplay)
    }

    /// Fetches the three Earshot Plus products from StoreKit and maps them to
    /// display data. Safe to call again (e.g. from a "Try Again" button after
    /// a network failure) — it always starts from `.loading` and replaces any
    /// previous result.
    func loadProducts() async {
        loadState = .loading
        do {
            let fetched = try await catalog.fetchEarshotPlusProducts()
            products = fetched
            displays = EarshotPlusProduct.earshotPlusProducts.compactMap { product in
                fetched[product].map { Self.display(for: product, storeKitProduct: $0) }
            }
            loadState = displays.isEmpty ? .failed : .loaded
        } catch {
            AppLog.monetization.error("Paywall product fetch failed: \(error.localizedDescription, privacy: .public)")
            products = [:]
            displays = []
            loadState = .failed
        }
    }

    /// Starts a purchase for `display`. No-ops if a purchase is already in
    /// flight or the underlying StoreKit `Product` isn't resolved (shouldn't
    /// happen once `loadState == .loaded`, guarded defensively anyway).
    ///
    /// `entitlements` is passed in rather than read from an injected property
    /// so this type has no `@Environment` dependency of its own and stays a
    /// plain, directly-constructible `@Observable` — the caller (``PaywallView``)
    /// is the one with access to the environment.
    func purchase(_ display: PaywallProductDisplay, entitlements: EntitlementStore) async {
        guard purchasingProduct == nil, let product = products[display.product] else { return }
        purchasingProduct = display.product
        outcome = nil
        showsLifetimeCancellationGuidance = false
        speak(PaywallLogic.inProgressAnnouncement(
            displayName: PaywallLogic.decisionDisplayName(for: display)
        ))

        do {
            let result = try await product.purchase()
            await handle(result: result, for: display, entitlements: entitlements)
        } catch {
            AppLog.monetization.error(
                "Purchase threw for \(display.product.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            purchasingProduct = nil
            outcome = .failed
            speak(PaywallLogic.announcement(for: .failed))
        }
    }

    private func handle(result: Product.PurchaseResult, for display: PaywallProductDisplay, entitlements: EntitlementStore) async {
        switch result {
        case .success(let verification):
            switch verification {
            case .verified(let transaction):
                // Finish directly here (WWDC "Meet StoreKit 2" pattern) rather
                // than relying solely on the long-running `Transaction.updates`
                // listener (`EntitlementStore.startObservingTransactionUpdates()`,
                // already running since launch) to pick this transaction up —
                // that listener WILL also see this exact transaction and is a
                // safe no-op the second time, but finishing + resyncing
                // immediately here is what makes `isEntitled` flip before this
                // method returns, instead of racing the listener's timing.
                await transaction.finish()
                _ = await entitlements.resync()
                let requiresSubscriptionCancellation =
                    PaywallLogic.shouldShowLifetimeCancellationGuidance(
                        purchasedProduct: display.product,
                        hasActiveSubscription: entitlements.hasActiveSubscription
                    )
                purchasingProduct = nil
                outcome = .success
                showsLifetimeCancellationGuidance = requiresSubscriptionCancellation
                speak(PaywallLogic.successAnnouncement(
                    for: display,
                    requiresSubscriptionCancellation: requiresSubscriptionCancellation
                ))
            case .unverified(_, let error):
                // Mirrors `StoreKitEntitlementSource`'s conservative handling:
                // an unverified transaction is never finished here and never
                // treated as a grant. The `Transaction.updates` listener will
                // observe the same unverified result independently and also
                // leave it unfinished.
                AppLog.monetization.error(
                    "Purchase unverified for \(display.product.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                purchasingProduct = nil
                outcome = .failed
                speak(PaywallLogic.announcement(for: .failed))
            }
        case .pending:
            // Ask to Buy / parental approval. Not a failure, not a success —
            // a distinct third state the user must be told about explicitly.
            purchasingProduct = nil
            outcome = .pending
            speak(PaywallLogic.announcement(for: .pending))
        case .userCancelled:
            // Deliberately does NOT set `outcome` — cancelling returns the
            // user to the interactive paywall exactly as it was, with only a
            // brief, non-alarming announcement. See `PaywallPurchaseOutcome`'s
            // doc comment for why this is not one of its cases.
            purchasingProduct = nil
            speak(PaywallLogic.cancelledAnnouncement)
        @unknown default:
            purchasingProduct = nil
            outcome = .failed
            speak(PaywallLogic.announcement(for: .failed))
        }
    }

    private func speak(_ announcement: PaywallLogic.Announcement) {
        Announcer.announce(announcement.message, assertive: announcement.assertive)
    }

    /// Maps a live StoreKit `Product` to StoreKit-free display data. The only
    /// place in this type (besides ``purchase(_:entitlements:)``'s direct
    /// `product.purchase()` call) that reads `Product`/`Product.SubscriptionPeriod`
    /// fields directly.
    private static func display(for product: EarshotPlusProduct, storeKitProduct: Product) -> PaywallProductDisplay {
        PaywallProductDisplay(
            product: product,
            displayName: storeKitProduct.displayName,
            displayPrice: storeKitProduct.displayPrice,
            price: storeKitProduct.price,
            subscriptionPeriod: storeKitProduct.subscription.map { mapPeriod($0.subscriptionPeriod) }
        )
    }

    private static func mapPeriod(_ period: Product.SubscriptionPeriod) -> PaywallSubscriptionPeriod {
        let unit: PaywallSubscriptionPeriod.Unit
        switch period.unit {
        case .day: unit = .day
        case .week: unit = .week
        case .month: unit = .month
        case .year: unit = .year
        @unknown default: unit = .month
        }
        return PaywallSubscriptionPeriod(unit: unit, value: period.value)
    }
}
