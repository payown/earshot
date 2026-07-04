import SwiftUI

/// The single compensation point for iOS's reversed rotor emission (#572).
///
/// SwiftUI's `.accessibilityActions { ... }` emits the ViewBuilder's custom
/// actions into the VoiceOver Actions rotor in REVERSE declaration order on
/// current iOS (observed on device, 2026-07-04, #572). The whole pipeline —
/// storage → `QuickActionStore` → the builders → each row — preserves the
/// user's saved order perfectly, yet the rotor announced every Quick Action
/// list exactly backwards. So this helper hands SwiftUI the actions reversed,
/// and the rotor speaks them in the user's order.
///
/// If a future iOS release starts emitting ViewBuilder actions in declaration
/// order, flip `compensatesReversedEmission` to `false` — that ONE constant is
/// the entire fix, everywhere, and its name tells you what it was for.
///
/// Scope: this compensates order for user-configurable Quick Action lists
/// (`[QuickActionItem]` arrays). It deliberately does NOT touch the default
/// double-tap or hint derivations — those must keep reading the UN-reversed
/// `actions.first`, which is still the user's first configured action.
enum QuickActionsRotor {
    /// `true` while the OS reverses `.accessibilityActions` ViewBuilder
    /// children in the rotor (every iOS release as of #572). Flip to `false`
    /// if the OS ever announces them in declaration order.
    static let compensatesReversedEmission = true

    /// The order to DECLARE actions in so VoiceOver ANNOUNCES them in the
    /// user's configured order.
    static func declarationOrder(_ actions: [QuickActionItem]) -> [QuickActionItem] {
        compensatesReversedEmission ? actions.reversed() : actions
    }
}

extension View {
    /// Exposes `actions` as VoiceOver custom actions (the Actions rotor) so the
    /// rotor announces them in the user's configured order, compensating for
    /// the OS's reversed emission — see ``QuickActionsRotor``.
    ///
    /// Use this for every user-configurable Quick Action list. Never hand a
    /// `[QuickActionItem]` array to `.accessibilityActions` with a raw
    /// `ForEach`, or the rotor reads it backwards (#572).
    func quickActionsRotor(_ actions: [QuickActionItem]) -> some View {
        accessibilityActions {
            ForEach(QuickActionsRotor.declarationOrder(actions)) { action in
                Button(action.label) { action.run() }
            }
        }
    }
}
