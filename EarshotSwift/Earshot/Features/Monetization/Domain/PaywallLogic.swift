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
        if let period = display.subscriptionPeriod {
            return "\(display.displayName), \(display.displayPrice) \(period.spokenCadence)"
        }
        return "\(display.displayName), \(display.displayPrice), one-time purchase"
    }

    /// The complete label for one product card's single VoiceOver element.
    /// All visible name, price, cadence, badge, and purchase-term text remains
    /// spoken, but the user no longer has to flick through each visual text
    /// fragment before reaching the purchase action.
    static func tierAccessibilityLabel(for display: PaywallProductDisplay, badge: String?) -> String {
        var parts = [accessibilityLabel(for: display)]
        if let badge {
            parts.append(badge)
        }
        parts.append(display.subscriptionPeriod != nil
            ? subscriptionDisclosure(for: display)
            : lifetimeDisclosure(for: display))
        return parts.joined(separator: ". ")
    }

    /// Visible + spoken disclosure line for a subscription product (Monthly,
    /// Yearly). It stays visually present before Continue and is included in
    /// the card's single combined VoiceOver label rather than becoming a
    /// separate focus stop. This inline disclosure is paired with the
    /// always-visible Terms and Privacy links in the paywall.
    static func subscriptionDisclosure(for display: PaywallProductDisplay) -> String {
        let cadence = display.subscriptionPeriod?.spokenCadence ?? "per period"
        return "\(display.displayPrice) \(cadence). Payment is charged to your Apple ID when you confirm. Auto-renews unless cancelled at least 24 hours before the current period ends. Your Apple ID is charged for renewal within 24 hours before the current period ends. Manage or cancel in your App Store account settings."
    }

    /// Visible + spoken disclosure line for the lifetime product — states
    /// plainly that it's a one-time purchase and deliberately avoids the
    /// word "renew" in any form (not just "auto-renews unless cancelled"),
    /// since no renewal language of any kind applies to a non-consumable.
    static func lifetimeDisclosure(for display: PaywallProductDisplay) -> String {
        "\(display.displayPrice), one-time purchase. Not a subscription — charged once, yours forever."
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
