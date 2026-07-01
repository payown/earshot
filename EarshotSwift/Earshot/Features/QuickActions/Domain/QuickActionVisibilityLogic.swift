import Foundation

/// Pure rules for hiding and restoring Quick Actions (#524). Operates on plain
/// action-key strings + a set of hidden keys so every branch is unit-testable
/// without SwiftData or a view.
///
/// Two invariants the UI relies on:
///   - The rotor for a content row shows only the VISIBLE actions, in order.
///   - The default double-tap is the FIRST visible action.
///
/// The one guard that keeps a set usable: an action can be hidden only while at
/// least one OTHER visible action would remain. Restoring is always allowed. A
/// key absent from the store (a brand-new action) is treated as visible, so
/// future actions default to enabled with no migration.
enum QuickActionVisibilityLogic {

    /// The rotor-visible keys, preserving `ordered`'s order and dropping any key
    /// in `hidden`.
    static func visibleKeys(ordered: [String], hidden: Set<String>) -> [String] {
        ordered.filter { !hidden.contains($0) }
    }

    /// The default double-tap key: the first visible key, or nil if none remain
    /// (which the `canHide` guard prevents from ever happening in practice).
    static func defaultKey(ordered: [String], hidden: Set<String>) -> String? {
        visibleKeys(ordered: ordered, hidden: hidden).first
    }

    /// Whether `key` may be hidden: it must currently be visible and there must
    /// be more than one visible action, so hiding it never empties the set.
    static func canHide(_ key: String, ordered: [String], hidden: Set<String>) -> Bool {
        let visible = visibleKeys(ordered: ordered, hidden: hidden)
        guard visible.contains(key) else { return false }
        return visible.count > 1
    }

    /// Whether `key` may be restored: it must currently be hidden.
    static func canRestore(_ key: String, hidden: Set<String>) -> Bool {
        hidden.contains(key)
    }
}
