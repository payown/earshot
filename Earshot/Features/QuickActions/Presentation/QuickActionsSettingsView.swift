import SwiftUI

/// Configures the Quick Action order for each of the three content sets. The
/// first action in a set is its default double-tap; the rest populate that
/// content's VoiceOver Actions rotor. Reordering applies immediately.
///
/// Sighted users reorder by dragging in Edit mode. Because that long-press drag
/// is inoperable with VoiceOver (no non-drag way to move a row), each row also
/// carries Move to top / up / down / to bottom in its Actions rotor — the same
/// non-drag reorder pattern the Queue screen uses (#523).
struct QuickActionsSettingsView: View {
    @Environment(QuickActionStore.self) private var store

    /// Keeps VoiceOver focus on a row after a rotor move so the user stays
    /// oriented. One binding serves all three sets, but the focus value is
    /// namespaced by section title (see `focusID`) because the raw action ids
    /// DO collide across sets (e.g. `playNow` and `openShowNotes` appear in both
    /// the Episode and Queue sets, `share` in both Episode and Podcast). Without
    /// the namespace, moving a row in one section could land focus on a
    /// same-ided row in another section.
    @AccessibilityFocusState private var focusedActionID: String?

    var body: some View {
        List {
            Section {
                Text("The first action in each list is the default double-tap; the rest fill the VoiceOver Actions rotor on that kind of row. Choose Edit, then drag a row to reorder, or use the row's VoiceOver actions to move it. Changes apply immediately.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            reorderableSection("Episode actions", store.episodeActions, label: \.label) {
                store.moveEpisodeActions(from: $0, to: $1)
            }
            reorderableSection("Podcast actions", store.podcastActions, label: \.label) {
                store.movePodcastActions(from: $0, to: $1)
            }
            reorderableSection("Queue actions", store.queueActions, label: \.label) {
                store.moveQueueActions(from: $0, to: $1)
            }
        }
        .navigationTitle("Quick Actions")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
        }
    }

    /// A titled, reorderable section. Each row announces its position and whether
    /// it's the default action, so VoiceOver users can tell what their reorder
    /// changes — the whole point of this screen. The drag handle (`.onMove`) stays
    /// for sighted users; the rotor move actions are additive.
    private func reorderableSection<A: Identifiable>(
        _ title: String,
        _ actions: [A],
        label: KeyPath<A, String>,
        move: @escaping (IndexSet, Int) -> Void
    ) -> some View where A.ID == String {
        Section(title) {
            ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                let name = action[keyPath: label]
                // Namespace the focus value by section so a move in this section
                // can't steal focus onto a same-ided row in another section.
                let focusID = "\(title).\(action.id)"
                Text(name)
                    .accessibilityLabel(rowLabel(name, index: index, count: actions.count))
                    .accessibilityHint("Reorderable in Edit mode. Position 1 is the default action. Use the actions rotor to move without dragging.")
                    .accessibilityFocused($focusedActionID, equals: focusID)
                    // Routed through the shared helper so the rotor announces
                    // "Move to top" first — the same order the compensated Queue
                    // rows use — despite the OS's reversed emission (#572, #577).
                    // `QuickActionMoveLogic.targets` already returns the designed
                    // order.
                    .rotorActions(
                        QuickActionMoveLogic.targets(index: index, count: actions.count)
                            .map { target in
                                QuickActionItem(id: target.label, label: target.label, isDestructive: false) {
                                    move(IndexSet(integer: index), target.destinationOffset)
                                    Announcer.announce("Moved \(name) to position \(target.resultingIndex + 1) of \(actions.count)")
                                    focusedActionID = focusID
                                }
                            }
                    )
            }
            .onMove { move($0, $1) }
        }
    }

    private func rowLabel(_ label: String, index: Int, count: Int) -> String {
        index == 0
            ? "\(label), default action, position 1 of \(count)"
            : "\(label), position \(index + 1) of \(count)"
    }
}
