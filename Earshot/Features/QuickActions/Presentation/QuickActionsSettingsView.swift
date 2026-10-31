import SwiftUI

/// Configures ordered Quick Actions for Episode, Podcast, and Queue rows and
/// VoiceOver actions for the full player's transport buttons.
struct QuickActionsSettingsView: View {
    @Environment(QuickActionStore.self) private var store
    @Environment(SettingsStore.self) private var settings
    @AccessibilityFocusState private var focusedActionID: String?

    var body: some View {
        List {
            Section {
                Text("Episode, Podcast, and Queue actions fill the VoiceOver Actions rotor; the first enabled action is the default double-tap. Add, remove, or reorder them. Player skip increments add buttons to the full player. Rewind and Fast-forward actions configure each button's VoiceOver Actions rotor, including chapter and queue navigation; either button can perform either action. You can remove all player actions. A skip matching the primary interval in Playback settings is hidden from the extra-action lists and returns if that interval changes.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            actionSection(content: "Episode", state: .enabled,
                          actions: store.episodeActions, label: \.label,
                          move: store.moveEpisodeActions,
                          transfer: removeEpisodeAction)
            actionSection(content: "Episode", state: .available,
                          actions: store.availableEpisodeActions, label: \.label,
                          move: store.moveAvailableEpisodeActions,
                          transfer: addEpisodeAction)
            actionSection(content: "Podcast", state: .enabled,
                          actions: store.podcastActions, label: \.label,
                          move: store.movePodcastActions,
                          transfer: removePodcastAction)
            actionSection(content: "Podcast", state: .available,
                          actions: store.availablePodcastActions, label: \.label,
                          move: store.moveAvailablePodcastActions,
                          transfer: addPodcastAction)
            actionSection(content: "Queue", state: .enabled,
                          actions: store.queueActions, label: \.label,
                          move: store.moveQueueActions,
                          transfer: removeQueueAction)
            actionSection(content: "Queue", state: .available,
                          actions: store.availableQueueActions, label: \.label,
                          move: store.moveAvailableQueueActions,
                          transfer: addQueueAction)

            let visibleTransportActions = TransportActionVisibility.visible(
                store.transportActions,
                backSeconds: settings.skipBackSeconds,
                forwardSeconds: settings.skipForwardSeconds
            )
            let visibleAvailableTransportActions = TransportActionVisibility.visible(
                store.availableTransportActions,
                backSeconds: settings.skipBackSeconds,
                forwardSeconds: settings.skipForwardSeconds
            )
            actionSection(content: "Player transport", state: .enabled,
                          actions: visibleTransportActions, label: \.label,
                          move: { store.moveTransportActions(from: $0, to: $1, visibleActions: visibleTransportActions) },
                          transfer: store.removeTransportAction,
                          allowsEmptyEnabled: true,
                          hasDefaultAction: false)
            actionSection(content: "Player transport", state: .available,
                          actions: visibleAvailableTransportActions, label: \.label,
                          move: store.moveAvailableTransportActions,
                          transfer: store.addTransportAction,
                          allowsEmptyEnabled: true,
                          hasDefaultAction: false)

            ForEach(PlayerTransportButton.allCases) { button in
                actionSection(
                    content: button.title,
                    state: .enabled,
                    actions: store.playerButtonActions(for: button),
                    label: \.label,
                    move: { store.movePlayerButtonActions(from: $0, to: $1, for: button) },
                    transfer: { store.removePlayerButtonAction($0, from: button) },
                    allowsEmptyEnabled: true,
                    hasDefaultAction: false
                )
                actionSection(
                    content: button.title,
                    state: .available,
                    actions: store.availablePlayerButtonActions(for: button),
                    label: \.label,
                    move: { store.moveAvailablePlayerButtonActions(from: $0, to: $1, for: button) },
                    transfer: { store.addPlayerButtonAction($0, to: button) },
                    allowsEmptyEnabled: true,
                    hasDefaultAction: false
                )
            }
        }
        .navigationTitle("Quick Actions")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
        }
    }

    private func actionSection<A: Identifiable>(
        content: String,
        state: ActionState,
        actions: [A],
        label: KeyPath<A, String>,
        move: @escaping (IndexSet, Int) -> Void,
        transfer: @escaping (A) -> Void,
        allowsEmptyEnabled: Bool = false,
        hasDefaultAction: Bool = true
    ) -> some View where A.ID == String {
        Section("\(content) actions — \(state.title)") {
            if actions.isEmpty {
                Text(state.emptyLabel)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                    let name = action[keyPath: label]
                    let focusID = "\(content).\(action.id)"
                    Text(name)
                        .accessibilityLabel(rowLabel(
                            name, state: state, index: index, count: actions.count,
                            hasDefaultAction: hasDefaultAction
                        ))
                        .accessibilityHint(state.hint(hasDefaultAction: hasDefaultAction))
                        .accessibilityFocused($focusedActionID, equals: focusID)
                        .rotorActions(rowActions(
                            action: action, name: name, focusID: focusID,
                            state: state, index: index, count: actions.count,
                            move: move, transfer: transfer,
                            allowsEmptyEnabled: allowsEmptyEnabled
                        ))
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(state.transferLabel) {
                                transfer(action)
                                announceTransfer(name, state: state)
                                focusedActionID = focusID
                            }
                            .tint(state == .enabled ? .red : .green)
                            .disabled(state == .enabled && actions.count == 1 && !allowsEmptyEnabled)
                        }
                }
                .onMove { move($0, $1) }
            }
        }
    }

    private func rowActions<A: Identifiable>(
        action: A,
        name: String,
        focusID: String,
        state: ActionState,
        index: Int,
        count: Int,
        move: @escaping (IndexSet, Int) -> Void,
        transfer: @escaping (A) -> Void,
        allowsEmptyEnabled: Bool
    ) -> [QuickActionItem] where A.ID == String {
        var items: [QuickActionItem] = []
        if state == .available || count > 1 || allowsEmptyEnabled {
            items.append(QuickActionItem(
                id: state.transferLabel,
                label: state.transferLabel,
                isDestructive: state == .enabled
            ) {
                transfer(action)
                announceTransfer(name, state: state)
                focusedActionID = focusID
            })
        }
        items += QuickActionMoveLogic.targets(index: index, count: count).map { target in
            QuickActionItem(id: target.label, label: target.label, isDestructive: false) {
                move(IndexSet(integer: index), target.destinationOffset)
                Announcer.announce(
                    "Moved \(name) to position \(target.resultingIndex + 1) of \(count)"
                )
                focusedActionID = focusID
            }
        }
        return items
    }

    private func rowLabel(
        _ label: String,
        state: ActionState,
        index: Int,
        count: Int,
        hasDefaultAction: Bool
    ) -> String {
        if state == .enabled, index == 0, hasDefaultAction {
            return "\(label), enabled, default action, position 1 of \(count)"
        }
        return "\(label), \(state.spokenState), position \(index + 1) of \(count)"
    }

    private func announceTransfer(_ name: String, state: ActionState) {
        Announcer.announce(state == .enabled ? "Removed \(name)" : "Added \(name)")
    }

    private func removeEpisodeAction(_ action: EpisodeAction) {
        _ = store.removeEpisodeAction(action)
    }

    private func addEpisodeAction(_ action: EpisodeAction) { store.addEpisodeAction(action) }

    private func removePodcastAction(_ action: PodcastAction) {
        _ = store.removePodcastAction(action)
    }

    private func addPodcastAction(_ action: PodcastAction) { store.addPodcastAction(action) }

    private func removeQueueAction(_ action: QueueItemAction) {
        _ = store.removeQueueAction(action)
    }

    private func addQueueAction(_ action: QueueItemAction) { store.addQueueAction(action) }
}

private enum ActionState: Equatable {
    case enabled
    case available

    var title: String { self == .enabled ? "Enabled" : "Available" }
    var spokenState: String { self == .enabled ? "enabled" : "available" }
    var transferLabel: String { self == .enabled ? "Remove" : "Add" }
    var emptyLabel: String { self == .enabled ? "No enabled actions" : "No available actions" }
    func hint(hasDefaultAction: Bool) -> String {
        if self == .enabled, hasDefaultAction {
            return "Remove or reorder with the Actions rotor. Position 1 is the default action."
        }
        return self == .enabled
            ? "Remove or reorder with the Actions rotor."
            : "Add or reorder with the Actions rotor."
    }
}
