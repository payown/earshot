import SwiftUI
import SwiftData

/// The play queue. Flat or grouped-by-podcast, with drag reorder for sighted
/// users and a full set of VoiceOver custom actions (move to top / up / down /
/// to bottom / remove) so reordering never depends on a drag gesture. Move
/// actions are offered only in flat mode, where position is unambiguous; in
/// grouped mode reordering is at the group level ("Play group").
struct QueueScreen: View {
    @Environment(\.modelContext) private var context
    @Environment(PlayerService.self) private var player
    @Environment(QuickActionStore.self) private var quickActions

    @Query(sort: \QueueItem.position) private var items: [QueueItem]

    @State private var groupByPodcast = false
    @State private var showNotesEpisode: Episode?
    @State private var sharingEpisode: Episode?
    @AccessibilityFocusState private var focusedEpisode: PersistentIdentifier?

    private var repo: QueueRepository { QueueRepository(context: context) }
    private var episodes: [Episode] { items.compactMap(\.episode) }

    var body: some View {
        content
            .navigationTitle("Queue")
            .toolbar { toolbar }
            .sheet(item: $showNotesEpisode) { ShowNotesView(episode: $0) }
            .sheet(item: $sharingEpisode) { episode in
                ShareSheet(items: shareItems(for: episode))
            }
    }

    @ViewBuilder
    private var content: some View {
        if episodes.isEmpty {
            ContentUnavailableView(
                "Queue is empty",
                systemImage: "list.bullet",
                description: Text("Episodes you add to the queue appear here.")
            )
        } else if groupByPodcast {
            groupedList
        } else {
            flatList
        }
    }

    // MARK: Flat

    private var flatList: some View {
        List {
            ForEach(Array(episodes.enumerated()), id: \.element.persistentModelID) { index, episode in
                row(episode, position: index + 1, total: episodes.count, showsMoveActions: true)
            }
            .onMove(perform: handleMove)
        }
    }

    // MARK: Grouped

    private var groupedList: some View {
        List {
            ForEach(repo.groupedQueue()) { group in
                Section {
                    ForEach(group.episodes) { episode in
                        row(episode, position: nil, total: nil, showsMoveActions: false)
                    }
                } header: {
                    groupHeader(group)
                }
            }
        }
    }

    private func groupHeader(_ group: QueueGroup) -> some View {
        HStack {
            Text(group.podcast.title)
            Spacer()
            Button {
                repo.playGroup(group.podcast)
                Announcer.announce("Moved \(group.podcast.title) to the front of the queue")
            } label: {
                Text("Play group")
            }
            .accessibilityLabel("Play \(group.podcast.title) group")
            .accessibilityHint("Moves these episodes to the front of the queue")
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: Row

    private func row(_ episode: Episode, position: Int?, total: Int?, showsMoveActions: Bool) -> some View {
        QueueRow(
            episode: episode,
            position: position,
            total: total,
            showsMoveActions: showsMoveActions,
            focusedEpisode: $focusedEpisode,
            episodeActions: buildEpisodeActions(
                episode: episode,
                order: quickActions.actions,
                player: player,
                context: context,
                onShowNotes: { showNotesEpisode = episode },
                onShare: { sharingEpisode = episode }
            ),
            onMoveToTop: { move(episode, repo.moveToTop, "Moved \(episode.title) to top") },
            onMoveUp: { move(episode, repo.moveUp, "Moved \(episode.title) up") },
            onMoveDown: { move(episode, repo.moveDown, "Moved \(episode.title) down") },
            onMoveToBottom: { move(episode, repo.moveToBottom, "Moved \(episode.title) to bottom") },
            onRemove: { remove(episode) }
        )
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if !episodes.isEmpty && !groupByPodcast {
            ToolbarItem(placement: .topBarLeading) { EditButton() }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Toggle(isOn: $groupByPodcast) {
                    Label("Group by podcast", systemImage: "rectangle.3.group")
                }
                if !episodes.isEmpty {
                    Button(role: .destructive) {
                        repo.clear()
                        Announcer.announce("Queue cleared")
                    } label: {
                        Label("Clear queue", systemImage: "trash")
                    }
                }
            } label: {
                Label("Queue options", systemImage: "ellipsis.circle")
            }
        }
    }

    // MARK: Mutations (with VoiceOver focus + announcements)

    /// Applies a move, announces it, and keeps VoiceOver focus on the moved
    /// episode so the user stays oriented after the list re-renders.
    private func move(_ episode: Episode, _ apply: (Episode) -> Void, _ announcement: String) {
        apply(episode)
        Announcer.announce(announcement)
        focusedEpisode = episode.persistentModelID
    }

    /// Removes an episode, announces which one, and moves focus to the row that
    /// takes its place (or the previous one, or nothing when the queue empties).
    private func remove(_ episode: Episode) {
        let nextFocus = neighborID(of: episode, in: episodes)
        repo.cancelFromQueue(episode)
        Announcer.announce("Removed \(episode.title) from the queue")
        focusedEpisode = nextFocus
    }

    private func handleMove(_ from: IndexSet, _ to: Int) {
        guard let source = from.first else { return }
        let episode = episodes[source]
        repo.move(episode, toIndex: to > source ? to - 1 : to)
        focusedEpisode = episode.persistentModelID
    }

    /// The id of the row that should receive focus once `episode` leaves the
    /// list: the next item, else the previous, else nil (queue emptied).
    private func neighborID(of episode: Episode, in list: [Episode]) -> PersistentIdentifier? {
        guard let idx = list.firstIndex(where: { $0.persistentModelID == episode.persistentModelID })
        else { return nil }
        if idx + 1 < list.count { return list[idx + 1].persistentModelID }
        if idx > 0 { return list[idx - 1].persistentModelID }
        return nil
    }

    private func shareItems(for episode: Episode) -> [Any] {
        if let url = URL(string: episode.audioURL) {
            return [episode.title, url]
        }
        return [episode.title]
    }
}

/// One queue row. The whole row is a single VoiceOver element carrying the
/// episode's quick actions plus queue-management actions, so a screen-reader
/// user can reorder without ever needing the drag gesture.
private struct QueueRow: View {
    let episode: Episode
    let position: Int?
    let total: Int?
    let showsMoveActions: Bool
    @AccessibilityFocusState.Binding var focusedEpisode: PersistentIdentifier?
    let episodeActions: [EpisodeActionItem]
    let onMoveToTop: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onMoveToBottom: () -> Void
    let onRemove: () -> Void

    var body: some View {
        let primary = episodeActions.first

        Button {
            primary?.run()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(episode.title)
                    .font(.body)
                    .multilineTextAlignment(.leading)
                if let podcast = episode.podcast?.title {
                    Text(podcast)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(primary.map { "Double tap to \($0.label.lowercased())" } ?? "")
        .accessibilityFocused($focusedEpisode, equals: episode.persistentModelID)
        .accessibilityActions {
            ForEach(episodeActions) { action in
                Button(action.label) { action.run() }
            }
            if showsMoveActions {
                Button("Move to top") { onMoveToTop() }
                Button("Move up") { onMoveUp() }
                Button("Move down") { onMoveDown() }
                Button("Move to bottom") { onMoveToBottom() }
            }
            Button("Remove from queue") { onRemove() }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive, action: onRemove) {
                Label("Remove", systemImage: "minus.circle")
            }
        }
        .contextMenu {
            if showsMoveActions {
                Button(action: onMoveToTop) { Label("Move to Top", systemImage: "arrow.up.to.line") }
                Button(action: onMoveToBottom) { Label("Move to Bottom", systemImage: "arrow.down.to.line") }
            }
            Button(role: .destructive, action: onRemove) {
                Label("Remove from Queue", systemImage: "minus.circle")
            }
        }
    }

    private var accessibilityLabel: String {
        var parts = [episode.title]
        if let podcast = episode.podcast?.title {
            parts.append(podcast)
        }
        if let position, let total {
            parts.append("position \(position) of \(total)")
        }
        return parts.joined(separator: ", ")
    }
}
