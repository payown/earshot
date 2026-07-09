import Foundation
import StoreKit

/// Everything ``EntitlementStore`` needs from StoreKit 2, behind a protocol so
/// tests can supply a fake transaction stream instead of a real/simulated
/// App Store environment (#634).
protocol EntitlementTransactionSource: Sendable {
    /// A full, current snapshot of entitlement-relevant facts, built from
    /// whatever the underlying transaction store considers "currently owned"
    /// right now. Called at launch and by ``EntitlementStore/resync()``
    /// (including after Restore Purchases, #633).
    func currentFacts() async -> [EntitlementFact]

    /// A stream that emits once for every StoreKit transaction update (new
    /// purchase, renewal, revocation, refund, ...). The stream carries no
    /// payload — receiving an element just means "something changed, call
    /// ``currentFacts()`` again" — because recomputing from the authoritative
    /// current-entitlements snapshot is simpler and more robust than trying to
    /// apply a single update as an incremental delta.
    func updateSignals() -> AsyncStream<Void>
}

/// Live adapter over `Transaction.currentEntitlements` / `Transaction.updates`.
/// This is the ONLY type in the app that touches those StoreKit 2 APIs
/// directly. It does no verify/reject decision-making of its own — every
/// `VerificationResult` is reduced to a StoreKit-free ``RawTransactionResult``
/// and handed to ``EntitlementFactMapper`` (pure, unit-testable) for that.
///
/// No backend, no server-side receipt validation anywhere in this codebase
/// (confirmed scope for #634): every transaction is checked with local,
/// on-device StoreKit 2 cryptographic verification only.
struct StoreKitEntitlementSource: EntitlementTransactionSource {
    init() {}

    func currentFacts() async -> [EntitlementFact] {
        var facts: [EntitlementFact] = []
        for await result in Transaction.currentEntitlements {
            if let fact = EntitlementFactMapper.fact(from: Self.rawResult(from: result).raw) {
                facts.append(fact)
            }
        }
        return facts
    }

    func updateSignals() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let task = Task {
                for await result in Transaction.updates {
                    await Self.processUpdate(result)
                    continuation.yield(())
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Processes one `Transaction.updates` element: maps it, and finishes the
    /// transaction when it's a verified Earshot Plus purchase. Tip jar
    /// consumables are deliberately left unfinished here — finishing a
    /// consumable is part of granting its content, which is #636's
    /// responsibility, not entitlement tracking's. Unverified/unrecognized
    /// transactions are also left unfinished (StoreKit will keep offering
    /// them; no entitlement is granted in the meantime).
    private static func processUpdate(_ result: VerificationResult<Transaction>) async {
        let (transaction, raw) = rawResult(from: result)
        guard let fact = EntitlementFactMapper.fact(from: raw) else { return }
        guard EarshotPlusProduct.earshotPlusProducts.contains(fact.product) else { return }
        await transaction.finish()
    }

    /// Reduces a real `VerificationResult<Transaction>` to the StoreKit-free
    /// ``RawTransactionResult`` ``EntitlementFactMapper`` operates on, keeping
    /// the live `Transaction` alongside for `finish()`. This is the only
    /// function in the app that reads `VerificationResult`/`Transaction`
    /// directly.
    private static func rawResult(
        from result: VerificationResult<Transaction>
    ) -> (transaction: Transaction, raw: RawTransactionResult) {
        switch result {
        case .unverified(let transaction, let error):
            return (transaction, .unverified(productID: transaction.productID, reason: error.localizedDescription))
        case .verified(let transaction):
            return (
                transaction,
                .verified(
                    productID: transaction.productID,
                    revocationDate: transaction.revocationDate,
                    expirationDate: transaction.expirationDate
                )
            )
        }
    }
}
