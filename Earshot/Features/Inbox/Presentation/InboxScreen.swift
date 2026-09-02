import SwiftUI
import SwiftData

private struct DownloadAllRequest: Identifiable {
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

/// The Inbox: new, untriaged episodes. Each row carries the configured episode
/// Quick Actions (rotor + default tap). "Clear inbox" dismisses everything
/// currently shown.
struct InboxScreen: View {
    var isActive = true
    @Environment(AppRuntime.self) private var runtime
    @Environment(\.modelContext) private var context
    @Environment(PlayerService.self) private var player
    @Environment(DownloadManager.self) private var downloads
    @Environment(QuickActionStore.self) private var quickActions
    @Environment(SettingsStore.self) private var settings

    // Folder filter choices (#763). The selected id, rather than a model
    // reference, remains stable across SwiftUI rebuilds. Folder rows use their
    // full breadcrumb paths so duplicate names at different depths are
    // distinguishable visually and with VoiceOver.
    @Query(sort: [SortDescriptor(\PodcastFolder.sortOrder), SortDescriptor(\PodcastFolder.name)])
    private var folders: [PodcastFolder]
    @State private var selectedFolderID: PersistentIdentifier?

    @State private var showNotesEpisode: Episode?
    @State private var sharingEpisode: Episode?
    // The episode a pending "Export audio" Quick Action targets (#689). Drives
    // the shared `.episodeAudioExport` download-then-share flow.
    @State private var exportEpisode: Episode?
    @State private var exportTranscriptEpisode: Episode?
    @State private var bookmarksEpisode: Episode?
    // The pending "Add to folder" / "Move to folder" Quick Action target (#756).
    // Non-nil presents the shared `FolderPickerView` for the single episode.
    @State private var folderPickRequest: FolderPickRequest?
    @State private var confirmingClear = false
    @State private var downloadAllRequest: DownloadAllRequest?
    @State private var isEnrollingDownloads = false
    // Inbox episode multi-select (#758). Reuses the shared scaffold: `selection`
    // is the generic ``MultiSelectState`` holder (keyed on persistent identity so
    // it survives the `@Query`-driven row rebuilds as the inbox changes),
    // `batchRequest` presents the shared ``FolderPickerView`` for the whole
    // selection. Entering selection mode swaps every row for a ``SelectableRow``
    // and shows a bottom ``MultiSelectBar`` with Add/Move to folder plus the
    // triage-natural Add to queue / Mark as played batches (supersedes the
    // bespoke #595 single-toolbar-button selection).
    @State private var selection = MultiSelectState()
    @State private var batchRequest: FolderPickRequest?
    // Takes VoiceOver focus back to the toolbar's Select/Done button after a bulk
    // action completes and selection mode exits, mirroring the neighbor-focus
    // wiring used elsewhere in this screen (`focusEmpty`, `focusedEpisode`).
    @AccessibilityFocusState private var focusSelectButton: Bool
    // Moves VoiceOver focus onto the list's first row when entering selection
    // mode. Keyed on the stable PersistentIdentifier and attached to whichever
    // row variant renders, so focus rides the row across the select-mode toggle
    // (mirrors SubscriptionsView's podcast multi-select, #757).
    @AccessibilityFocusState private var focusedRowID: PersistentIdentifier?
    // The podcast a pending "Unfollow this podcast" targets — reached from the
    // trailing swipe (sighted, #500) or the row's `.unfollow` Quick Action in the
    // VoiceOver rotor (#572). Non-nil drives the destructive confirmation dialog.
    // Mirrors the Library unfollow flow (`SubscriptionsView.pendingUnsubscribe`)
    // so the UX is identical.
    @State private var pendingUnfollow: Podcast?
    // The in-place `.searchable` filter (#457, Part A). Pure presentation: the
    // @Query-backed inbox is filtered in memory, never re-fetched.
    @State private var searchText = ""
    /// Keep initial view construction bounded on large inboxes. More episodes
    /// remain available in explicit, predictable batches without deleting data.
    @State private var displayedEpisodeLimit = InboxLogic.displayBatchSize
    // The event-driven child loader owns store refreshes. Focus recovery reads
    // this same selected-scope snapshot instead of synchronously re-querying
    // the store during a VoiceOver action.
    @State private var currentCandidateSnapshot: [Episode] = []
    @AccessibilityFocusState private var focusEmpty: Bool
    // Focus target for the row that should take VoiceOver focus after the rotor
    // "Mark as played" removes the focused row from the inbox (#579). Mirrors
    // the Queue's neighbor-focus wiring.
    @AccessibilityFocusState private var focusedEpisode: PersistentIdentifier?
    @AccessibilityFocusState private var focusLaunchHeading: Bool
    @AccessibilityFocusState private var focusRefreshStatus: Bool
    // Tracked by SwiftUI, so toggling VoiceOver while the Inbox is on screen
    // re-renders the rows and attaches/removes the swipe actions immediately —
    // no relaunch. (Reading UIAccessibility.isVoiceOverRunning in body would
    // not invalidate.) Mirrors the Queue's SightedRowActions gate.
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    private var orderedFolders: [PodcastFolder] {
        FolderLogic.orderedHierarchy(from: folders)
    }

    private var selectedFolder: PodcastFolder? {
        guard let selectedFolderID else { return nil }
        return folders.first { $0.persistentModelID == selectedFolderID }
    }

    var body: some View {
        Group {
            if let selectedFolder {
                FolderScopedInboxCandidates(
                    folder: selectedFolder,
                    isActive: isActive
                ) { candidates in
                    inboxContent(candidates: candidates)
                }
            } else {
                AllInboxCandidates(
                    optInOnly: settings.inboxOptInOnly,
                    isActive: isActive
                ) { candidates in
                    inboxContent(candidates: candidates)
                }
            }
        }
    }

    private func inboxContent(candidates: [Episode]) -> some View {
        // Compute the inbox once per body so the list, empty-state check, title,
        // count, and Clear dialog all read a single value instead of re-running
        // the filter (formerly a re-fetch) several times per render.
        // EpisodeStatus is stored as a Codable enum and is not translated by
        // SwiftData predicates. This bounded scalar check is safe; the expensive
        // Podcast relationship rules have already run in SQLite.
        // An event-driven snapshot can briefly retain an Episode that refresh
        // identity repair or CloudKit projection has deleted. Check SwiftData's
        // backing-data state before touching any persisted property; a stale
        // `status` getter traps rather than throwing (TestFlight build 210).
        let inbox = InboxRepository.liveEpisodes(candidates, in: context)
            .filter { $0.status == .newEpisode }
        // What the list actually shows: the inbox narrowed by the search field
        // (#457). With no search active this IS `inbox` (same array, no copy).
        let visible = EpisodeSearchFilter.filter(inbox, query: searchText)
        let displayed = visible.prefix(displayedEpisodeLimit)
        return VStack(spacing: 0) {
            inboxFilter
            Group {
                if inbox.isEmpty {
                    ContentUnavailableView(
                        selectedFolder == nil ? "Inbox is empty" : "No new episodes",
                        systemImage: "tray",
                        description: Text(emptyDescription)
                    )
                    .accessibilityElement(children: .combine)
                    .accessibilityFocused($focusEmpty)
                } else if visible.isEmpty {
                    // Search matched nothing. Bound to the same focus target as
                    // the true empty state so mutation focus never gets stranded.
                    NoSearchMatchesView(query: searchText)
                        .accessibilityFocused($focusEmpty)
                } else {
                    List {
                        // The rotor is owned EXCLUSIVELY by the row's configured
                        // episode Quick Actions. Sighted-only swipes stay gated
                        // below so iOS cannot mirror duplicates into the rotor.
                        ForEach(displayed) { episode in
                            rowContainer(for: episode)
                                .accessibilityFocused(
                                    $focusedEpisode, equals: episode.persistentModelID
                                )
                                .accessibilityFocused(
                                    $focusedRowID, equals: episode.persistentModelID
                                )
                        }
                        if displayed.count < visible.count {
                            Button {
                                displayedEpisodeLimit = InboxLogic.nextDisplayLimit(
                                    current: displayedEpisodeLimit,
                                    total: visible.count
                                )
                                let newCount = displayedEpisodeLimit
                                Announcer.announce(
                                    "Showing \(newCount) of \(visible.count) episodes"
                                )
                            } label: {
                                Label("Show 100 more", systemImage: "chevron.down.circle")
                            }
                            .accessibilityLabel("Show 100 more episodes")
                            .accessibilityHint(
                                "Currently showing \(displayed.count) of \(visible.count) episodes"
                            )
                        }
                    }
                }
            }
        }
        // The visible title and its VoiceOver label both derive from
        // `inbox.count`, which comes from the @Query-backed `inbox` — so they
        // re-render live as episodes are triaged or the inbox is cleared, with
        // no separate state to go stale. Visible string stays compact
        // ("Inbox (12)"); VoiceOver gets a naturally-spoken label
        // ("Inbox, 12 episodes").
        //
        // The count-bearing title rides on a `.principal` toolbar item rather
        // than `.navigationTitle`. A `.navigationTitle(Text(...))` plus a
        // standalone `.accessibilityLabel` puts the label on the content view,
        // not the title element, so VoiceOver still spells out "open paren,
        // 12, close paren". Even moving the label onto the `Text` passed to
        // `navigationTitle` is unreliable here: on this project's iOS 17
        // deployment target SwiftUI's navigation-bar bridge does not
        // consistently carry a custom accessibility label into the LARGE
        // title. The `.principal` item is a single, real bar element we fully
        // own, so the label is guaranteed. `.accessibilityAddTraits(.isHeader)`
        // restores the heading role that a plain `navigationTitle` grants for
        // free. Tradeoff: a principal item presents inline-style with no
        // large-title spring — acceptable for an accessibility-first app where
        // the guaranteed reading matters more than the large-title animation.
        // The plain `navigationTitle("Inbox")` keeps the bar's title identity
        // (e.g. for back-button context) without duplicating the principal.
        .navigationTitle("Inbox")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top) {
            if FeedRefreshInlineStatus.shouldShow(runtime.feedRefreshStatus.snapshot) {
                FeedRefreshInlineStatus(snapshot: runtime.feedRefreshStatus.snapshot)
                    .accessibilityFocused($focusRefreshStatus)
            }
        }
        // Persistent episode multi-select bar (#758): Add to folder is primary
        // and its label carries the live count ("Add 3 episodes to folder") — the
        // accessibility source of truth for the count. Move to folder follows, and
        // the two triage-natural batches (Add to queue, Mark as played) round it
        // out. Reuses the shared ``MultiSelectBar`` unchanged from podcast
        // multi-select.
        .safeAreaInset(edge: .bottom) {
            if selection.isSelecting {
                MultiSelectBar(
                    count: selection.count,
                    primary: MultiSelectAction(
                        id: "add",
                        title: MultiSelectActionLabel.addToFolder(count: selection.count, itemSingular: "episode"),
                        systemImage: "folder",
                        handler: { presentBatch(.add, visible: visible) }
                    ),
                    secondary: [
                        MultiSelectAction(
                            id: "move",
                            title: MultiSelectActionLabel.moveToFolder(count: selection.count, itemSingular: "episode"),
                            systemImage: "folder",
                            handler: { presentBatch(.move, visible: visible) }
                        ),
                        MultiSelectAction(
                            id: "queue",
                            title: EpisodeBatchLabel.addToQueue(count: selection.count),
                            systemImage: "text.badge.plus",
                            handler: { addSelectedToQueue(visible: visible) }
                        ),
                        MultiSelectAction(
                            id: "played",
                            title: EpisodeBatchLabel.markPlayed(count: selection.count),
                            systemImage: "checkmark.circle",
                            handler: { markSelectedPlayed(visible: visible) }
                        ),
                    ],
                    announcementNoun: "episode"
                )
                .transition(.move(edge: .bottom))
            }
        }
        // In-place search filter (#457, Part A). The system `.searchable` field
        // is the standard accessible search affordance (labeled, focusable,
        // clearable). The result count is announced on SUBMIT only — never per
        // keystroke, never while the field is empty — so typing stays quiet and
        // the user asks for the tally when they want it (the list itself
        // updates live as they type).
        .searchable(text: $searchText, prompt: "Search inbox")
        .modifier(CandidateSnapshotSyncModifier(
            candidates: candidates,
            snapshot: $currentCandidateSnapshot
        ))
        .onAppear {
            requestLaunchHeadingFocus()
            requestTabEntryFocus()
        }
        .onChange(of: runtime.launchFocusRequest) { _, _ in
            requestLaunchHeadingFocus()
        }
        .onChange(of: runtime.tabFocusRevision) { _, _ in
            requestTabEntryFocus()
        }
        .onChange(of: searchText) { _, _ in displayedEpisodeLimit = InboxLogic.displayBatchSize }
        .onSubmit(of: .search) { announceMatches(count: visible.count) }
        .toolbar {
            // Deliberately `inbox.count`, not `visible.count`: the title states
            // the TOTAL inbox size even while a search narrows the list (#457).
            // The title is the inbox's identity, not the filter's result count —
            // the match tally is announced from the search field on submit.
            ToolbarItem(placement: .principal) {
                Text(InboxLogic.inboxTitle(count: inbox.count))
                    .font(.headline)
                    .accessibilityLabel(InboxLogic.inboxTitleAccessibilityLabel(count: inbox.count))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($focusLaunchHeading)
            }
            // Select / Done toggles selection mode (#758). "Select" enters and
            // moves VoiceOver focus to the first row; "Done" exits and announces
            // the change. Only offered when there's something to select; hidden
            // while the inbox is empty just like Clear inbox. The batch actions
            // themselves live in the bottom MultiSelectBar, not the toolbar.
            if !inbox.isEmpty {
                ToolbarItem(placement: .topBarLeading) {
                    if selection.isSelecting {
                        Button("Done") { exitSelection(announce: true) }
                            .accessibilityHint("Leaves selection mode")
                            .accessibilityFocused($focusSelectButton)
                    } else {
                        Button {
                            enterSelection(first: displayed.first)
                        } label: {
                            Label("Select", systemImage: "checkmark.circle")
                        }
                        .accessibilityFocused($focusSelectButton)
                    }
                }
            }
            if !selection.isSelecting && !inbox.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            downloadAllRequest = DownloadAllRequest(
                                candidates: visible,
                                scope: EpisodeSearchFilter.isActive(searchText)
                                    ? "current filtered Inbox" : "Inbox"
                            )
                        } label: {
                            Label(
                                EpisodeSearchFilter.isActive(searchText)
                                    ? "Download filtered Inbox" : "Download all",
                                systemImage: "arrow.down.circle"
                            )
                        }

                        Button(role: .destructive) {
                            confirmingClear = true
                        } label: {
                            Label("Clear inbox", systemImage: "tray.and.arrow.down")
                        }
                    } label: {
                        Label(
                            isEnrollingDownloads ? "Preparing downloads" : "Inbox options",
                            systemImage: isEnrollingDownloads ? "arrow.down.circle" : "ellipsis.circle"
                        )
                    }
                    .disabled(isEnrollingDownloads)
                }
            }
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
            "Clear inbox?",
            isPresented: $confirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear inbox", role: .destructive) { clearInbox(inbox) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Hides all \(inbox.count) episodes from the inbox. They stay in your podcasts.")
        }
        // Podcast-level destructive confirmation for the inbox-row "Unfollow"
        // swipe (#500). Wording and structure mirror Library's unfollow dialog
        // (`SubscriptionsView`) for consistency; the message spells out that the
        // whole show leaves the library, since the action is reached from a single
        // episode's context and shouldn't be mistaken for an inbox-only dismiss.
        .confirmationDialog(
            "Unfollow \(pendingUnfollow?.title ?? "this podcast")?",
            isPresented: Binding(
                get: { pendingUnfollow != nil },
                set: { if !$0 { pendingUnfollow = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingUnfollow
        ) { podcast in
            Button("Unfollow", role: .destructive) { unfollow(podcast) }
            Button("Cancel", role: .cancel) { pendingUnfollow = nil }
        } message: { podcast in
            Text("This removes \(podcast.title) and its episodes from your library. This can't be undone.")
        }
        .sheet(item: $showNotesEpisode) { ShowNotesView(episode: $0) }
        .sheet(item: $bookmarksEpisode) { BookmarksListView(episode: $0) }
        .sheet(item: $sharingEpisode) { ShareSheet(items: shareItems(for: $0)) }
        .episodeAudioExport($exportEpisode)
        .episodeTranscriptExport($exportTranscriptEpisode)
        .folderPicker($folderPickRequest)
        // The multi-select batch picker (#758): same shared FolderPickerView, but
        // it reports completion so we leave selection mode and re-anchor focus
        // only after a real pick (Cancel keeps the selection for a retry).
        .sheet(item: $batchRequest) { req in
            FolderPickerView(episodes: req.episodes, mode: req.mode) {
                finishBatch()
            }
        }
    }

    /// Always-visible folder scope control (#763). A native menu-style Picker
    /// supplies the button role, current value, keyboard/VoiceOver behavior, and
    /// a 44-point target. It remains above empty/no-search states so a user can
    /// always escape a folder with no matches. Full breadcrumb labels
    /// disambiguate same-named nested folders.
    private var inboxFilter: some View {
        Picker(selection: $selectedFolderID) {
            Text("All folders").tag(nil as PersistentIdentifier?)
            ForEach(orderedFolders) { folder in
                Text(FolderLogic.pathString(folder))
                    .tag(folder.persistentModelID as PersistentIdentifier?)
            }
        } label: {
            Label("Inbox: \(selectedFolderName)", systemImage: "line.3.horizontal.decrease.circle")
        }
        .pickerStyle(.menu)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.horizontal, Spacing.md)
        .accessibilityLabel("Inbox filter, \(selectedFolderName)")
        .accessibilityHint("Choose a folder to show its new episodes, including subfolders")
        .disabled(selection.isSelecting)
        .onChange(of: selectedFolderID) { _, _ in
            searchText = ""
            displayedEpisodeLimit = InboxLogic.displayBatchSize
        }
        .onChange(of: folders.map(\.persistentModelID)) { _, availableIDs in
            guard let selectedFolderID,
                  !availableIDs.contains(selectedFolderID) else { return }
            self.selectedFolderID = nil
        }
    }

    private var selectedFolderName: String {
        selectedFolder.map { FolderLogic.pathString($0) } ?? "All folders"
    }

    private var emptyDescription: String {
        guard let selectedFolder else {
            return "New episodes you haven't triaged appear here."
        }
        return "New episodes from \(FolderLogic.pathString(selectedFolder)) and its subfolders appear here."
    }

    /// Whichever row variant applies: a selectable checkmark row while in
    /// selection mode (#758, via the shared ``SelectableRow`` scaffold),
    /// otherwise the normal navigate/rotor + sighted-swipe row.
    @ViewBuilder
    private func rowContainer(for episode: Episode) -> some View {
        if selection.isSelecting {
            EpisodeSelectableRow(
                episode: episode,
                includesPodcastName: true,
                isSelected: selection.isSelected(episode.persistentModelID),
                onToggle: { selection.toggle(episode.persistentModelID) }
            )
        } else {
            normalRow(for: episode)
        }
    }

    /// The normal Inbox row: the configurable episode Quick Actions (rotor + tap)
    /// plus, for sighted users only, the mark-played and unfollow swipes. Selection
    /// mode swaps this out entirely for ``EpisodeSelectableRow`` (#758).
    @ViewBuilder
    private func normalRow(for episode: Episode) -> some View {
        let row = episodeRow(for: episode)
        if voiceOverEnabled {
            row
        } else {
            row
                // Visible affordance for sighted users to clear a finished
                // episode out of the inbox (#546): a leading swipe marks it
                // played and dismisses it. Leading edge + a constructive green
                // tint keeps it distinct from the trailing destructive unfollow
                // swipe; a full swipe completes it since the action is safe and
                // reversible (the episode stays in the podcast). The Label gives
                // it an icon + text (never color alone).
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button {
                        markPlayed(episode)
                    } label: {
                        Label("Mark as played", systemImage: "checkmark.circle")
                    }
                    .tint(.green)
                    Button {
                        removeFromInbox(episode)
                    } label: {
                        Label("Remove from Inbox", systemImage: "tray.and.arrow.down")
                    }
                    .tint(.blue)
                }
                // Unfollow the whole show straight from one of its inbox episodes
                // (#500), for sighted users; VoiceOver users reach the same flow
                // through the `.unfollow` Quick Action in the rotor (#572).
                // `allowsFullSwipe` is off so an over-swipe can't fast-path a
                // podcast-level delete; every path lands on the confirmation. The
                // Label gives the destructive action an icon + text (never color
                // alone).
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if let podcast = episode.podcast {
                        Button(role: .destructive) {
                            pendingUnfollow = podcast
                        } label: {
                            Label("Unfollow this podcast", systemImage: "xmark.bin")
                        }
                    }
                }
        }
    }

    private func episodeRow(for episode: Episode) -> EpisodeRow {
        EpisodeRow(
            episode: episode,
            deferredActions: availableActions(for: episode),
            includesPodcastName: true,
            performAction: { action in perform(action, for: episode) }
        )
    }

    // MARK: Multi-select (#758)

    /// Enters selection mode: announces it, then moves VoiceOver focus to the
    /// list's first row so the user lands where they can start selecting. The
    /// focus move is deferred a beat so the selectable rows exist first (mirrors
    /// SubscriptionsView's podcast multi-select).
    private func enterSelection(first: Episode?) {
        withAnimation(Motion.preferred(.easeInOut(duration: 0.2))) {
            selection.enter()
        }
        Announcer.announce("Selection mode on")
        let firstID = first?.persistentModelID
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            focusedRowID = firstID
        }
    }

    /// Leaves selection mode. `announce` is true for a manual "Done" (which says
    /// "Selection mode off"); the batch paths pass false because they've already
    /// announced their result. Re-anchors VoiceOver focus to a stable element,
    /// never a removed row: the empty state if the inbox is now empty (Add to
    /// queue / Mark as played remove rows), otherwise the Select/Done toolbar
    /// button. `focusDelay` lets a folder batch push the focus move past the
    /// picker's own +0.5s result announcement so the two don't collide.
    private func exitSelection(announce: Bool, focusDelay: TimeInterval = 0.5) {
        withAnimation(Motion.preferred(.easeInOut(duration: 0.2))) {
            selection.exit()
        }
        if announce {
            Announcer.announce("Selection mode off")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + focusDelay) {
            if currentInboxEpisodes().isEmpty {
                focusEmpty = true
            } else {
                focusSelectButton = true
            }
        }
    }

    /// Presents the shared picker for the whole selection. No-op with an empty
    /// selection (the bar's buttons are already disabled there).
    private func presentBatch(_ mode: FolderPickMode, visible: [Episode]) {
        let selected = selectedEpisodes(in: visible)
        guard !selected.isEmpty else { return }
        batchRequest = .episodes(selected, mode: mode)
    }

    /// Called by the batch folder picker once it has applied the add/move. Filing
    /// into a folder doesn't remove episodes from the inbox, so we leave selection
    /// mode silently (the picker announced the result) and re-anchor focus,
    /// staggered past the picker's +0.5s result announcement.
    private func finishBatch() {
        exitSelection(announce: false, focusDelay: 0.9)
    }

    /// The selected episodes, in the current Inbox (search-filtered) order.
    private func selectedEpisodes(in visible: [Episode]) -> [Episode] {
        visible.filter { selection.isSelected($0.persistentModelID) }
    }

    /// Adds every selected episode to the end of the queue, in Inbox order, then
    /// exits selection mode. The added episodes flip to `.inQueue` and drop out of
    /// the Inbox on their own (same as the single-row "Add to end of queue" Quick
    /// Action); `exitSelection` re-anchors focus to the empty state or the Select
    /// button depending on whether that emptied the inbox.
    private func addSelectedToQueue(visible: [Episode]) {
        let toAdd = selectedEpisodes(in: visible)
        guard !toAdd.isEmpty else { return }
        QueueRepository(context: context).add(toAdd)
        // Noun-carrying result ("Added 3 episodes to queue"), matching the folder
        // batch announcement's phrasing.
        Announcer.announce("Added \(EpisodeBatchLabel.episodePhrase(toAdd.count)) to queue", assertive: true)
        exitSelection(announce: false)
    }

    /// Marks every selected episode played and dismisses them from the inbox via
    /// the shared ``InboxRepository/markPlayed(_:)`` path (the same one the
    /// sighted swipe and rotor use), then exits selection mode. The marked
    /// episodes leave the inbox, so `exitSelection` re-anchors focus off the
    /// removed rows.
    private func markSelectedPlayed(visible: [Episode]) {
        let toMark = selectedEpisodes(in: visible)
        guard !toMark.isEmpty else { return }
        let repo = InboxRepository(context: context)
        for episode in toMark {
            repo.markPlayed(episode)
        }
        Announcer.announce("Marked \(EpisodeBatchLabel.episodePhrase(toMark.count)) as played", assertive: true)
        exitSelection(announce: false)
    }

    private func clearInbox(_ episodes: [Episode]) {
        InboxRepository(context: context).clearInbox(episodes)
        Announcer.announce("Inbox cleared")
        // The list collapses to the empty state; move focus there so VoiceOver
        // isn't orphaned on the vanished Clear button.
        // Delay so the list has collapsed to the empty state (the focus target)
        // before we request focus on it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { focusEmpty = true }
    }

    private func startDownloadAll(_ request: DownloadAllRequest) {
        downloadAllRequest = nil
        isEnrollingDownloads = true
        Task { @MainActor in
            let report = await downloads.downloadAll(request.candidates)
            isEnrollingDownloads = false
            Announcer.announce(report.announcement, assertive: true)
        }
    }

    /// Marks `episode` played and dismisses it from the inbox via the shared
    /// repository path (#546), then announces it. If that empties the inbox the
    /// focused row is gone, so move VoiceOver focus to the empty state (mirrors
    /// `clearInbox` / `unfollow`).
    private func markPlayed(_ episode: Episode) {
        InboxRepository(context: context).markPlayed(episode)
        Announcer.announce("Marked as played")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if currentInboxEpisodes().isEmpty {
                focusEmpty = true
            }
        }
    }

    private func removeFromInbox(_ episode: Episode) {
        focusAfterInboxRowLeaves(episode)
        InboxRepository(context: context).dismiss(episode)
        Announcer.announce("Removed from Inbox")
    }

    /// Unfollows `podcast` via the centralized repository path shared with
    /// Library and search (#499/#500) — never an inline delete. The repo logs
    /// failures and returns whether the delete saved, so we announce success only
    /// on `true`. The unfollowed show's episodes drop out of the @Query-backed
    /// inbox automatically; if that empties the inbox the focused row is gone, so
    /// move VoiceOver focus to the empty state (mirrors `clearInbox`).
    private func unfollow(_ podcast: Podcast) {
        let title = podcast.title
        let removed = SubscriptionRepository(context: context).unsubscribe(podcast)
        pendingUnfollow = nil
        guard removed else { return }
        Announcer.announce("Unfollowed \(title)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            // Checked against the list AS DISPLAYED (#457): with a search
            // active, unfollowing can empty the VISIBLE list (every match was
            // the unfollowed show) while the inbox itself still has episodes.
            // The no-match state then shows, and it's bound to `focusEmpty`, so
            // this filtered check is what actually parks VoiceOver on it. With
            // no search the filter passes the inbox through unchanged.
            if EpisodeSearchFilter.filter(
                currentInboxEpisodes(), query: searchText
            ).isEmpty {
                focusEmpty = true
            }
        }
    }

    /// Keeps only stable enum identifiers in an Inbox row. The two conditional
    /// omissions exactly mirror `buildEpisodeActions`; every other action has a
    /// runner on this surface.
    private func availableActions(for episode: Episode) -> [EpisodeAction] {
        availableEpisodeActions(
            episode: episode,
            order: quickActions.episodeActions,
            supportsUnfollow: true,
            supportsExport: true,
            supportsTranscriptExport: true,
            supportsAddToFolder: true,
            supportsMoveToFolder: true,
            supportsRemoveFromInbox: true
        )
    }

    /// Resolve only the action the user actually activated. This retains the
    /// established builder as the single execution path without paying its
    /// UUID/closure cost during every lazy-list row realization.
    private func perform(_ action: EpisodeAction, for episode: Episode) {
        buildEpisodeActions(
            episode: episode,
            order: [action],
            player: player,
            downloads: downloads,
            context: context,
            onShowNotes: { showNotesEpisode = episode },
            onShare: { sharingEpisode = episode },
            onBookmarks: { bookmarksEpisode = episode },
            onUnfollow: { pendingUnfollow = episode.podcast },
            onMarkPlayed: { nowPlayed in
                guard nowPlayed else { return }
                focusAfterInboxRowLeaves(episode)
            },
            onWillQueue: { focusAfterInboxRowLeaves(episode) },
            onExport: { exportEpisode = episode },
            onExportTranscript: { exportTranscriptEpisode = episode },
            onAddToFolder: { folderPickRequest = .episode($0, mode: .add) },
            onMoveToFolder: { folderPickRequest = .episode($0, mode: .move) },
            onRemoveFromInbox: { removeFromInbox(episode) }
        ).first?.run()
    }

    /// Announces the search's match count on submit (#457). Guarded so an empty
    /// or whitespace-only field never announces; Announcer itself is a no-op
    /// with VoiceOver off.
    private func announceMatches(count: Int) {
        guard EpisodeSearchFilter.isActive(searchText) else { return }
        Announcer.announce(EpisodeSearchFilter.resultAnnouncement(count: count))
    }

    /// Current Inbox membership under the selected folder scope. Mutation focus
    /// recovery uses this instead of the global Inbox so clearing/playing the
    /// last visible folder episode lands on the visible empty state (#763).
    private func currentInboxEpisodes() -> [Episode] {
        InboxRepository.currentEpisodes(currentCandidateSnapshot, in: context)
    }

    /// Re-anchors VoiceOver after a played or queued action removes an Inbox row.
    /// The neighbor comes from the list as displayed — folder scope and search
    /// included — and is captured before the mutation changes membership.
    private func focusAfterInboxRowLeaves(_ episode: Episode) {
        let neighbor = neighborID(
            of: episode,
            in: EpisodeSearchFilter.filter(currentInboxEpisodes(), query: searchText)
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let neighbor {
                focusedEpisode = neighbor
            } else {
                focusEmpty = true
            }
        }
    }

    private func requestLaunchHeadingFocus() {
        guard runtime.consumeLaunchFocus(.inbox) else { return }
        focusHeadingOrRefreshStatus()
    }

    private func requestTabEntryFocus() {
        guard runtime.consumeTabFocus(.inbox) else { return }
        focusHeadingOrRefreshStatus()
    }

    private func focusHeadingOrRefreshStatus() {
        DispatchQueue.main.async {
            if FeedRefreshStatusPresentation.entryFocus(
                runtime.feedRefreshStatus.snapshot
            ) == .refreshStatus {
                focusRefreshStatus = true
            } else {
                focusLaunchHeading = true
            }
        }
    }

    private func shareItems(for episode: Episode) -> [Any] {
        if let url = URL(string: episode.audioURL) {
            return [episode.title, url]
        }
        return [episode.title]
    }
}

/// Keeps focus-recovery actions on the already loaded Inbox snapshot without
/// adding more generic work to `InboxScreen`'s large view expression.
private struct CandidateSnapshotSyncModifier: ViewModifier {
    let candidates: [Episode]
    @Binding var snapshot: [Episode]

    private var candidateIDs: [PersistentIdentifier] {
        candidates.map(\.persistentModelID)
    }

    func body(content: Content) -> some View {
        content
            .onAppear { snapshot = candidates }
            .onChange(of: candidateIDs) { _, _ in snapshot = candidates }
    }
}

/// Global Inbox candidates stay in their selected store-queryable mode. Keeping
/// this fetch in a conditional child means SwiftUI tears it down while a folder
/// filter is active instead of continuing to materialize the global candidate
/// set behind the scoped UI (#763). It is event-driven rather than a live
/// `@Query`: unrelated SwiftData saves must not repeatedly run the relationship
/// predicate on the main actor while VoiceOver is using the app.
private struct AllInboxCandidates<Content: View>: View {
    @Environment(\.modelContext) private var context

    let optInOnly: Bool
    let isActive: Bool
    let content: ([Episode]) -> Content
    @State private var candidates: [Episode]?
    @State private var reloadScheduled = false
    @State private var reloadGeneration = 0
    @State private var reloadTask: Task<Void, Never>?

    init(
        optInOnly: Bool,
        isActive: Bool,
        @ViewBuilder content: @escaping ([Episode]) -> Content
    ) {
        self.optInOnly = optInOnly
        self.isActive = isActive
        self.content = content
    }

    var body: some View {
        Group {
            if let candidates {
                content(InboxRepository.currentEpisodes(candidates, in: context))
            } else {
                ProgressView("Loading inbox")
                    .accessibilityLabel("Loading inbox")
            }
        }
        .task(id: isActive ? (optInOnly ? 2 : 1) : 0) {
            if isActive { await reload() }
        }
        // A pushed destination can mutate Inbox membership while this snapshot
        // is covered and not receiving notifications. Refresh when navigation
        // reveals it again so newly added candidates and policy changes also
        // catch up, while `currentEpisodes` removes stale rows immediately.
        .onAppear {
            if isActive, candidates != nil { startReload() }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .earshotInboxDidChange)
                .receive(on: DispatchQueue.main)
        ) { _ in
            if isActive { scheduleReload() }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .earshotQueueDidChange)
                .receive(on: DispatchQueue.main)
        ) { _ in
            if isActive { scheduleReload() }
        }
        .onDisappear { reloadTask?.cancel() }
    }

    /// Inbox and Queue notifications commonly describe the same durable
    /// mutation. Collapse notifications delivered in one main-run-loop turn so
    /// the relationship query runs once without delaying later independent
    /// changes.
    private func scheduleReload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.async {
            reloadScheduled = false
            startReload()
        }
    }

    private func startReload() {
        reloadTask?.cancel()
        reloadTask = Task { await reload() }
    }

    private func reload() async {
        let interval = PerformanceSignposts.signposter.beginInterval("InboxReload")
        reloadGeneration += 1
        let generation = reloadGeneration
        do {
            let snapshot = try await InboxSnapshotLoader.all(
                modelContainer: context.container,
                optInOnly: optInOnly
            )
            let loaded = try await resolveInboxEpisodes(
                snapshot.ids,
                in: context
            )
            guard isActive, generation == reloadGeneration else {
                PerformanceSignposts.signposter.endInterval("InboxReload", interval)
                return
            }
            candidates = loaded
            PerformanceSignposts.signposter.endInterval(
                "InboxReload",
                interval,
                "inspectedCount=\(snapshot.inspectedCount), returnedCount=\(loaded.count)"
            )
        } catch {
            PerformanceSignposts.signposter.endInterval("InboxReload", interval)
            guard !Task.isCancelled else { return }
            AppLog.data.error(
                "Inbox reload failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}

/// Live snapshot for one folder subtree. SwiftData cannot safely express a
/// captured array `contains` across Episode's optional Podcast relationship, so
/// ``InboxRepository/inboxEpisodes(in:)`` performs supported scalar relationship
/// predicates per de-duplicated podcast. Reloads are event-driven: scope changes
/// or the same Inbox mutation notification that refreshes the tab badge — never
/// playback-position saves (#736, #763).
struct FolderScopedInboxCandidates<Content: View>: View {
    @Environment(\.modelContext) private var context
    @Environment(SettingsStore.self) private var settings
    let folder: PodcastFolder
    let isActive: Bool
    let content: ([Episode]) -> Content

    @State private var candidates: [Episode] = []
    @State private var loaded = false
    @State private var reloadScheduled = false
    @State private var reloadGeneration = 0
    @State private var reloadTask: Task<Void, Never>?

    init(
        folder: PodcastFolder,
        isActive: Bool = true,
        @ViewBuilder content: @escaping ([Episode]) -> Content
    ) {
        self.folder = folder
        self.isActive = isActive
        self.content = content
    }

    private var scopeSignature: [String] {
        [
            String(describing: folder.persistentModelID),
            "opt-in-only:\(settings.inboxOptInOnly)",
        ]
    }

    var body: some View {
        Group {
            if loaded {
                content(InboxRepository.currentEpisodes(candidates, in: context))
            } else {
                ProgressView("Loading folder inbox")
                    .accessibilityLabel("Loading folder inbox")
            }
        }
        .task(id: scopeSignature + ["active:\(isActive)"]) {
            if isActive { await reload() }
        }
        // Returning from a podcast detail doesn't change `scopeSignature`, so
        // `.task(id:)` alone may retain the pre-navigation candidate snapshot.
        .onAppear {
            if isActive, loaded { startReload() }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .earshotInboxDidChange)
                .receive(on: DispatchQueue.main)
        ) { _ in
            if isActive { scheduleReload() }
        }
        .onDisappear { reloadTask?.cancel() }
        .onReceive(
            NotificationCenter.default.publisher(for: .earshotQueueDidChange)
                .receive(on: DispatchQueue.main)
        ) { _ in
            if isActive { scheduleReload() }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .earshotFoldersDidChange)
                .receive(on: DispatchQueue.main)
        ) { _ in
            if isActive { scheduleReload() }
        }
    }

    private func scheduleReload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.async {
            reloadScheduled = false
            startReload()
        }
    }

    private func startReload() {
        reloadTask?.cancel()
        reloadTask = Task { await reload() }
    }

    private func reload() async {
        let interval = PerformanceSignposts.signposter.beginInterval("InboxReload")
        reloadGeneration += 1
        let generation = reloadGeneration
        let folderID = folder.persistentModelID
        let optInOnly = settings.inboxOptInOnly
        do {
            let snapshot = try await InboxSnapshotLoader.folder(
                modelContainer: context.container,
                id: folderID,
                optInOnly: optInOnly
            )
            let resolved = try await resolveInboxEpisodes(snapshot.ids, in: context)
            guard isActive, generation == reloadGeneration else {
                PerformanceSignposts.signposter.endInterval("InboxReload", interval)
                return
            }
            candidates = resolved
            loaded = true
            PerformanceSignposts.signposter.endInterval(
                "InboxReload",
                interval,
                "inspectedCount=\(snapshot.inspectedCount), returnedCount=\(resolved.count)"
            )
        } catch {
            PerformanceSignposts.signposter.endInterval("InboxReload", interval)
            guard !Task.isCancelled else { return }
            AppLog.data.error(
                "Folder Inbox reload failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}

/// Main-context resolution is deliberately chunked. The background loader owns
/// the expensive relationship query; this hop creates the exact models the UI
/// already expects while yielding between bounded groups so accessibility work
/// is never locked out by a large identity snapshot.
@MainActor
private func resolveInboxEpisodes(
    _ ids: [PersistentIdentifier],
    in context: ModelContext
) async throws -> [Episode] {
    let chunkSize = InboxLogic.displayBatchSize
    var resolved: [Episode] = []
    resolved.reserveCapacity(ids.count)
    for start in stride(from: 0, to: ids.count, by: chunkSize) {
        try Task.checkCancellation()
        let end = min(ids.count, start + chunkSize)
        for id in ids[start..<end] {
            if let episode = context.model(for: id) as? Episode,
               !episode.isDeleted,
               episode.modelContext == context {
                resolved.append(episode)
            }
        }
        await Task.yield()
    }
    return resolved
}
