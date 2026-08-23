import SwiftUI

/// Configures the ordered Enabled and Available Quick Actions for Episode,
/// Podcast, and Queue rows. The first enabled action remains the default
/// double-tap; only enabled actions populate the VoiceOver Actions rotor.
struct QuickActionsSettingsView: View {
    @Environment(QuickActionStore.self) private var store
    @AccessibilityFocusState private var focusedActionID: String?

    var body: some View {
        List {
            Section {
                Text("The first enabled action is the default double-tap. Enabled actions fill the VoiceOver Actions rotor. Remove actions you do not use, or add them back from Available. At least one action stays enabled. New actions added by future updates appear in Available after you customize a list.")
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
        transfer: @escaping (A) -> Void
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
                            name, state: state, index: index, count: actions.count
                        ))
                        .accessibilityHint(state.hint)
                        .accessibilityFocused($focusedActionID, equals: focusID)
                        .rotorActions(rowActions(
                            action: action, name: name, focusID: focusID,
                            state: state, index: index, count: actions.count,
                            move: move, transfer: transfer
                        ))
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(state.transferLabel) {
                                transfer(action)
                                announceTransfer(name, state: state)
                                focusedActionID = focusID
                            }
                            .tint(state == .enabled ? .red : .green)
                            .disabled(state == .enabled && actions.count == 1)
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
        transfer: @escaping (A) -> Void
    ) -> [QuickActionItem] where A.ID == String {
        var items: [QuickActionItem] = []
        if state == .available || count > 1 {
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
        count: Int
    ) -> String {
        if state == .enabled, index == 0 {
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
    var hint: String {
        self == .enabled
            ? "Remove or reorder with the Actions rotor. Position 1 is the default action."
            : "Add or reorder with the Actions rotor."
    }
}
