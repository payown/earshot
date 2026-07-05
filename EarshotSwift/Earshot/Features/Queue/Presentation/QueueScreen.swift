import SwiftUI
import SwiftData

/// The play queue. Flat or grouped-by-podcast, with drag reorder for sighted
/// users and a full set of VoiceOver custom actions so reordering never depends
/// on a drag gesture. Flat mode offers Move to top / up / down / to bottom over
/// absolute position. Grouped mode offers Move up / down that reorder within the
/// row's podcast group (top/bottom are ambiguous across groups, so they're
/// dropped), and the group heading exposes Play Group, Move Group Up / Down,
/// Sort Newest First, Sort Oldest First, and Shuffle Group in the actions rotor.
struct QueueScreen: View {
    @Environment(\.modelContext) private var context
    @Environment(PlayerService.self) private var player
    @Environment(QuickActionStore.self) private var quickActions
    @Environment(SettingsStore.self) private var settings

    @Query(sort: \QueueItem.position) private var items: [QueueItem]

    @State private var showNotesEpisode: Episode?
    // The in-place `.searchable` filter (#457, Part A). Pure presentation: the
    // queue itself is never touched — rows are hidden from display only.
    @State private var searchText = ""
    @AccessibilityFocusState private var focusedEpisode: PersistentIdentifier?
    @AccessibilityFocusState private var focusedGroup: PersistentIdentifier?

    private var repo: QueueRepository { QueueRepository(context: context) }
    private var episodes: [Episode] { items.compactMap(\.episode) }

    /// Whether the search field holds a real (non-whitespace) query. Gates the
    /// no-match state and disables drag reorder / Edit while filtering, since
    /// move indices against a partial list would be wrong (#457).
    private var searchActive: Bool { EpisodeSearchFilter.isActive(searchText) }

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
            // Mirrors the Inbox pattern (#422): a plain `navigationTitle` keeps the
            // bar's title identity (back-button context) while `.inline` collapses
            // the large title out of the scrollable content area. The visible,
            // heading-trait "Queue" rides on the `.principal` toolbar item below.
            // Without this, the large title lives in the content area and VoiceOver
            // sweeps the trailing "Queue options" bar item before reaching it, so
            // options was announced before the heading (#490).
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
            // In-place search filter (#457, Part A). Standard accessible
            // `.searchable` field; the match count is announced on SUBMIT only —
            // never per keystroke, never while the field is empty — while the
            // list itself narrows live as the user types.
            .searchable(text: $searchText, prompt: "Search queue")
            .onSubmit(of: .search) { announceMatches() }
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
        } else if searchActive && EpisodeSearchFilter.filter(episodes, query: searchText).isEmpty {
            // A search is active and nothing in the queue matches — covers both
            // flat and grouped modes (a group survives filtering only if one of
            // its episodes matches, so no-match overall means no groups either).
            NoSearchMatchesView(query: searchText)
        } else if settings.groupQueueEpisodes {
            groupedList
        } else {
            flatList
        }
    }

    // MARK: Flat

    private var flatList: some View {
        // Filter WITHOUT re-numbering: `index` stays each row's position in the
        // full queue, so a filtered row still speaks its true "position X of Y"
        // (#457) — X is where the episode actually sits, Y the whole queue.
        // With no search active this passes every row through unchanged.
        let indexed = Array(episodes.enumerated()).filter {
            EpisodeSearchFilter.matches($0.element, query: searchText)
        }
        return List {
            ForEach(indexed, id: \.element.persistentModelID) { index, episode in
                row(episode, position: index + 1, total: episodes.count, moveMode: .flat)
            }
            // Drag reorder is suspended while a search narrows the list: move
            // destination indices refer to the visible subset, not real queue
            // positions, so a drop would land in the wrong place. The rotor
            // move actions (which address the real queue) keep working.
            .onMove(perform: searchActive ? nil : handleMove)
        }
    }

    // MARK: Grouped

    private var groupedList: some View {
        // Filter within each group and hide groups the search empties (#457).
        // The header's "N episodes" count then reflects the visible rows, which
        // is what a VoiceOver user is about to traverse.
        let groups: [QueueGroup] = repo.groupedQueue().compactMap { group in
            let matching = EpisodeSearchFilter.filter(group.episodes, query: searchText)
            guard !matching.isEmpty else { return nil }
            return QueueGroup(podcast: group.podcast, episodes: matching)
        }
        return List {
            ForEach(groups) { group in
                Section {
                    ForEach(group.episodes) { episode in
                        row(episode, position: nil, total: nil, moveMode: .grouped)
                    }
                } header: {
                    groupHeader(group)
                }
            }
        }
    }

    /// A single heading element per group. It carries the `.isHeader` trait and
    /// is announced as "[Podcast], N episodes". The six group-level actions
    /// (Play Group, Move Group Up/Down, Sort Newest/Oldest First, Shuffle Group)
    /// live in the VoiceOver Actions rotor on this one element — no second focusable
    /// button — so reordering and playback never depend on a drag gesture.
    /// The explicit `.accessibilityLabel` overrides the child `Text`, so only
    /// one heading node exists (the SwiftUI analogue of the explicit-label +
    /// ExcludeSemantics pattern). Only Play Group starts audio; the three
    /// sort/shuffle actions reorder the group in place without starting playback.
    private func groupHeader(_ group: QueueGroup) -> some View {
        let count = group.episodes.count
        let countPhrase = count == 1 ? "1 episode" : "\(count) episodes"
        let podcastID = group.podcast.persistentModelID

        return Text(group.podcast.title)
            .accessibilityLabel("\(group.podcast.title), \(countPhrase)")
            .accessibilityAddTraits(.isHeader)
            .accessibilityFocused($focusedGroup, equals: podcastID)
            // Routed through the shared helper so the rotor announces Play
            // Group first and Shuffle Group last — the designed order — despite
            // the OS's reversed emission (#572, #577).
            .rotorActions(groupHeaderActions(group, podcastID: podcastID))
    }

    /// The group header's rotor actions in DESIGNED announce order. Play Group
    /// starts playback; the move and sort/shuffle actions only reorder in place
    /// (their @discardableResult Episode?, where any, is ignored) — they never
    /// start audio.
    private func groupHeaderActions(
        _ group: QueueGroup, podcastID: PersistentIdentifier
    ) -> [QuickActionItem] {
        [
            QuickActionItem(label: "Play Group", isDestructive: false) {
                if let episode = repo.playGroup(group.podcast) {
                    player.play(episode)
                    Announcer.announce("Playing \(group.podcast.title)")
                }
            },
            QuickActionItem(label: "Move Group Up", isDestructive: false) {
                // Announce + refocus only on a real move; an edge no-op
                // (group already first / last) must stay silent.
                if repo.moveGroupUp(group.podcast) {
                    Announcer.announce("Moved \(group.podcast.title) up")
                    focusedGroup = podcastID
                }
            },
            QuickActionItem(label: "Move Group Down", isDestructive: false) {
                if repo.moveGroupDown(group.podcast) {
                    Announcer.announce("Moved \(group.podcast.title) down")
                    focusedGroup = podcastID
                }
            },
            QuickActionItem(label: "Sort Newest First", isDestructive: false) {
                repo.playNewestFirst(group.podcast)
                Announcer.announce("Sorted newest first")
            },
            QuickActionItem(label: "Sort Oldest First", isDestructive: false) {
                repo.playOldestFirst(group.podcast)
                Announcer.announce("Sorted oldest first")
            },
            QuickActionItem(label: "Shuffle Group", isDestructive: false) {
                repo.shuffleGroup(group.podcast)
                Announcer.announce("Shuffled")
            },
        ]
    }

    // MARK: Row

    private func row(_ episode: Episode, position: Int?, total: Int?, moveMode: QueueMoveMode) -> some View {
        QueueRow(
            episode: episode,
            position: position,
            total: total,
            focusedEpisode: $focusedEpisode,
            actions: buildQueueActions(
                episode: episode,
                order: quickActions.queueActions,
                moveMode: moveMode,
                player: player,
                context: context,
                onShowNotes: { showNotesEpisode = episode },
                onFocus: { focusedEpisode = $0 },
                // The queue AS DISPLAYED (#457): with a search active, the
                // post-remove focus neighbor must be the adjacent VISIBLE row —
                // a hidden row's id matches no rendered element, so focus would
                // be dropped. With no search the filter passes the full queue
                // through unchanged, preserving the original behavior.
                visibleQueue: {
                    EpisodeSearchFilter.filter(repo.queue(), query: searchText)
                }
            )
        )
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // The on-screen "Queue" heading. A `.principal` bar element is traversed
        // before the trailing "Queue options", so the heading is announced first
        // (and carries the heading trait). Mirrors InboxScreen's principal heading.
        ToolbarItem(placement: .principal) {
            Text("Queue")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
        }
        // Edit (drag reorder) is hidden while a search is active, matching the
        // suspended `.onMove` — reordering a partial view of the queue would
        // move rows to the wrong real positions (#457).
        if !episodes.isEmpty && !settings.groupQueueEpisodes && !searchActive {
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

    // MARK: Search

    /// Announces the search's match count on submit (#457). Guarded so an empty
    /// or whitespace-only field never announces; Announcer itself is a no-op
    /// with VoiceOver off.
    private func announceMatches() {
        guard searchActive else { return }
        let count = EpisodeSearchFilter.filter(episodes, query: searchText).count
        Announcer.announce(EpisodeSearchFilter.resultAnnouncement(count: count))
    }

}

/// One queue row: a single VoiceOver element whose Actions rotor is the user's
/// configured queue Quick Actions (in order), so a screen-reader user can play,
/// reorder, or remove without a drag gesture. Swipe exposes the destructive
/// actions; the context menu exposes the non-default ones.
private struct QueueRow: View {
    // Requires SettingsStore in the environment (injected at the app root); every
    // QueueRow renders under QueueScreen, which is under that root. Gates the
    // opt-in season/episode numbering (#452).
    @Environment(SettingsStore.self) private var settings
    let episode: Episode
    let position: Int?
    let total: Int?
    @AccessibilityFocusState.Binding var focusedEpisode: PersistentIdentifier?
    let actions: [QuickActionItem]

    var body: some View {
        let primary = actions.first
        // Castro-style "X min left" / total length, the same treatment EpisodeRow
        // gives every other list. The Queue was the original surface this was
        // requested for but #493 only reached the shared row, not this bespoke
        // one (#504). Cheap arithmetic, safe to evaluate per realization.
        let timeText = EpisodeTimeLogic.visibleText(
            positionSeconds: episode.positionSeconds,
            durationSeconds: episode.durationSeconds,
            isPlayed: episode.isPlayed
        )

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
                // Season/episode badge ("S2 · E14"), matching EpisodeRow. Shown
                // only when the user opted in (off by default) and the feed
                // provides numbers; the spoken form is folded into the label below
                // so this visible Text isn't announced separately (#452).
                if settings.showEpisodeNumbers,
                   let numberBadge = EpisodeRowLabel.numberBadge(
                       season: episode.seasonNumber, episode: episode.episodeNumber
                   ) {
                    Text(numberBadge)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                // Time-left / total length, matching EpisodeRow's caption +
                // secondary treatment. Absent (nil) for a played or
                // unknown-duration episode, so no "--" artifact shows.
                if let timeText {
                    Text(timeText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                // Downloaded / streaming indicator (#513), matching EpisodeRow.
                // Hidden from VoiceOver inside the badge — the spoken state is
                // folded into this row's single `accessibilityLabel` below.
                DownloadStateBadge(status: episode.downloadStatus)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // A Button is already a single accessibility element with the button
        // trait, so combining its children just made VoiceOver re-walk and merge
        // the label subtree only for the explicit `.accessibilityLabel` below to
        // discard it — wasted work on every focus move. Dropping it keeps the
        // identical label/hint/actions/focus while removing that per-row cost. (#479)
        .accessibilityLabel(accessibilityLabel)
        // VoiceOver value carries the spoken time-left/length (#493/#504). The
        // label stays title-first (title, podcast, position) so quick flicking
        // still leads with the title; the time rides as the value, where a user
        // who dwells hears it without it bloating the label. Applied only when
        // there's something to speak: `.accessibilityValue("")` makes VoiceOver
        // utter a stray pause, so a played/unknown-duration row omits it.
        .accessibilityValueIfPresent(accessibilityValue)
        .accessibilityHint(primary.map { "Double tap to \($0.label.lowercased())" } ?? "")
        .accessibilityFocused($focusedEpisode, equals: episode.persistentModelID)
        // Rotor order goes through the shared helper, which compensates for the
        // OS emitting `.accessibilityActions` children in reverse (#572). The
        // default double-tap and hint above keep the UN-reversed `actions.first`.
        .quickActionsRotor(actions)
        .modifier(SightedRowActions(actions: actions))
    }

    private var accessibilityLabel: String {
        var parts = [episode.title]
        if let podcast = episode.podcast?.title {
            parts.append(podcast)
        }
        // Spoken "Season 2, Episode 14" when opted in, after the show name and
        // before position — matching EpisodeRow's order (#452).
        if settings.showEpisodeNumbers,
           let numbering = EpisodeRowLabel.spokenNumber(
               season: episode.seasonNumber, episode: episode.episodeNumber
           ) {
            parts.append(numbering)
        }
        if let position, let total {
            parts.append("position \(position) of \(total)")
        }
        // Downloaded / streaming state, last, matching EpisodeRow's order (#513).
        // Folded into this single label so it never becomes a separate stop.
        parts.append(EpisodeRowLabel.spokenDownloadState(episode.downloadStatus))
        return parts.joined(separator: ", ")
    }

    /// The row's VoiceOver value: the spoken time-left/length (#493/#504), or an
    /// empty string when the episode is played or has no known duration, so
    /// VoiceOver announces no stray value.
    private var accessibilityValue: String {
        EpisodeTimeLogic.spokenText(
            positionSeconds: episode.positionSeconds,
            durationSeconds: episode.durationSeconds,
            isPlayed: episode.isPlayed
        ) ?? ""
    }
}

private extension View {
    /// Applies `.accessibilityValue` only when there's something to say. An empty
    /// value string makes VoiceOver speak a stray pause (dead air), so callers
    /// with no value to communicate must omit the modifier entirely rather than
    /// set "".
    @ViewBuilder
    func accessibilityValueIfPresent(_ value: String) -> some View {
        if value.isEmpty {
            self
        } else {
            accessibilityValue(value)
        }
    }
}

/// Swipe-to-delete and the context menu for sighted users. SwiftUI promotes both
/// swipe and context-menu items into the VoiceOver Actions rotor, which duplicated
/// every action already listed by `.accessibilityActions` (the reported "Remove
/// from queue" appearing twice). With VoiceOver running these are redundant, so
/// they're omitted — leaving `.accessibilityActions` as the single rotor source.
private struct SightedRowActions: ViewModifier {
    let actions: [QuickActionItem]
    // Tracked by SwiftUI, so toggling VoiceOver while the Queue is on screen
    // re-evaluates and removes/restores the swipe + context actions immediately
    // (reading UIAccessibility.isVoiceOverRunning in body would not invalidate).
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    func body(content: Content) -> some View {
        if voiceOverEnabled {
            content
        } else {
            content
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
    }
}
