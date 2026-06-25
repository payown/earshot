import SwiftUI
import SwiftData

/// The play queue. Flat or grouped-by-podcast, with drag reorder for sighted
/// users and a full set of VoiceOver custom actions (move to top / up / down /
/// to bottom / remove) so reordering never depends on a drag gesture. Move
/// actions are offered only in flat mode, where position is unambiguous; in
/// grouped mode the group heading exposes four group-level actions (Play Group,
/// Play Newest First, Play Oldest First, Shuffle Group) in the actions rotor.
struct QueueScreen: View {
    @Environment(\.modelContext) private var context
    @Environment(PlayerService.self) private var player
    @Environment(QuickActionStore.self) private var quickActions
    @Environment(SettingsStore.self) private var settings

    @Query(sort: \QueueItem.position) private var items: [QueueItem]

    @State private var showNotesEpisode: Episode?
    @AccessibilityFocusState private var focusedEpisode: PersistentIdentifier?

    private var repo: QueueRepository { QueueRepository(context: context) }
    private var episodes: [Episode] { items.compactMap(\.episode) }

    /// Drives the grouped-vs-flat display from the persisted
    /// ``SettingsKey/groupQueueEpisodes`` setting, so the choice survives
    /// navigation and relaunch and stays in sync with the App Settings toggle.
    /// Writing through it announces the change for VoiceOver (Flutter parity).
    private var groupByPodcast: Binding<Bool> {
        Binding(
            get: { settings.groupQueueEpisodes },
            set: { newValue in
                settings.groupQueueEpisodes = newValue
                Announcer.announce(newValue ? "Queue grouped by podcast" : "Queue ungrouped")
            }
        )
    }

    var body: some View {
        content
            .navigationTitle("Queue")
            .toolbar { toolbar }
            .sheet(item: $showNotesEpisode) { ShowNotesView(episode: $0) }
    }

    @ViewBuilder
    private var content: some View {
        if episodes.isEmpty {
            ContentUnavailableView(
                "Queue is empty",
                systemImage: "list.bullet",
                description: Text("Episodes you add to the queue appear here.")
            )
        } else if settings.groupQueueEpisodes {
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

    /// A single heading element per group. It carries the `.isHeader` trait and
    /// is announced as "[Podcast], N episodes". The four group-level actions
    /// (Play Group, Play Newest First, Play Oldest First, Shuffle Group) live in
    /// the VoiceOver Actions rotor on this one element — no second focusable
    /// button — so reordering and playback never depend on a drag gesture.
    /// The explicit `.accessibilityLabel` overrides the child `Text`, so only
    /// one heading node exists (the SwiftUI analogue of the explicit-label +
    /// ExcludeSemantics pattern).
    private func groupHeader(_ group: QueueGroup) -> some View {
        let count = group.episodes.count
        let countPhrase = count == 1 ? "1 episode" : "\(count) episodes"

        return Text(group.podcast.title)
            .accessibilityLabel("\(group.podcast.title), \(countPhrase)")
            .accessibilityAddTraits(.isHeader)
            .accessibilityActions {
                Button("Play Group") {
                    if let episode = repo.playGroup(group.podcast) {
                        player.play(episode)
                        Announcer.announce("Playing \(group.podcast.title)")
                    }
                }
                Button("Play Newest First") {
                    if let episode = repo.playNewestFirst(group.podcast) {
                        player.play(episode)
                        Announcer.announce("\(group.podcast.title), newest first")
                    }
                }
                Button("Play Oldest First") {
                    if let episode = repo.playOldestFirst(group.podcast) {
                        player.play(episode)
                        Announcer.announce("\(group.podcast.title), oldest first")
                    }
                }
                Button("Shuffle Group") {
                    if let episode = repo.shuffleGroup(group.podcast) {
                        player.play(episode)
                        Announcer.announce("\(group.podcast.title), shuffled")
                    }
                }
            }
    }

    // MARK: Row

    private func row(_ episode: Episode, position: Int?, total: Int?, showsMoveActions: Bool) -> some View {
        QueueRow(
            episode: episode,
            position: position,
            total: total,
            focusedEpisode: $focusedEpisode,
            actions: buildQueueActions(
                episode: episode,
                order: quickActions.queueActions,
                moveActionsEnabled: showsMoveActions,
                player: player,
                context: context,
                onShowNotes: { showNotesEpisode = episode },
                onFocus: { focusedEpisode = $0 }
            )
        )
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if !episodes.isEmpty && !settings.groupQueueEpisodes {
            ToolbarItem(placement: .topBarLeading) { EditButton() }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Toggle(isOn: groupByPodcast) {
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

    // MARK: Drag reorder

    private func handleMove(_ from: IndexSet, _ to: Int) {
        guard let source = from.first else { return }
        let episode = episodes[source]
        repo.move(episode, toIndex: to > source ? to - 1 : to)
        focusedEpisode = episode.persistentModelID
    }

}

/// One queue row: a single VoiceOver element whose Actions rotor is the user's
/// configured queue Quick Actions (in order), so a screen-reader user can play,
/// reorder, or remove without a drag gesture. Swipe exposes the destructive
/// actions; the context menu exposes the non-default ones.
private struct QueueRow: View {
    let episode: Episode
    let position: Int?
    let total: Int?
    @AccessibilityFocusState.Binding var focusedEpisode: PersistentIdentifier?
    let actions: [QuickActionItem]

    var body: some View {
        let primary = actions.first

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
            ForEach(actions) { action in
                Button(action.label) { action.run() }
            }
        }
        .swipeActions(edge: .trailing) {
            ForEach(actions.filter(\.isDestructive)) { action in
                Button(role: .destructive) { action.run() } label: { Text(action.label) }
            }
        }
        .contextMenu {
            ForEach(actions.dropFirst()) { action in
                Button(role: action.isDestructive ? .destructive : nil) { action.run() } label: {
                    Text(action.label)
                }
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
