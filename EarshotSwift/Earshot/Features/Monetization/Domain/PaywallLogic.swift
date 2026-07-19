import Foundation

/// StoreKit-free display data for one Earshot Plus product tile on the
/// paywall (#632). Mirrors the ``EntitlementFact`` pattern from #634: a real
/// StoreKit `Product` is mapped into this plain struct by the adapter that
/// owns the StoreKit import (``PaywallViewModel``), so everything below —
/// badge math, accessibility labels, disclosure copy — is trivially
/// unit-testable with plain literals, no `Product.products(for:)` round trip
/// and none of the `SKInternalErrorDomain Code=3` local-daemon limitation
/// documented for #631/`ProductCatalogServiceTests`.
struct PaywallProductDisplay: Equatable, Sendable, Identifiable {
    var id: EarshotPlusProduct { product }
    let product: EarshotPlusProduct
    /// StoreKit's localized product name (e.g. "Earshot Plus Monthly"),
    /// exactly as configured in App Store Connect / `Configuration.storekit`
    /// — never hardcoded in this app.
    let displayName: String
    /// StoreKit's localized, currency-formatted price string (e.g. "$2.99"),
    /// for display only — never used for arithmetic.
    let displayPrice: String
    /// The numeric price in the store's currency. Used ONLY to compute the
    /// honest "Best value" percentage (``PaywallLogic/bestValueBadge``) —
    /// never shown directly, since `displayPrice` is already the correctly
    /// localized/formatted string for that.
    let price: Decimal
    /// `nil` for the lifetime product, which is a one-time non-consumable
    /// purchase, not a subscription.
    let subscriptionPeriod: PaywallSubscriptionPeriod?
}

/// StoreKit-free mirror of `Product.SubscriptionPeriod` — just enough to
/// compute a monthly-equivalent cost and speak a billing cadence.
struct PaywallSubscriptionPeriod: Equatable, Sendable {
    enum Unit: Sendable, Equatable {
        case day, week, month, year
    }

    let unit: Unit
    let value: Int

    /// Approximate months in this period, used only for the "Best value"
    /// percentage math (30-day months, 365-day years — an approximation for
    /// comparison purposes, never used for actual billing).
    var approximateMonths: Double {
        switch unit {
        case .day: Double(value) / 30
        case .week: Double(value) * 7 / 30
        case .month: Double(value)
        case .year: Double(value) * 12
        }
    }

    /// Spoken/written billing cadence, e.g. "per month", "every 3 months".
    var spokenCadence: String {
        switch (unit, value) {
        case (.day, 1): "per day"
        case (.week, 1): "per week"
        case (.month, 1): "per month"
        case (.year, 1): "per year"
        case (.day, let n): "every \(n) days"
        case (.week, let n): "every \(n) weeks"
        case (.month, let n): "every \(n) months"
        case (.year, let n): "every \(n) years"
        }
    }
}

/// Why the paywall is being presented. The standard upgrade mode shows all
/// three purchase choices; plan change mode derives a current, non-purchasable
/// tier plus only the valid upgrade offers from the verified entitlement.
enum PaywallPresentationMode: Equatable, Sendable {
    case upgrade
    case changePlan
}

/// One product card in the paywall's StoreKit-free presentation model.
struct PaywallTierOption: Equatable, Sendable, Identifiable {
    enum Status: Equatable, Sendable {
        case current
        case offer
    }

    var id: EarshotPlusProduct { product }
    let product: EarshotPlusProduct
    let status: Status
}

/// The three settled, non-cancellation purchase outcomes the paywall UI
/// renders an inline state for. Cancellation is deliberately NOT a case here
/// — per #632's hard constraint, cancelling must be exactly as easy and
/// neutral as any other sheet dismissal, so it never produces a persistent
/// banner or state change, only a brief, non-alarming announcement (see
/// ``PaywallLogic/cancelledAnnouncement``).
enum PaywallPurchaseOutcome: Equatable, Sendable {
    case success
    case pending
    case failed
}

/// Pure paywall presentation logic (#632): which product gets the factual
/// "Best value" badge, combined accessibility labels, disclosure copy, and
/// the VoiceOver announcement text/assertiveness for every purchase-flow
/// stage. No SwiftUI, no StoreKit — everything here takes
/// ``PaywallProductDisplay`` values, so it's testable with plain literals.
enum PaywallLogic {

    /// One VoiceOver announcement: the message and whether it should
    /// interrupt current speech (`assertive: true`) or queue behind it
    /// (`assertive: false`). Mirrors the two-argument shape of
    /// ``Announcer/announce(_:assertive:)`` so call sites can splat this
    /// straight into that call.
    struct Announcement: Equatable, Sendable {
        let message: String
        let assertive: Bool
    }

    /// Product cards for the requested paywall state. Yearly owners are not
    /// offered a Monthly downgrade, avoiding a delayed-change path in this
    /// upgrade-focused surface. Lifetime is final and therefore has no offers.
    static func tierOptions(
        mode: PaywallPresentationMode,
        currentProduct: EarshotPlusProduct?
    ) -> [PaywallTierOption] {
        switch mode {
        case .upgrade:
            return EarshotPlusProduct.earshotPlusProducts.map {
                PaywallTierOption(product: $0, status: .offer)
            }
        case .changePlan:
            switch currentProduct {
            case .plusMonthly:
                return [
                    PaywallTierOption(product: .plusMonthly, status: .current),
                    PaywallTierOption(product: .plusYearly, status: .offer),
                    PaywallTierOption(product: .plusLifetime, status: .offer)
                ]
            case .plusYearly:
                return [
                    PaywallTierOption(product: .plusYearly, status: .current),
                    PaywallTierOption(product: .plusLifetime, status: .offer)
                ]
            case .plusLifetime:
                return [PaywallTierOption(product: .plusLifetime, status: .current)]
            case .tipSmall, .tipMedium, .tipLarge, nil:
                return []
            }
        }
    }

    static func hasPlanChangeOffers(currentProduct: EarshotPlusProduct?) -> Bool {
        tierOptions(mode: .changePlan, currentProduct: currentProduct)
            .contains { $0.status == .offer }
    }

    static func shortPlanName(for product: EarshotPlusProduct) -> String {
        switch product {
        case .plusMonthly: "Monthly"
        case .plusYearly: "Yearly"
        case .plusLifetime: "Lifetime"
        case .tipSmall: "Small Tip"
        case .tipMedium: "Medium Tip"
        case .tipLarge: "Large Tip"
        }
    }

    /// App Store Connect intentionally uses "Earshot Plus" for both
    /// subscription display names. Append the cadence name for decision copy,
    /// while avoiding duplication if StoreKit already supplies it.
    static func decisionDisplayName(for display: PaywallProductDisplay) -> String {
        let suffix = shortPlanName(for: display.product)
        if display.displayName.lowercased().hasSuffix(suffix.lowercased()) {
            return display.displayName
        }
        return "\(display.displayName) \(suffix)"
    }

    /// The "Best value" badge text for the yearly product, computed honestly
    /// from the ACTUAL monthly and yearly prices passed in — never
    /// hardcoded. Returns `nil` when there's nothing to compare (either
    /// product missing or non-positive price) or when yearly does not
    /// actually save money over monthly (never show a false claim). The
    /// percentage is rounded DOWN to the nearest whole percent so the
    /// claim is always true — rounding up could overstate the saving by a
    /// fraction of a percent.
    static func bestValueBadge(monthly: PaywallProductDisplay?, yearly: PaywallProductDisplay?) -> String? {
        guard let monthly, let yearly,
              monthly.price > 0, yearly.price > 0,
              let yearlyPeriod = yearly.subscriptionPeriod,
              yearlyPeriod.approximateMonths > 0
        else { return nil }

        let yearlyMonthlyEquivalent = yearly.price / Decimal(yearlyPeriod.approximateMonths)
        guard yearlyMonthlyEquivalent < monthly.price else { return nil }

        let savingsFraction = (monthly.price - yearlyMonthlyEquivalent) / monthly.price
        let percent = Int((NSDecimalNumber(decimal: savingsFraction).doubleValue * 100).rounded(.down))
        guard percent > 0 else { return nil }
        return "Best value — about \(percent)% off monthly"
    }

    /// Accessibility label combining product name, price, and billing
    /// cadence into ONE spoken phrase (e.g. "Earshot Plus Monthly, $2.99 per
    /// month"). The lifetime product combines name, price, and "one-time
    /// purchase" instead of a cadence.
    static func accessibilityLabel(for display: PaywallProductDisplay) -> String {
        let name = decisionDisplayName(for: display)
        if let period = display.subscriptionPeriod {
            return "\(name), \(display.displayPrice) \(period.spokenCadence)"
        }
        return "\(name), \(display.displayPrice), one-time purchase"
    }

    /// Short decision label for one product card's single VoiceOver element.
    /// Legal terms live in the hint and the shared disclosure after all tiers,
    /// keeping routine flick navigation concise.
    static func tierAccessibilityLabel(for display: PaywallProductDisplay, badge: String?) -> String {
        var parts = [accessibilityLabel(for: display)]
        if let badge {
            parts.append(badge)
        }
        return parts.joined(separator: ". ") + "."
    }

    static func currentPlanAccessibilityLabel(for display: PaywallProductDisplay) -> String {
        "\(accessibilityLabel(for: display)). Current plan."
    }

    /// One shared, visually-present and VoiceOver-focusable legal disclosure
    /// after all tier controls. Price and cadence are deliberately absent
    /// because every tier's decision label already speaks them.
    static let sharedLegalDisclosure = "Payment is charged to your Apple ID when you confirm. Subscriptions auto-renew unless cancelled at least 24 hours before the current period ends. Your Apple ID is charged for renewal within 24 hours before the current period ends. Manage or cancel subscriptions in your App Store account settings. Lifetime is a one-time purchase and does not renew."

    static let lifetimeSubscriberNotice = "Buying Lifetime does not cancel your current subscription. Cancel the subscription to avoid future charges."

    /// A short action cue plus compressed terms. VoiceOver speaks this only
    /// when the user has hints enabled, after the decision label pause.
    static func purchaseHint(
        for display: PaywallProductDisplay,
        mode: PaywallPresentationMode,
        hasActiveSubscription: Bool
    ) -> String {
        if display.product == .plusLifetime {
            return hasActiveSubscription
                ? "Double tap to buy once. Your subscription continues until you cancel it in App Store settings."
                : "Double tap to buy once. No subscription or renewal."
        }
        if mode == .changePlan, display.product == .plusYearly {
            return "Double tap to upgrade now. Apple applies this change immediately."
        }
        return "Double tap to subscribe. Auto-renews; cancel anytime in App Store settings."
    }

    static func shouldShowLifetimeCancellationGuidance(
        purchasedProduct: EarshotPlusProduct,
        hasActiveSubscription: Bool
    ) -> Bool {
        purchasedProduct == .plusLifetime && hasActiveSubscription
    }

    static func successAnnouncement(
        for display: PaywallProductDisplay,
        requiresSubscriptionCancellation: Bool
    ) -> Announcement {
        let current = "\(decisionDisplayName(for: display)) is now your current plan."
        if requiresSubscriptionCancellation {
            return Announcement(
                message: "\(current) Your subscription is still active. Cancel it to avoid future charges.",
                assertive: true
            )
        }
        return Announcement(message: current, assertive: true)
    }

    /// The busy-state announcement fired the moment a purchase starts.
    /// Polite (not assertive): this is reassurance that the tap registered,
    /// not something the user must be interrupted for — the button's own
    /// accessibility label also swaps to a busy phrase at the same time
    /// (matching `RestorePurchasesRow`'s established busy-state pattern), so
    /// this announcement is a supplement, not the only busy signal.
    static func inProgressAnnouncement(displayName: String) -> Announcement {
        Announcement(message: "Purchasing \(displayName).", assertive: false)
    }

    /// The announcement for a settled, non-cancellation purchase outcome.
    /// All three are assertive — they interrupt current speech — mirroring
    /// `RestorePurchasesRow`'s outcome announcements (`.restored`/`.noChange`/
    /// `.failed` are all `assertive: true`): a purchase result is exactly the
    /// kind of "operation the user explicitly triggered and must hear"
    /// moment that convention exists for. The failure message is
    /// deliberately generic and retry-friendly, matching
    /// `RestorePurchasesRow`'s "Restore failed..." — the specific thrown
    /// error is logged via `AppLog.monetization`, never spoken.
    static func announcement(for outcome: PaywallPurchaseOutcome) -> Announcement {
        switch outcome {
        case .success:
            Announcement(message: "Earshot Plus unlocked.", assertive: true)
        case .pending:
            Announcement(
                message: "Purchase pending approval. You'll be notified once it's approved.",
                assertive: true
            )
        case .failed:
            Announcement(message: "Purchase failed. Check your connection and try again.", assertive: true)
        }
    }

    /// The announcement for a user-initiated cancellation. Deliberately
    /// NOT assertive and deliberately worded to not sound like an error —
    /// cancelling is not a failure, it's the same neutral action as
    /// dismissing any other sheet, and the hard constraint against
    /// guilt-tripping dismiss-path copy applies here too.
    static let cancelledAnnouncement = Announcement(message: "Purchase cancelled.", assertive: false)
}
