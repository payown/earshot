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

/// Context menus do not share the OS rotor's reversed-emission behavior. They
/// must receive the resolved actions in their original order so the visible
/// menu exactly matches Settings and the row's default action (#761).
enum QuickActionsContextMenu {
    static func declarationOrder<T>(_ actions: [T]) -> [T] {
        actions
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

    /// Adds a sighted long-press convenience menu without replacing the row's
    /// primary tap or its VoiceOver Actions rotor. Callers hand this the SAME
    /// resolved array they pass to ``quickActionsRotor(_:)`` / ``rotorActions(_:)``
    /// so labels, availability, destructive roles, and ordering cannot drift.
    @ViewBuilder
    func quickActionsContextMenu(_ actions: [QuickActionItem]) -> some View {
        if actions.isEmpty {
            self
        } else {
            contextMenu {
                ForEach(QuickActionsContextMenu.declarationOrder(actions)) { action in
                    Button(role: action.isDestructive ? .destructive : nil) {
                        action.run()
                    } label: {
                        Text(action.label)
                    }
                }
            }
        }
    }

    /// Lightweight episode-action variant for large lazy lists. The row stores
    /// stable enum identifiers and one shared runner instead of rebuilding a
    /// UUID and captured closure for every action whenever SwiftUI recycles it.
    func episodeActionsRotor(
        _ actions: [EpisodeAction],
        supplementalActions: [EpisodeRowSupplementalAction] = [],
        episode: Episode,
        perform: @escaping (EpisodeAction) -> Void,
        performSupplemental: @escaping (EpisodeRowSupplementalAction) -> Void = { _ in }
    ) -> some View {
        accessibilityActions {
            if QuickActionsRotor.compensatesReversedEmission {
                ForEach(supplementalActions.reversed()) { action in
                    Button(action.label) { performSupplemental(action) }
                }
                ForEach(actions.reversed()) { action in
                    Button(action.label(for: episode)) { perform(action) }
                }
            } else {
                ForEach(actions) { action in
                    Button(action.label(for: episode)) { perform(action) }
                }
                ForEach(supplementalActions) { action in
                    Button(action.label) { performSupplemental(action) }
                }
            }
        }
    }

    /// Sighted long-press companion to ``episodeActionsRotor``. It uses the
    /// same stable action identifiers and shared runner, while preserving the
    /// user's configured order and dynamic destructive roles.
    @ViewBuilder
    func episodeActionsContextMenu(
        _ actions: [EpisodeAction],
        supplementalActions: [EpisodeRowSupplementalAction] = [],
        episode: Episode,
        perform: @escaping (EpisodeAction) -> Void,
        performSupplemental: @escaping (EpisodeRowSupplementalAction) -> Void = { _ in }
    ) -> some View {
        if actions.isEmpty && supplementalActions.isEmpty {
            self
        } else {
            contextMenu {
                ForEach(QuickActionsContextMenu.declarationOrder(actions)) { action in
                    Button(role: action.isDestructive(for: episode) ? .destructive : nil) {
                        perform(action)
                    } label: {
                        Text(action.label(for: episode))
                    }
                }
                ForEach(QuickActionsContextMenu.declarationOrder(supplementalActions)) { action in
                    Button(role: action.isDestructive ? .destructive : nil) {
                        performSupplemental(action)
                    } label: {
                        Text(action.label)
                    }
                }
            }
        }
    }

    /// Stable-enum queue variant used by the potentially unbounded Queue list.
    func queueActionsRotor(
        _ actions: [QueueItemAction],
        episode: Episode,
        perform: @escaping (QueueItemAction) -> Void
    ) -> some View {
        accessibilityActions {
            ForEach(QuickActionsRotor.declarationOrder(actions)) { action in
                Button(action.label(for: episode)) { perform(action) }
            }
        }
    }

    /// Stable-enum podcast variant used by the Library's large lazy list.
    func podcastActionsRotor(
        _ actions: [PodcastAction],
        podcast: Podcast,
        perform: @escaping (PodcastAction) -> Void
    ) -> some View {
        accessibilityActions {
            ForEach(QuickActionsRotor.declarationOrder(actions)) { action in
                Button(action.label(for: podcast)) { perform(action) }
            }
        }
    }

    /// Sighted-only long-press companion for deferred podcast actions.
    @ViewBuilder
    func podcastActionsContextMenu(
        _ actions: [PodcastAction],
        podcast: Podcast,
        perform: @escaping (PodcastAction) -> Void
    ) -> some View {
        if actions.isEmpty {
            self
        } else {
            contextMenu {
                ForEach(QuickActionsContextMenu.declarationOrder(actions)) { action in
                    Button(role: action.isDestructive ? .destructive : nil) {
                        perform(action)
                    } label: {
                        Text(action.label(for: podcast))
                    }
                }
            }
        }
    }
}
