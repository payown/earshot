import Foundation

/// Pure decision logic for "does this set of facts add up to Earshot Plus
/// being entitled right now?" (#634). Deliberately a plain, synchronous,
/// StoreKit-free function so it's trivially unit-testable with hand-built
/// ``EntitlementFact`` fixtures — no `SKTestSession`, no async, no live
/// transaction stream required.
///
/// Ambiguous-state rule (explicit product decision): any fact this engine
/// can't positively confirm as a currently-valid Earshot Plus purchase is
/// treated as NOT entitled. There is no "unknown -> grant" branch anywhere
/// in this type.
enum EntitlementEngine {
    /// Returns whether `facts` grant Earshot Plus entitlement as of `now`.
    ///
    /// A fact grants entitlement only when all of the following hold:
    ///   - its product is one of the three that unlock Plus
    ///     (``EarshotPlusProduct/earshotPlusProducts`` — excludes tip jar
    ///     consumables, which never grant entitlement even if one somehow
    ///     appeared here);
    ///   - it has not been revoked or refunded (`revocationDate == nil`);
    ///   - it isn't expired (`expirationDate`, when present, is after `now`).
    ///
    /// `facts` need only contain one qualifying entry for the result to be
    /// `true` — a user only needs one live Plus purchase (monthly, yearly, or
    /// lifetime), not all three.
    static func isEntitled(from facts: [EntitlementFact], now: Date = .now) -> Bool {
        facts.contains { grantsEntitlement($0, now: now) }
    }

    /// Whether a single fact, on its own, currently grants Earshot Plus.
    static func grantsEntitlement(_ fact: EntitlementFact, now: Date = .now) -> Bool {
        guard EarshotPlusProduct.earshotPlusProducts.contains(fact.product) else { return false }
        guard fact.revocationDate == nil else { return false }
        if let expirationDate = fact.expirationDate, expirationDate <= now { return false }
        return true
    }
}
