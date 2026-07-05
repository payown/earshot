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
/// Scope: this compensates rotor ORDER for every `.accessibilityActions` site
/// in the app — user-configurable Quick Action lists and fixed action sets
/// alike (#577 generalized it beyond the `[QuickActionItem]` pipelines that
/// #573 fixed). It deliberately does NOT touch the default double-tap or hint
/// derivations — those must keep reading the UN-reversed `actions.first`,
/// which is still the user's first configured action.
enum QuickActionsRotor {
    /// `true` while the OS reverses `.accessibilityActions` ViewBuilder
    /// children in the rotor (every iOS release as of #572). Flip to `false`
    /// if the OS ever announces them in declaration order.
    static let compensatesReversedEmission = true

    /// The order to DECLARE actions in so VoiceOver ANNOUNCES them in the
    /// designed (or user-configured) order. Generic so fixed action sets and
    /// `[QuickActionItem]` arrays flow through the same constant.
    static func declarationOrder<T>(_ actions: [T]) -> [T] {
        compensatesReversedEmission ? actions.reversed() : actions
    }
}

extension View {
    /// Exposes `actions` as VoiceOver custom actions (the Actions rotor) so the
    /// rotor announces them in the order the array lists them, compensating for
    /// the OS's reversed emission — see ``QuickActionsRotor``.
    ///
    /// This is the ONE way to attach custom rotor actions in Earshot. Build the
    /// actions as an array in the DESIGNED order (conditionals and all), then
    /// hand it here. Never call `.accessibilityActions` with a raw ViewBuilder,
    /// or the rotor reads the actions backwards (#572, #577).
    func rotorActions(_ actions: [QuickActionItem]) -> some View {
        accessibilityActions {
            ForEach(QuickActionsRotor.declarationOrder(actions)) { action in
                Button(action.label) { action.run() }
            }
        }
    }

    /// Exposes a user-configurable Quick Action list as VoiceOver custom
    /// actions in the user's configured order. Same compensation as
    /// ``rotorActions(_:)`` — this name exists so Quick Action call sites read
    /// as what they are. Never hand a `[QuickActionItem]` array to
    /// `.accessibilityActions` with a raw `ForEach` (#572).
    func quickActionsRotor(_ actions: [QuickActionItem]) -> some View {
        rotorActions(actions)
    }
}
