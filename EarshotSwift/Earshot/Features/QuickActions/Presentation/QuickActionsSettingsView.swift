import SwiftUI

/// Configures the Quick Action order and visibility for each of the three content
/// sets. The first VISIBLE action in a set is its default double-tap; the rest of
/// the visible actions populate that content's VoiceOver Actions rotor. Reordering
/// and hiding both apply immediately.
///
/// Sighted users reorder by dragging in Edit mode. Because that long-press drag
/// is inoperable with VoiceOver (no non-drag way to move a row), each row also
/// carries Move to top / up / down / to bottom in its Actions rotor — the same
/// non-drag reorder pattern the Queue screen uses (#523).
///
/// Removal is HIDE, never delete (#524): a hidden action stays in its list,
/// clearly labelled "Hidden", and its rotor carries a Restore action. Hiding is
/// refused when it would remove the last enabled action, so every set always
/// keeps at least one default double-tap.
struct QuickActionsSettingsView: View {
    @Environment(QuickActionStore.self) private var store

    /// Keeps VoiceOver focus on a row after a rotor action so the user stays
    /// oriented. One binding serves all three sets, but the focus value is
    /// namespaced by section title (see `focusID`) because the raw action ids
    /// DO collide across sets (e.g. `playNow` and `openShowNotes` appear in both
    /// the Episode and Queue sets, `share` in both Episode and Podcast). Without
    /// the namespace, an action in one section could land focus on a same-ided
    /// row in another section.
    @AccessibilityFocusState private var focusedActionID: String?

    var body: some View {
        List {
            Section {
                Text("The first visible action in each list is the default double-tap; the rest of the visible actions fill the VoiceOver Actions rotor on that kind of row. Choose Edit, then drag a row to reorder, or use the row's VoiceOver actions to move it or to remove and restore it. Changes apply immediately.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            reorderableSection(
                "Episode actions", store.episodeActions, label: \.label,
                isHidden: { store.isEpisodeActionHidden($0) },
                move: { store.moveEpisodeActions(from: $0, to: $1) },
                setHidden: { store.setEpisodeActionHidden($0, hidden: $1) }
            )
            reorderableSection(
                "Podcast actions", store.podcastActions, label: \.label,
                isHidden: { store.isPodcastActionHidden($0) },
                move: { store.movePodcastActions(from: $0, to: $1) },
                setHidden: { store.setPodcastActionHidden($0, hidden: $1) }
            )
            reorderableSection(
                "Queue actions", store.queueActions, label: \.label,
                isHidden: { store.isQueueActionHidden($0) },
                move: { store.moveQueueActions(from: $0, to: $1) },
                setHidden: { store.setQueueActionHidden($0, hidden: $1) }
            )
        }
        .navigationTitle("Quick Actions")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
        }
    }

    /// A titled, reorderable section. Each row announces its position, whether it
    /// is hidden, and whether it's the default action, so VoiceOver users can tell
    /// what their changes did — the whole point of this screen. The drag handle
    /// (`.onMove`) stays for sighted users; the rotor move + remove/restore
    /// actions are additive.
    private func reorderableSection<A: Identifiable>(
        _ title: String,
        _ actions: [A],
        label: KeyPath<A, String>,
        isHidden: @escaping (A) -> Bool,
        move: @escaping (IndexSet, Int) -> Void,
        setHidden: @escaping (A, Bool) -> Bool
    ) -> some View where A.ID == String {
        // The default double-tap is the first VISIBLE action in the set.
        let defaultID = actions.first(where: { !isHidden($0) })?.id

        return Section(title) {
            ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                let name = action[keyPath: label]
                let hidden = isHidden(action)
                // Namespace the focus value by section so an action in this
                // section can't steal focus onto a same-ided row in another.
                let focusID = "\(title).\(action.id)"
                row(name: name, hidden: hidden)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(rowLabel(name, hidden: hidden, isDefault: action.id == defaultID, index: index, count: actions.count))
                    .accessibilityHint("Reorderable in Edit mode. Use the actions rotor to move it, or to remove it from — or restore it to — Quick Actions.")
                    .accessibilityFocused($focusedActionID, equals: focusID)
                    .accessibilityActions {
                        ForEach(QuickActionMoveLogic.targets(index: index, count: actions.count), id: \.label) { target in
                            Button(target.label) {
                                move(IndexSet(integer: index), target.destinationOffset)
                                Announcer.announce("Moved \(name) to position \(target.resultingIndex + 1) of \(actions.count)")
                                focusedActionID = focusID
                            }
                        }
                        if hidden {
                            Button("Restore to Quick Actions") {
                                _ = setHidden(action, false)
                                Announcer.announce("Restored \(name) to Quick Actions")
                                focusedActionID = focusID
                            }
                        } else {
                            Button("Remove from Quick Actions") {
                                if setHidden(action, true) {
                                    Announcer.announce("Removed \(name) from Quick Actions")
                                } else {
                                    Announcer.announce("At least one Quick Action must remain")
                                }
                                focusedActionID = focusID
                            }
                        }
                    }
            }
            .onMove { move($0, $1) }
        }
    }

    /// The visible row: the action name, plus a plain-text "Hidden" tag so the
    /// hidden state is conveyed in words (not colour alone) for sighted users too.
    @ViewBuilder
    private func row(name: String, hidden: Bool) -> some View {
        if hidden {
            HStack {
                Text(name).foregroundStyle(.secondary)
                Spacer()
                Text("Hidden")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text(name)
        }
    }

    private func rowLabel(_ label: String, hidden: Bool, isDefault: Bool, index: Int, count: Int) -> String {
        let state = hidden ? "hidden" : (isDefault ? "visible, default action" : "visible")
        return "\(label), \(state), position \(index + 1) of \(count)"
    }
}
