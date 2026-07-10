import Foundation

/// A StoreKit-free description of one tip purchase attempt's result, carrying
/// only the fields ``TipJarDecisionLogic`` needs to decide what to show the
/// user and whether the transaction should be finished. Exists purely so the
/// decision logic below is unit-testable with plain fixtures — no real or
/// `SKTestSession`-simulated `Product`/`Transaction` required (#636). Mirrors
/// the shape of ``RawTransactionResult`` (see `EntitlementFactMapper.swift`),
/// extended with the two additional `Product.PurchaseResult` cases a
/// consumable purchase can hit that entitlement resync never sees:
/// `.userCancelled` and `.pending`. ``TipPurchaseSource`` (Data layer) is the
/// only place a real `Product.PurchaseResult` gets reduced to one of these.
enum RawPurchaseResult: Sendable, Equatable {
    /// StoreKit's local cryptographic check passed for this purchase.
    case verified(productID: String)
    /// StoreKit's local cryptographic check failed. `reason` is a
    /// human-readable description of the verification error, logged only —
    /// never used in the finish/deny decision itself (the case alone is
    /// enough to deny finishing).
    case unverified(productID: String, reason: String)
    /// The user dismissed or cancelled the purchase sheet. Not an error.
    case userCancelled
    /// The purchase requires approval outside this session (e.g. Ask to Buy
    /// for a family member) and has not completed yet.
    case pending
}

/// What the tip jar UI should show/announce after a purchase attempt
/// completes, however it completed.
enum TipJarOutcome: Sendable, Equatable {
    case success
    case cancelled
    case pending
    case failed
}

/// Pure decision logic for the tip jar consumable purchase flow (#636). No
/// StoreKit, no `async`, no I/O — every branch is a direct, unit-testable
/// mapping from a ``RawPurchaseResult``.
///
/// The critical rule this encodes (called out explicitly in #636): a
/// consumable transaction must only ever be finished when it was verified.
/// Every other case — unverified, cancelled, pending, or a thrown error
/// upstream that never produced a `RawPurchaseResult` at all — must leave the
/// transaction unfinished. ``TipJarViewModel`` is responsible for the *order*
/// (deliver the thank-you, then finish); this type is only responsible for
/// the *should we finish at all* decision.
enum TipJarDecisionLogic {
    /// Maps a raw purchase result to the outcome the UI should render and
    /// announce.
    static func outcome(for result: RawPurchaseResult) -> TipJarOutcome {
        switch result {
        case .verified:
            .success
        case .unverified:
            .failed
        case .userCancelled:
            .cancelled
        case .pending:
            .pending
        }
    }

    /// Whether the transaction behind this result should be finished at all.
    /// Only `true` for a verified purchase — unverified, cancelled, and
    /// pending results must never be finished.
    static func shouldFinish(for result: RawPurchaseResult) -> Bool {
        if case .verified = result {
            return true
        }
        return false
    }
}
