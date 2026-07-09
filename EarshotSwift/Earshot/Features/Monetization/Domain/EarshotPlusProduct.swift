import Foundation

/// Single source of truth for every purchasable Earshot Plus / tip jar
/// product. Nothing outside this enum should ever hardcode a
/// `media.payown.earshot.*` product identifier string — reference a case
/// here instead (see #631, the foundation issue for the Earshot Plus A-series
/// #632-#638).
///
/// These six IDs are matched 1:1 with both App Store Connect and the local
/// `Configuration.storekit` file (`Earshot/Testing/Configuration.storekit`)
/// used for on-device/simulator StoreKit testing. The paid tier itself is
/// always called "Earshot Plus" — never "Pro" or "Premium" — in code,
/// comments, and UI copy.
///
/// This type only describes the catalog shape (identifiers, kind, grouping).
/// It says nothing about whether the current user owns any of these products
/// — that entitlement check is issue #634.
enum EarshotPlusProduct: String, CaseIterable, Sendable {
    /// $2.99/month, auto-renewing, in the "Earshot Plus" subscription group.
    case plusMonthly = "media.payown.earshot.plus.monthly"
    /// $20/year, auto-renewing, in the "Earshot Plus" subscription group.
    case plusYearly = "media.payown.earshot.plus.yearly"
    /// $49 one-time purchase, non-consumable. NOT in the subscription group.
    case plusLifetime = "media.payown.earshot.plus.lifetime"
    /// $1.99 tip jar purchase, consumable.
    case tipSmall = "media.payown.earshot.tip.small"
    /// $4.99 tip jar purchase, consumable.
    case tipMedium = "media.payown.earshot.tip.medium"
    /// $9.99 tip jar purchase, consumable.
    case tipLarge = "media.payown.earshot.tip.large"

    /// The StoreKit purchase model each product uses. Mirrors the `type`
    /// each product is configured with in App Store Connect and
    /// `Configuration.storekit`.
    enum Kind: Sendable, Equatable {
        case autoRenewableSubscription
        case nonConsumable
        case consumable
    }

    var kind: Kind {
        switch self {
        case .plusMonthly, .plusYearly:
            .autoRenewableSubscription
        case .plusLifetime:
            .nonConsumable
        case .tipSmall, .tipMedium, .tipLarge:
            .consumable
        }
    }

    /// The App Store Connect subscription group name this product belongs
    /// to, or `nil` if it isn't an auto-renewing subscription. Only
    /// ``plusMonthly`` and ``plusYearly`` are grouped; ``plusLifetime`` is a
    /// separate non-consumable and the three tip products are standalone
    /// consumables — none of those three belong to any group.
    var subscriptionGroupName: String? {
        switch kind {
        case .autoRenewableSubscription:
            EarshotPlusProduct.subscriptionGroupName
        case .nonConsumable, .consumable:
            nil
        }
    }

    /// The single subscription group name used by this app. Exposed as a
    /// static so callers can compare against it without going through a
    /// specific product case.
    static let subscriptionGroupName = "Earshot Plus"

    /// The three products that unlock Earshot Plus (the two subscriptions
    /// plus the lifetime non-consumable). Excludes tip jar consumables.
    static var earshotPlusProducts: [EarshotPlusProduct] {
        [.plusMonthly, .plusYearly, .plusLifetime]
    }

    /// The three standalone tip jar consumables. Excludes Earshot Plus
    /// entitlement products.
    static var tipProducts: [EarshotPlusProduct] {
        [.tipSmall, .tipMedium, .tipLarge]
    }
}
