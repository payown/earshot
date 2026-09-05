import SwiftUI
import SwiftData

private struct QueueDownloadAllRequest: Identifiable {
    let id = UUID()
    let candidates: [Episode]
    let episodes: [Episode]
    let eligibleCount: Int
    let skippedCount: Int
    let deferredCount: Int
    let scope: String

    init(candidates: [Episode], scope: String) {
        let plan = ManualDownloadBatchPlan.make(statuses: candidates.map(\.downloadStatus))
        self.candidates = candidates
        episodes = plan.selectedIndices.map { candidates[$0] }
        eligibleCount = plan.eligibleCount
        skippedCount = plan.skippedCount
        deferredCount = plan.deferredCount
        self.scope = scope
    }
}

private enum QueueLineupRequest: Identifiable {
    case save(queueCount: Int, replacing: Int)
    case apply(savedCount: Int)
    case clear(savedCount: Int)

    var id: String {
        switch self {
        case .save: "save"
        case .apply: "apply"
        case .clear: "clear"
        }
    }

    var title: String {
        switch self {
        case let .save(queueCount, replacing):
            return replacing > 0
                ? "Replace the saved lineup with \(min(queueCount, QueueLineupStore.maximumEpisodeCount)) episodes?"
                : "Save \(min(queueCount, QueueLineupStore.maximumEpisodeCount)) episodes as a lineup?"
        case let .apply(savedCount):
            return "Apply the saved \(savedCount)-episode lineup?"
        case let .clear(savedCount):
            return "Clear the saved \(savedCount)-episode lineup?"
        }
    }
}

/// The play queue. Flat, grouped by podcast, or grouped by folder, with drag reorder for sighted
/// users and a full set of VoiceOver custom actions so reordering never depends
/// on a drag gesture. Flat mode offers Move to top / up / down / to bottom over
/// absolute position. Grouped mode offers Move up / down that reorder within the
/// row's podcast group (top/bottom are ambiguous across groups, so they're
/// dropped), and the group heading exposes Play Group, Move Group Up / Down,
/// Sort Newest First, Sort Oldest First, and Shuffle Group in the actions rotor.
struct QueueScreen: View {
    @Environment(AppRuntime.self) private var runtime
    @Environment(\.modelContext) private var context
    @Environment(PlayerService.self) private var player
    @Environment(DownloadManager.self) private var downloads
    @Environment(QuickActionStore.self) private var quickActions
    @Environment(SettingsStore.self) private var settings

    @Query(sort: \QueueItem.position) private var items: [QueueItem]

    @State private var confirmingClearQueue = false
    @State private var showNotesEpisode: Episode?
    // The in-place `.searchable` filter (#457, Part A). Pure presentation: the
    // queue itself is never touched — rows are hidden from display only.
    @State private var searchText = ""
    @State private var downloadAllRequest: QueueDownloadAllRequest?
    @State private var lineupRequest: QueueLineupRequest?
    @State private var savedLineupCount = 0
    @State private var isEnrollingDownloads = false
    @AccessibilityFocusState private var focusedEpisode: PersistentIdentifier?
    @AccessibilityFocusState private var focusedGroup: QueueGroup.Kind?
    @AccessibilityFocusState private var focusLaunchHeading: Bool

    private var repo: QueueRepository { QueueRepository(context: context) }
    private var lineupStore: QueueLineupStore { QueueLineupStore(context: context) }
    private var episodes: [Episode] { items.compactMap(\.episode) }

    /// Whether the search field holds a real (non-whitespace) query. Gates the
    /// no-match state and disables drag reorder / Edit while filtering, since
    /// move indices against a partial list would be wrong (#457).
    private var searchActive: Bool { EpisodeSearchFilter.isActive(searchText) }

    /// Drives the three-way display from the persisted
    /// ``SettingsKey/groupQueueEpisodes`` setting, so the choice survives
    /// navigation and relaunch and stays in sync with the App Settings toggle.
    /// Writing through it announces the change for VoiceOver (Flutter parity).
    private var queueGrouping: Binding<QueueGrouping> {
        Binding(
            get: { settings.queueGrouping },
            set: { mode in
                settings.queueGrouping = mode
                Announcer.announce(mode.announcement)
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
            .confirmationDialog("Clear the entire Queue?", isPresented: $confirmingClearQueue, titleVisibility: .visible) {
                Button("Clear entire Queue", role: .destructive) {
                    let saved = repo.clear()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        focusLaunchHeading = true
                        Announcer.announce(saved ? "Queue cleared" : "Could not clear Queue. Please try again.")
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Removes all \(episodes.count) episodes from Queue, including episodes hidden by search. " + (settings.deleteDownloadAfterPlayed ? "Downloaded audio for these episodes will also be deleted." : "Downloaded audio is kept."))
            }
            .confirmationDialog(
                downloadAllRequest.map {
                    $0.deferredCount > 0
                        ? "Download the next \($0.episodes.count) episodes?"
                        : "Download \($0.episodes.count) episodes?"
                }
                    ?? "Download episodes?",
                isPresented: Binding(
                    get: { downloadAllRequest != nil },
                    set: { if !$0 { downloadAllRequest = nil } }
                ),
                titleVisibility: .visible,
                presenting: downloadAllRequest
            ) { request in
                Button("Download \(request.episodes.count) episodes") {
                    startDownloadAll(request)
                }
                .disabled(request.episodes.isEmpty)
                Button("Cancel", role: .cancel) { downloadAllRequest = nil }
            } message: { request in
                if request.deferredCount > 0 {
                    Text("\(request.eligibleCount) episodes in the \(request.scope) are eligible. This starts the next \(request.episodes.count) and leaves \(request.deferredCount) for a later batch. \(request.skippedCount) downloaded or active episodes are skipped.")
                } else {
                    Text("Downloads all \(request.eligibleCount) eligible episodes in the \(request.scope). \(request.skippedCount) downloaded or active episodes are skipped.")
                }
            }
            .confirmationDialog(
                lineupRequest?.title ?? "Lineup options",
                isPresented: Binding(
                    get: { lineupRequest != nil },
                    set: { if !$0 { lineupRequest = nil } }
                ),
                titleVisibility: .visible,
                presenting: lineupRequest
            ) { request in
                switch request {
                case let .save(queueCount, replacing):
                    Button(replacing > 0 ? "Replace saved lineup" : "Save lineup") {
                        let report = lineupStore.save(episodes)
                        savedLineupCount = report.savedCount
                        lineupRequest = nil
                        Announcer.announce(report.announcement, assertive: true)
                    }
                    .disabled(queueCount == 0)
                    Button("Cancel", role: .cancel) { lineupRequest = nil }
                case .apply:
                    Button("Apply lineup") {
                        let report = lineupStore.apply(to: repo)
                        lineupRequest = nil
                        Announcer.announce(report.announcement, assertive: true)
                    }
                    Button("Cancel", role: .cancel) { lineupRequest = nil }
                case .clear:
                    Button("Clear saved lineup", role: .destructive) {
                        lineupStore.clear()
                        savedLineupCount = 0
                        lineupRequest = nil
                        Announcer.announce("Saved lineup cleared", assertive: true)
                    }
                    Button("Cancel", role: .cancel) { lineupRequest = nil }
                }
            } message: { request in
                switch request {
                case let .save(queueCount, _):
                    if queueCount > QueueLineupStore.maximumEpisodeCount {
                        Text("The first \(QueueLineupStore.maximumEpisodeCount) episodes will be saved in their current order. \(queueCount - QueueLineupStore.maximumEpisodeCount) later episodes will be omitted.")
                    } else {
                        Text("Saves the current Queue order so you can restore it later.")
                    }
                case .apply:
                    Text("Saved episodes move to the front in order. Other queued episodes stay after them. Unavailable or played episodes are skipped.")
                case .clear:
                    Text("Removes the reusable lineup only. Your current Queue is unchanged.")
                }
            }
            .sheet(item: $showNotesEpisode) { ShowNotesView(episode: $0) }
            .onAppear {
                savedLineupCount = lineupStore.savedCount
                requestLaunchHeadingFocus()
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .earshotCloudKitImportDidFinish)
            ) { _ in
                savedLineupCount = lineupStore.savedCount
            }
            .onChange(of: runtime.launchFocusRequest) { _, _ in
                requestLaunchHeadingFocus()
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
        } else if searchActive && EpisodeSearchFilter.filter(episodes, query: searchText).isEmpty {
            // A search is active and nothing in the queue matches — covers both
            // flat and grouped modes (a group survives filtering only if one of
            // its episodes matches, so no-match overall means no groups either).
            NoSearchMatchesView(query: searchText)
        } else if settings.queueGrouping == .none {
            flatList
        } else {
            groupedList
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
            .onMove { from, to in
                guard !searchActive else { return }
                handleMove(from, to)
            }
        }
    }

    // MARK: Grouped

    @ViewBuilder
    private var groupedList: some View {
        if settings.queueGrouping == .folder {
            let folderGrouping = repo.groupedQueueByFolder()
            groupedList(
                groups: filtered(folderGrouping.groups),
                moveMode: .groupedByFolder(resolution: folderGrouping.resolution),
                folderGrouping: folderGrouping
            )
        } else {
            groupedList(
                groups: filtered(repo.groupedQueue()),
                moveMode: .grouped,
                folderGrouping: nil
            )
        }
    }

    /// Filters within each group and hides groups the search empties. The
    /// header count therefore matches the rows VoiceOver will traverse.
    private func filtered(_ groups: [QueueGroup]) -> [QueueGroup] {
        groups.compactMap { group in
            let matching = EpisodeSearchFilter.filter(group.episodes, query: searchText)
            guard !matching.isEmpty else { return nil }
            return QueueGroup(
                kind: group.kind,
                title: (group.podcast?.displayName ?? group.title),
                episodes: matching,
                podcast: group.podcast
            )
        }
    }

    private func groupedList(
        groups: [QueueGroup],
        moveMode: QueueMoveMode,
        folderGrouping: QueueFolderGrouping?
    ) -> some View {
        // Filter within each group and hide groups the search empties (#457).
        // The header's "N episodes" count then reflects the visible rows, which
        // is what a VoiceOver user is about to traverse.
        return List {
            ForEach(groups) { group in
                Section {
                    ForEach(group.episodes) { episode in
                        row(
                            episode,
                            position: nil,
                            total: nil,
                            moveMode: moveMode,
                            displayedGroups: groups
                        )
                    }
                    .onMove { from, to in
                        guard !searchActive else { return }
                        handleGroupedMove(group, moveMode: moveMode, from: from, to: to)
                    }
                } header: {
                    groupHeader(group, folderGrouping: folderGrouping)
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
    private func groupHeader(_ group: QueueGroup, folderGrouping: QueueFolderGrouping?) -> some View {
        let count = group.episodes.count
        let countPhrase = count == 1 ? "1 episode" : "\(count) episodes"

        return Text((group.podcast?.displayName ?? group.title))
            .accessibilityLabel("\((group.podcast?.displayName ?? group.title)), \(countPhrase)")
            .accessibilityAddTraits(.isHeader)
            .accessibilityFocused($focusedGroup, equals: group.kind)
            // Routed through the shared helper so the rotor announces Play
            // Group first and Shuffle Group last — the designed order — despite
            // the OS's reversed emission (#572, #577).
            .rotorActions(groupHeaderActions(group, folderGrouping: folderGrouping))
    }

    /// The group header's rotor actions in DESIGNED announce order. Play Group
    /// starts playback; the move and sort/shuffle actions only reorder in place
    /// (their @discardableResult Episode?, where any, is ignored) — they never
    /// start audio.
    private func groupHeaderActions(
        _ group: QueueGroup, folderGrouping: QueueFolderGrouping?
    ) -> [QuickActionItem] {
        [
            QuickActionItem(id: "playGroup", label: "Play Group", isDestructive: false) {
                if let episode = playGroup(group, folderGrouping: folderGrouping) {
                    // playFromEpisodeList so Play Group honors #562 (Item 1).
                    player.playFromEpisodeList(episode, origin: group.playbackOrigin)
                    Announcer.announce("Playing \((group.podcast?.displayName ?? group.title))")
                }
            },
            QuickActionItem(id: "moveGroupUp", label: "Move Group Up", isDestructive: false) {
                // Announce + refocus only on a real move; an edge no-op
                // (group already first / last) must stay silent.
                if moveGroupUp(group, folderGrouping: folderGrouping) {
                    Announcer.announce("Moved \((group.podcast?.displayName ?? group.title)) up")
                    focusedGroup = group.kind
                }
            },
            QuickActionItem(id: "moveGroupDown", label: "Move Group Down", isDestructive: false) {
                if moveGroupDown(group, folderGrouping: folderGrouping) {
                    Announcer.announce("Moved \((group.podcast?.displayName ?? group.title)) down")
                    focusedGroup = group.kind
                }
            },
            QuickActionItem(id: "sortNewest", label: "Sort Newest First", isDestructive: false) {
                sortNewest(group, folderGrouping: folderGrouping)
                Announcer.announce("Sorted newest first")
            },
            QuickActionItem(id: "sortOldest", label: "Sort Oldest First", isDestructive: false) {
                sortOldest(group, folderGrouping: folderGrouping)
                Announcer.announce("Sorted oldest first")
            },
            QuickActionItem(id: "shuffleGroup", label: "Shuffle Group", isDestructive: false) {
                shuffleGroup(group, folderGrouping: folderGrouping)
                Announcer.announce("Shuffled")
            },
        ]
    }

    private func playGroup(_ group: QueueGroup, folderGrouping: QueueFolderGrouping?) -> Episode? {
        if let podcast = group.podcast { return repo.playGroup(podcast) }
        guard let folderGrouping else { return nil }
        return repo.playGroup(group.kind, resolution: folderGrouping.resolution)
    }

    private func moveGroupUp(_ group: QueueGroup, folderGrouping: QueueFolderGrouping?) -> Bool {
        if let podcast = group.podcast { return repo.moveGroupUp(podcast) }
        guard let folderGrouping else { return false }
        return repo.moveGroupUp(group.kind, resolution: folderGrouping.resolution)
    }

    private func moveGroupDown(_ group: QueueGroup, folderGrouping: QueueFolderGrouping?) -> Bool {
        if let podcast = group.podcast { return repo.moveGroupDown(podcast) }
        guard let folderGrouping else { return false }
        return repo.moveGroupDown(group.kind, resolution: folderGrouping.resolution)
    }

    private func sortNewest(_ group: QueueGroup, folderGrouping: QueueFolderGrouping?) {
        if let podcast = group.podcast {
            repo.playNewestFirst(podcast)
            return
        }
        guard let folderGrouping else { return }
        repo.playNewestFirst(group.kind, resolution: folderGrouping.resolution)
    }

    private func sortOldest(_ group: QueueGroup, folderGrouping: QueueFolderGrouping?) {
        if let podcast = group.podcast {
            repo.playOldestFirst(podcast)
            return
        }
        guard let folderGrouping else { return }
        repo.playOldestFirst(group.kind, resolution: folderGrouping.resolution)
    }

    private func shuffleGroup(_ group: QueueGroup, folderGrouping: QueueFolderGrouping?) {
        if let podcast = group.podcast {
            repo.shuffleGroup(podcast)
            return
        }
        guard let folderGrouping else { return }
        repo.shuffleGroup(group.kind, resolution: folderGrouping.resolution)
    }

    // MARK: Row

    private func row(
        _ episode: Episode,
        position: Int?,
        total: Int?,
        moveMode: QueueMoveMode,
        displayedGroups: [QueueGroup] = []
    ) -> some View {
        QueueRow(
            episode: episode,
            position: position,
            total: total,
            focusedEpisode: $focusedEpisode,
            actions: availableQueueActions(order: quickActions.queueActions, moveMode: moveMode),
            performAction: { action in
                buildQueueActions(
                    episode: episode,
                    order: [action],
                    moveMode: moveMode,
                    player: player,
                    downloads: downloads,
                    context: context,
                    onShowNotes: { showNotesEpisode = episode },
                    onFocus: { focusedEpisode = $0 },
                    // Resolve the displayed order only when removal is activated,
                    // never while SwiftUI is recycling queue rows.
                    visibleQueue: {
                        let ordered = displayedQueueOrder(
                            moveMode: moveMode, flat: repo.queue(), grouped: displayedGroups
                        )
                        return EpisodeSearchFilter.filter(ordered, query: searchText)
                    }
                ).first?.run()
            }
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
                .accessibilityFocused($focusLaunchHeading)
        }
        // Edit (drag reorder) is hidden while a search is active, matching the
        // suspended `.onMove` — reordering a partial view of the queue would
        // move rows to the wrong real positions (#457).
        if !episodes.isEmpty && !searchActive {
            ToolbarItem(placement: .topBarLeading) { EditButton() }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Section("Organization") {
                    Picker("Group queue", selection: queueGrouping) {
                        ForEach(QueueGrouping.allCases) { mode in
                            Text(mode.optionLabel).tag(mode)
                        }
                    }
                }
                if !episodes.isEmpty {
                    Section("Downloads") {
                        Button {
                            downloadAllRequest = QueueDownloadAllRequest(
                                candidates: EpisodeSearchFilter.filter(episodes, query: searchText),
                                scope: searchActive ? "current filtered Queue" : "Queue"
                            )
                        } label: {
                            Label(searchActive ? "Download filtered Queue" : "Download all", systemImage: "arrow.down.circle")
                        }
                    }
                }
                Section("Saved lineup") {
                    if !episodes.isEmpty {
                        Button {
                            lineupRequest = .save(queueCount: episodes.count, replacing: savedLineupCount)
                        } label: {
                            Label(savedLineupCount > 0 ? "Replace saved lineup" : "Save as lineup", systemImage: "bookmark")
                        }
                    }
                    if savedLineupCount > 0 {
                        Button { lineupRequest = .apply(savedCount: savedLineupCount) } label: {
                            Label("Apply saved lineup", systemImage: "text.badge.checkmark")
                        }
                        Button(role: .destructive) { lineupRequest = .clear(savedCount: savedLineupCount) } label: {
                            Label("Clear saved lineup", systemImage: "bookmark.slash")
                        }
                    }
                }
                if !episodes.isEmpty {
                    Section {
                        Button(role: .destructive) { confirmingClearQueue = true } label: {
                            Label("Clear queue", systemImage: "trash")
                        }
                    }
                }
            } label: {
                Label(
                    isEnrollingDownloads ? "Preparing downloads" : "Queue options",
                    systemImage: isEnrollingDownloads ? "arrow.down.circle" : "ellipsis.circle"
                )
            }
            .disabled(isEnrollingDownloads)
        }
    }

    private func startDownloadAll(_ request: QueueDownloadAllRequest) {
        downloadAllRequest = nil
        isEnrollingDownloads = true
        Task { @MainActor in
            let report = await downloads.downloadAll(request.candidates)
            isEnrollingDownloads = false
            Announcer.announce(report.announcement, assertive: true)
        }
    }

    // MARK: Drag reorder

    private func handleMove(_ from: IndexSet, _ to: Int) {
        guard let source = from.first else { return }
        let episode = episodes[source]
        repo.move(episode, toIndex: to > source ? to - 1 : to)
        focusedEpisode = episode.persistentModelID
    }

    /// Grouped drag mirrors the existing VoiceOver row actions: a row may move
    /// only within its podcast group. Applying the same repository operation
    /// repeatedly preserves the interleaved flat queue and #444/#445 parity.
    private func handleGroupedMove(
        _ group: QueueGroup, moveMode: QueueMoveMode, from: IndexSet, to: Int
    ) {
        guard let source = from.first, group.episodes.indices.contains(source) else { return }
        let episode = group.episodes[source]
        for direction in GroupedQueueDrag.directions(
            from: source,
            to: to,
            itemCount: group.episodes.count
        ) {
            switch direction {
            case .up:
                switch moveMode {
                case .grouped:
                    repo.moveUpWithinGroup(episode)
                case let .groupedByFolder(resolution):
                    repo.moveUpWithinFolderGroup(episode, resolution: resolution)
                case .flat, .none:
                    break
                }
            case .down:
                switch moveMode {
                case .grouped:
                    repo.moveDownWithinGroup(episode)
                case let .groupedByFolder(resolution):
                    repo.moveDownWithinFolderGroup(episode, resolution: resolution)
                case .flat, .none:
                    break
                }
            }
        }
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

    private func requestLaunchHeadingFocus() {
        guard runtime.consumeLaunchFocus(.queue) else { return }
        DispatchQueue.main.async { focusLaunchHeading = true }
    }

}

/// Converts SwiftUI's insertion-index `onMove` destination into the same
/// one-row-at-a-time directions exposed by the grouped VoiceOver actions.
/// Presentation-only and pure so the drag mapping can be regression-tested.
enum GroupedQueueDrag {
    enum Direction: Equatable {
        case up
        case down
    }

    static func directions(from source: Int, to destination: Int, itemCount: Int) -> [Direction] {
        guard itemCount > 1, (0..<itemCount).contains(source) else { return [] }
        let insertionAdjusted = destination > source ? destination - 1 : destination
        let target = max(0, min(insertionAdjusted, itemCount - 1))
        if target < source {
            return Array(repeating: .up, count: source - target)
        }
        if target > source {
            return Array(repeating: .down, count: target - source)
        }
        return []
    }
}

/// One queue row: a single VoiceOver element whose Actions rotor is the user's
/// configured queue Quick Actions (in order), so a screen-reader user can play,
/// reorder, or remove without a drag gesture. Swipe exposes the destructive
/// actions; the context menu exposes the non-default ones.
private struct QueueRow: View {
    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    // Requires SettingsStore in the environment (injected at the app root); every
    // QueueRow renders under QueueScreen, which is under that root. Gates the
    // opt-in season/episode numbering (#452).
    @Environment(SettingsStore.self) private var settings
    // Observed now-playing identity so the row re-renders when the loaded episode
    // changes and its badge/label update (Item 2). Every QueueRow renders under
    // QueueScreen, which is under the app root that injects PlayerService.
    @Environment(PlayerService.self) private var player
    let episode: Episode
    let position: Int?
    let total: Int?
    @AccessibilityFocusState.Binding var focusedEpisode: PersistentIdentifier?
    let actions: [QueueItemAction]
    let performAction: (QueueItemAction) -> Void

    @ViewBuilder
    var body: some View {
        if episode.isDeleted {
            EmptyView()
        } else {
            rowContent
        }
    }

    private var rowContent: some View {
        let episodeID = episode.persistentModelID
        let presentations = QueueItemAction.presentations(actions, for: episode)
        let primary = presentations.first
        // Castro-style "X min left" / total length, the same treatment EpisodeRow
        // gives every other list. The Queue was the original surface this was
        // requested for but #493 only reached the shared row, not this bespoke
        // one (#504). Cheap arithmetic, safe to evaluate per realization.
        let timeText = EpisodeTimeLogic.visibleText(
            positionSeconds: episode.positionSeconds,
            durationSeconds: episode.durationSeconds,
            isPlayed: episode.isPlayed
        )

        return Button {
            guard let primary,
                  PersistentModelLifetime.episodeExists(episodeID, in: context) else { return }
            performAction(primary.action)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(episode.title)
                    .font(.body)
                    .multilineTextAlignment(.leading)
                // Now-playing indicator (Item 2): icon + text, accent-tinted,
                // never colour alone. Hidden from VoiceOver here — the row is one
                // element and the spoken state rides in accessibilityLabel below.
                if isNowPlaying {
                    Label("Now Playing", systemImage: "waveform")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }
                if let podcast = episode.podcast?.displayName {
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
        .queueActionsRotor(presentations) { action in
            guard PersistentModelLifetime.episodeExists(episodeID, in: context) else { return }
            performAction(action)
        }
        .modifier(SightedRowActions(
            episodeID: episodeID,
            context: context,
            actions: presentations,
            performAction: performAction
        ))
    }

    /// True when this row's episode is the one loaded in the player, compared by
    /// persistent identity against the observed ``PlayerService/nowPlayingEpisodeID``
    /// so the row re-renders as the loaded episode changes (Item 2).
    private var isNowPlaying: Bool {
        player.nowPlayingEpisodeID == episode.persistentModelID
    }

    private var accessibilityLabel: String {
        EpisodeRowLabel.label(
            episodeTitle: episode.title,
            podcastName: episode.podcast?.displayName,
            seasonNumber: settings.showEpisodeNumbers ? episode.seasonNumber : nil,
            episodeNumber: settings.showEpisodeNumbers ? episode.episodeNumber : nil,
            isPlayed: episode.isPlayed,
            pubDate: episode.pubDate,
            downloadState: episode.downloadStatus,
            isNowPlaying: isNowPlaying,
            contextDetail: position.flatMap { position in
                total.map { "position \(position) of \($0)" }
            },
            details: settings.episodeSpokenDetails
        )
    }

    /// The row's VoiceOver value: the spoken time-left/length (#493/#504), or an
    /// empty string when the episode is played or has no known duration, so
    /// VoiceOver announces no stray value.
    private var accessibilityValue: String {
        guard voiceOverEnabled else { return "" }
        return EpisodeRowSpeech.value(for: episode, details: settings.episodeSpokenDetails)
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
    let episodeID: PersistentIdentifier
    let context: ModelContext
    let actions: [DeferredActionPresentation<QueueItemAction>]
    let performAction: (QueueItemAction) -> Void
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
                        Button(role: .destructive) {
                            guard PersistentModelLifetime.episodeExists(episodeID, in: context) else { return }
                            performAction(action.action)
                        } label: {
                            Text(action.label)
                        }
                    }
                }
                .contextMenu {
                    ForEach(actions.dropFirst()) { action in
                        Button(role: action.isDestructive ? .destructive : nil) {
                            guard PersistentModelLifetime.episodeExists(episodeID, in: context) else { return }
                            performAction(action.action)
                        } label: {
                            Text(action.label)
                        }
                    }
                }
        }
    }
}
