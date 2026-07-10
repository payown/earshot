import Foundation

/// A StoreKit-free description of one `VerificationResult<Transaction>`,
/// carrying only the fields ``EntitlementFactMapper`` needs to decide whether
/// it can become an ``EntitlementFact``. Exists purely so the verify/reject
/// mapping logic in ``EntitlementFactMapper`` is unit-testable with plain
/// fixtures — no real or `SKTestSession`-simulated StoreKit transaction
/// required (#634). ``StoreKitEntitlementSource`` is the only place a real
/// `VerificationResult<Transaction>` gets reduced to one of these.
enum RawTransactionResult: Sendable, Equatable {
    /// StoreKit's local cryptographic check passed.
    case verified(productID: String, revocationDate: Date?, expirationDate: Date?)
    /// StoreKit's local cryptographic check failed. `reason` is a
    /// human-readable description of the verification error, logged only —
    /// never used in the grant/deny decision itself (the case alone is
    /// enough to deny).
    case unverified(productID: String, reason: String)
}

/// Converts a ``RawTransactionResult`` into an ``EntitlementFact``, or `nil`
/// when the result must not grant entitlement.
///
/// Ambiguous-state rule (explicit product decision, #634): every branch here
/// that can't positively confirm a verified, recognized Earshot Plus product
/// returns `nil` (deny) and logs. There is no branch that grants on an
/// unverified result or an unrecognized product id.
enum EntitlementFactMapper {
    static func fact(from result: RawTransactionResult) -> EntitlementFact? {
        switch result {
        case .unverified(let productID, let reason):
            AppLog.monetization.error(
                "Unverified transaction for \(productID, privacy: .public): \(reason, privacy: .public); not granting entitlement"
            )
            return nil
        case .verified(let productID, let revocationDate, let expirationDate):
            guard let product = EarshotPlusProduct(rawValue: productID) else {
                // A verified transaction for a product ID StoreKit knows about
                // but this app's catalog doesn't (e.g. a retired/renamed ID).
                // Ambiguous — deny rather than guess.
                AppLog.monetization.error(
                    "Verified transaction for unknown product id \(productID, privacy: .public); not granting entitlement"
                )
                return nil
            }
            return EntitlementFact(product: product, revocationDate: revocationDate, expirationDate: expirationDate)
        }
    }
}
