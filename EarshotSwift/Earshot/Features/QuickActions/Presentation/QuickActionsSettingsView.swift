import SwiftUI

/// Configures the Quick Action order for each of the three content sets. The
/// first action in a set is its default double-tap; the rest populate that
/// content's VoiceOver Actions rotor. Reordering applies immediately.
struct QuickActionsSettingsView: View {
    @Environment(QuickActionStore.self) private var store

    var body: some View {
        List {
            Section {
                Text("The first action in each list is the default double-tap; the rest fill the VoiceOver Actions rotor on that kind of row. Choose Edit, then drag a row to reorder. Changes apply immediately.")
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
    /// changes — the whole point of this screen.
    private func reorderableSection<A: Identifiable>(
        _ title: String,
        _ actions: [A],
        label: KeyPath<A, String>,
        move: @escaping (IndexSet, Int) -> Void
    ) -> some View {
        Section(title) {
            ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                Text(action[keyPath: label])
                    .accessibilityLabel(rowLabel(action[keyPath: label], index: index, count: actions.count))
                    .accessibilityHint("Reorderable in Edit mode. Position 1 is the default action.")
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
