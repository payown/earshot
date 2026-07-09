import Foundation

/// A single StoreKit 2 transaction's entitlement-relevant fields, already
/// unwrapped from `VerificationResult` and reduced to plain Sendable data.
///
/// This is deliberately StoreKit-free (no `Transaction`, no
/// `VerificationResult`) so ``EntitlementEngine`` — the pure decision logic —
/// and its tests never need a real or simulated StoreKit environment. Only
/// ``StoreKitEntitlementSource`` (the live adapter) ever produces one of
/// these, and it does so only for `.verified` results (#634): an
/// `.unverified` transaction never becomes an `EntitlementFact` at all, so
/// there is no "unverified" case here to accidentally treat as entitled.
struct EntitlementFact: Sendable, Equatable {
    /// The catalog product this transaction is for. `StoreKitEntitlementSource`
    /// never produces a fact for a product ID outside ``EarshotPlusProduct`` —
    /// an unrecognized ID is logged and dropped rather than represented here.
    let product: EarshotPlusProduct

    /// Non-nil when Apple revoked or refunded this transaction (family sharing
    /// removal, support refund, etc.). A revoked transaction never grants
    /// entitlement regardless of any other field.
    let revocationDate: Date?

    /// For auto-renewable subscriptions, when the current period ends. `nil`
    /// for the lifetime non-consumable, which never expires. Present mainly as
    /// a defensive check — `Transaction.currentEntitlements` is documented to
    /// already exclude expired subscriptions — so a stale/expired fact can
    /// never grant entitlement even if it somehow reached the engine.
    let expirationDate: Date?

    init(product: EarshotPlusProduct, revocationDate: Date? = nil, expirationDate: Date? = nil) {
        self.product = product
        self.revocationDate = revocationDate
        self.expirationDate = expirationDate
    }
}
