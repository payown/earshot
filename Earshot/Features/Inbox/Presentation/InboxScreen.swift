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

    init(
        candidates: [Episode],
        eligibleCount: Int,
        skippedCount: Int,
        scope: String
    ) {
        self.candidates = candidates
        episodes = candidates
        self.eligibleCount = eligibleCount
        self.skippedCount = skippedCount
        deferredCount = max(0, eligibleCount - candidates.count)
        self.scope = scope
    }
}

struct InboxPresentationSnapshot {
    let episodes: [Episode]
    let downloadCandidates: [Episode]
    let inboxCount: Int
    let matchingCount: Int
    let downloadEligibleCount: Int
    let downloadSkippedCount: Int
}

enum InboxPendingFocusTarget<ID: Hashable>: Equatable {
    case episode(ID)
    case empty
    case wait
}

enum InboxPendingFocusLogic {
    static func target<ID: Hashable>(
        pendingEpisode: ID?,
        pendingEmpty: Bool,
        publishedEpisodes: [ID],
        matchingCount: Int
    ) -> InboxPendingFocusTarget<ID> {
        if let pendingEpisode {
            if publishedEpisodes.contains(pendingEpisode) {
                return .episode(pendingEpisode)
            }
            if let fallback = publishedEpisodes.first {
                return .episode(fallback)
            }
            if matchingCount == 0 { return .empty }
        } else if pendingEmpty {
            if let fallback = publishedEpisodes.first {
                return .episode(fallback)
            }
            if matchingCount == 0 { return .empty }
        }
        return .wait
    }
}

struct InboxReloadCoalescer: Equatable {
    private(set) var isScheduled = false

    mutating func request() -> Bool {
        guard !isScheduled else { return false }
        isScheduled = true
        return true
    }

    mutating func consume() {
        isScheduled = false
    }
}

struct InboxCandidateQueryKey: Equatable, Hashable {
    let scope: InboxPageScope
    let optInOnly: Bool
    let searchText: String
}

extension InboxPageScope {
    var loadingAccessibilityLabel: String {
        switch self {
        case .all: "Loading inbox"
        case .folder: "Loading folder inbox"
        }
    }
}

enum InboxLoadPresentationPhase: Equatable {
    case content
    case loading
    case retry
}

enum InboxCandidatePresentationLogic {
    static func phase(
        requested: InboxCandidateQueryKey,
        published: InboxCandidateQueryKey?,
        failed: InboxCandidateQueryKey?
    ) -> InboxLoadPresentationPhase {
        if published == requested { return .content }
        if failed == requested { return .retry }
        return .loading
    }
}

struct InboxShellResultState: Equatable {
    private(set) var matchingCount: Int?

    mutating func queryDidChange() {
        matchingCount = nil
    }

    mutating func didPublish(matchingCount: Int) {
        self.matchingCount = matchingCount
    }
}

struct InboxShowMoreRequest: Equatable {
    let previousCount: Int
}

struct InboxShowMorePublication<ID: Hashable>: Equatable {
    let announcement: String
    let terminalFocus: ID?
}

enum InboxShowMoreLogic {
    static func publication<ID: Hashable>(
        pending: InboxShowMoreRequest?,
        publishedIDs: [ID],
        totalCount: Int,
        noun: String
    ) -> InboxShowMorePublication<ID>? {
        guard let pending, publishedIDs.count > pending.previousCount else { return nil }
        let terminal = publishedIDs.count >= totalCount ? publishedIDs.last : nil
        return InboxShowMorePublication(
            announcement: "Showing \(publishedIDs.count) of \(totalCount) \(noun)",
            terminalFocus: terminal
        )
    }
}

/// The Inbox: new, untriaged episodes. Each row carries the configured episode
/// Quick Actions (rotor + default tap). "Clear inbox" dismisses everything
/// currently shown.
struct InboxScreen: View {
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
    @State private var pendingUnfollowLeavesVisibleEmpty = false
    // The in-place `.searchable` filter (#457, Part A). Pure presentation: the
    // @Query-backed inbox is filtered in memory, never re-fetched.
    @State private var searchText = ""
    /// Keep initial view construction bounded on large inboxes. More episodes
    /// remain available in explicit, predictable batches without deleting data.
    @State private var displayedEpisodeLimit = InboxLogic.displayBatchSize
    @State private var pendingShowMore: InboxShowMoreRequest?
    @State private var shellResultState = InboxShellResultState()
    @AccessibilityFocusState private var focusEmpty: Bool
    // Focus target for the row that should take VoiceOver focus after the rotor
    // "Mark as played" removes the focused row from the inbox (#579). Mirrors
    // the Queue's neighbor-focus wiring.
    @AccessibilityFocusState private var focusedEpisode: PersistentIdentifier?
    @State private var pendingFocusedEpisode: PersistentIdentifier?
    @State private var pendingEmptyFocus = false
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
        VStack(spacing: 0) {
            inboxFilter
            Group {
                if let selectedFolder {
                    InboxCandidates(
                        scope: .folder(selectedFolder.persistentModelID),
                        optInOnly: settings.inboxOptInOnly,
                        searchText: searchText,
                        requestedLimit: displayedEpisodeLimit,
                        onPagePublished: applyPublishedInboxPage
                    ) { snapshot in
                        inboxContent(snapshot: snapshot)
                    }
                } else {
                    InboxCandidates(
                        scope: .all,
                        optInOnly: settings.inboxOptInOnly,
                        searchText: searchText,
                        requestedLimit: displayedEpisodeLimit,
                        onPagePublished: applyPublishedInboxPage
                    ) { snapshot in
                        inboxContent(snapshot: snapshot)
                    }
                }
            }
        }
        // The search and folder-filter shell lives above the result-state switch.
        // A new actor query can replace rows with Loading/Retry without replacing
        // the search field and collapsing its VoiceOver or keyboard focus.
        .searchable(text: $searchText, prompt: "Search inbox")
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
        .onChange(of: searchText) { _, _ in
            shellResultState.queryDidChange()
            pendingShowMore = nil
            displayedEpisodeLimit = InboxLogic.displayBatchSize
        }
        .onChange(of: selectedFolderID) { _, _ in
            shellResultState.queryDidChange()
            pendingShowMore = nil
            displayedEpisodeLimit = InboxLogic.displayBatchSize
        }
        .onSubmit(of: .search) {
            if let matchingCount = shellResultState.matchingCount {
                announceMatches(count: matchingCount)
            }
        }
    }

    private func inboxContent(snapshot: InboxPresentationSnapshot) -> some View {
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
        let visible = InboxRepository.liveEpisodes(snapshot.episodes, in: context)
            .filter { $0.status == .newEpisode }
        let displayed = visible[...]
        return Group {
                if snapshot.inboxCount == 0 {
                    ContentUnavailableView(
                        selectedFolder == nil ? "Inbox is empty" : "No new episodes",
                        systemImage: "tray",
                        description: Text(emptyDescription)
                    )
                    .accessibilityElement(children: .combine)
                    .accessibilityFocused($focusEmpty)
                } else if snapshot.matchingCount == 0 {
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
                            rowContainer(
                                for: episode,
                                visible: visible,
                                inboxCount: snapshot.inboxCount
                            )
                                .accessibilityFocused(
                                    $focusedEpisode, equals: episode.persistentModelID
                                )
                                .accessibilityFocused(
                                    $focusedRowID, equals: episode.persistentModelID
                                )
                        }
                        if displayed.count < snapshot.matchingCount {
                            Button {
                                pendingShowMore = InboxShowMoreRequest(
                                    previousCount: displayed.count
                                )
                                displayedEpisodeLimit = InboxLogic.nextDisplayLimit(
                                    current: displayedEpisodeLimit,
                                    total: snapshot.matchingCount
                                )
                            } label: {
                                Label("Show 100 more", systemImage: "chevron.down.circle")
                            }
                            .accessibilityLabel("Show 100 more episodes")
                            .accessibilityHint(
                                "Currently showing \(displayed.count) of \(snapshot.matchingCount) episodes"
                            )
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
                            handler: {
                                addSelectedToQueue(
                                    visible: visible,
                                    inboxCount: snapshot.inboxCount
                                )
                            }
                        ),
                        MultiSelectAction(
                            id: "played",
                            title: EpisodeBatchLabel.markPlayed(count: selection.count),
                            systemImage: "checkmark.circle",
                            handler: {
                                markSelectedPlayed(
                                    visible: visible,
                                    inboxCount: snapshot.inboxCount
                                )
                            }
                        ),
                    ],
                    announcementNoun: "episode"
                )
                .transition(.move(edge: .bottom))
            }
        }
        .toolbar {
            // Deliberately `inbox.count`, not `visible.count`: the title states
            // the TOTAL inbox size even while a search narrows the list (#457).
            // The title is the inbox's identity, not the filter's result count —
            // the match tally is announced from the search field on submit.
            ToolbarItem(placement: .principal) {
                Text(InboxLogic.inboxTitle(count: snapshot.inboxCount))
                    .font(.headline)
                    .accessibilityLabel(InboxLogic.inboxTitleAccessibilityLabel(count: snapshot.inboxCount))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($focusLaunchHeading)
            }
            // Select / Done toggles selection mode (#758). "Select" enters and
            // moves VoiceOver focus to the first row; "Done" exits and announces
            // the change. Only offered when there's something to select; hidden
            // while the inbox is empty just like Clear inbox. The batch actions
            // themselves live in the bottom MultiSelectBar, not the toolbar.
            if snapshot.inboxCount > 0 {
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
            if !selection.isSelecting && snapshot.inboxCount > 0 {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            downloadAllRequest = DownloadAllRequest(
                                candidates: snapshot.downloadCandidates,
                                eligibleCount: snapshot.downloadEligibleCount,
                                skippedCount: snapshot.downloadSkippedCount,
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
            downloadAllConfirmationTitle,
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
            Button("Clear inbox", role: .destructive) { clearInbox() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Hides all \(snapshot.inboxCount) episodes from the inbox. They stay in your podcasts.")
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
    private func rowContainer(
        for episode: Episode,
        visible: [Episode],
        inboxCount: Int
    ) -> some View {
        if selection.isSelecting {
            EpisodeSelectableRow(
                episode: episode,
                includesPodcastName: true,
                isSelected: selection.isSelected(episode.persistentModelID),
                onToggle: { selection.toggle(episode.persistentModelID) }
            )
        } else {
            normalRow(for: episode, visible: visible, inboxCount: inboxCount)
        }
    }

    /// The normal Inbox row: the configurable episode Quick Actions (rotor + tap)
    /// plus, for sighted users only, the mark-played and unfollow swipes. Selection
    /// mode swaps this out entirely for ``EpisodeSelectableRow`` (#758).
    @ViewBuilder
    private func normalRow(
        for episode: Episode,
        visible: [Episode],
        inboxCount: Int
    ) -> some View {
        let row = episodeRow(for: episode, visible: visible, inboxCount: inboxCount)
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
                        markPlayed(episode, inboxCount: inboxCount)
                    } label: {
                        Label("Mark as played", systemImage: "checkmark.circle")
                    }
                    .tint(.green)
                    Button {
                        removeFromInbox(episode, visible: visible)
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
                            prepareUnfollow(podcast, visible: visible)
                        } label: {
                            Label("Unfollow this podcast", systemImage: "xmark.bin")
                        }
                    }
                }
        }
    }

    private func episodeRow(
        for episode: Episode,
        visible: [Episode],
        inboxCount: Int
    ) -> EpisodeRow {
        EpisodeRow(
            episode: episode,
            deferredActions: availableActions(for: episode),
            includesPodcastName: true,
            performAction: { action in
                perform(action, for: episode, visible: visible, inboxCount: inboxCount)
            }
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
    private func exitSelection(
        announce: Bool,
        focusDelay: TimeInterval = 0.5,
        inboxWillBeEmpty: Bool = false
    ) {
        withAnimation(Motion.preferred(.easeInOut(duration: 0.2))) {
            selection.exit()
        }
        if announce {
            Announcer.announce("Selection mode off")
        }
        if inboxWillBeEmpty {
            pendingEmptyFocus = true
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + focusDelay) {
            focusSelectButton = true
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
    private func addSelectedToQueue(visible: [Episode], inboxCount: Int) {
        let toAdd = selectedEpisodes(in: visible)
        guard !toAdd.isEmpty else { return }
        QueueRepository(context: context).add(toAdd)
        // Noun-carrying result ("Added 3 episodes to queue"), matching the folder
        // batch announcement's phrasing.
        Announcer.announce("Added \(EpisodeBatchLabel.episodePhrase(toAdd.count)) to queue", assertive: true)
        exitSelection(announce: false, inboxWillBeEmpty: toAdd.count >= inboxCount)
    }

    /// Marks every selected episode played and dismisses them from the inbox via
    /// the shared ``InboxRepository/markPlayed(_:)`` path (the same one the
    /// sighted swipe and rotor use), then exits selection mode. The marked
    /// episodes leave the inbox, so `exitSelection` re-anchors focus off the
    /// removed rows.
    private func markSelectedPlayed(visible: [Episode], inboxCount: Int) {
        let toMark = selectedEpisodes(in: visible)
        guard !toMark.isEmpty else { return }
        let repo = InboxRepository(context: context)
        for episode in toMark {
            repo.markPlayed(episode)
        }
        Announcer.announce("Marked \(EpisodeBatchLabel.episodePhrase(toMark.count)) as played", assertive: true)
        exitSelection(announce: false, inboxWillBeEmpty: toMark.count >= inboxCount)
    }

    private func clearInbox() {
        let scope = selectedFolderID.map(InboxPageScope.folder) ?? .all
        let optInOnly = settings.inboxOptInOnly
        Task { @MainActor in
            pendingEmptyFocus = true
            _ = await InboxRepository(context: context).clearInbox(
                scope: scope,
                optInOnly: optInOnly
            )
            Announcer.announce("Inbox cleared")
        }
    }

    private func startDownloadAll(_ request: DownloadAllRequest) {
        downloadAllRequest = nil
        isEnrollingDownloads = true
        Task { @MainActor in
            let batch = await downloads.downloadAll(request.candidates)
            isEnrollingDownloads = false
            let report = DownloadBatchReport(
                eligible: request.eligibleCount,
                started: batch.started,
                skipped: request.skippedCount + batch.skipped,
                deferred: request.deferredCount,
                failed: batch.failed,
                wasCancelled: batch.wasCancelled
            )
            Announcer.announce(report.announcement, assertive: true)
        }
    }

    private var downloadAllConfirmationTitle: String {
        guard let request = downloadAllRequest else { return "Download episodes?" }
        if request.deferredCount > 0 {
            return "Download the next \(request.episodes.count) episodes?"
        }
        return "Download \(request.episodes.count) episodes?"
    }

    /// Marks `episode` played and dismisses it from the inbox via the shared
    /// repository path (#546), then announces it. If that empties the inbox the
    /// focused row is gone, so move VoiceOver focus to the empty state (mirrors
    /// `clearInbox` / `unfollow`).
    private func markPlayed(_ episode: Episode, inboxCount: Int) {
        InboxRepository(context: context).markPlayed(episode)
        Announcer.announce("Marked as played")
        if inboxCount == 1 { pendingEmptyFocus = true }
    }

    private func removeFromInbox(_ episode: Episode, visible: [Episode]) {
        focusAfterInboxRowLeaves(episode, in: visible)
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
        if pendingUnfollowLeavesVisibleEmpty { pendingEmptyFocus = true }
    }

    private func prepareUnfollow(_ podcast: Podcast, visible: [Episode]) {
        let podcastID = podcast.persistentModelID
        pendingUnfollowLeavesVisibleEmpty = !visible.contains {
            $0.podcast?.persistentModelID != podcastID
        }
        pendingUnfollow = podcast
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
    private func perform(
        _ action: EpisodeAction,
        for episode: Episode,
        visible: [Episode],
        inboxCount: Int
    ) {
        buildEpisodeActions(
            episode: episode,
            order: [action],
            player: player,
            downloads: downloads,
            context: context,
            onShowNotes: { showNotesEpisode = episode },
            onShare: { sharingEpisode = episode },
            onBookmarks: { bookmarksEpisode = episode },
            onUnfollow: {
                if let podcast = episode.podcast {
                    prepareUnfollow(podcast, visible: visible)
                }
            },
            onMarkPlayed: { nowPlayed in
                guard nowPlayed else { return }
                focusAfterInboxRowLeaves(episode, in: visible)
            },
            onWillQueue: { focusAfterInboxRowLeaves(episode, in: visible) },
            onExport: { exportEpisode = episode },
            onExportTranscript: { exportTranscriptEpisode = episode },
            onAddToFolder: { folderPickRequest = .episode($0, mode: .add) },
            onMoveToFolder: { folderPickRequest = .episode($0, mode: .move) },
            onRemoveFromInbox: { removeFromInbox(episode, visible: visible) }
        ).first?.run()
    }

    /// Announces the search's match count on submit (#457). Guarded so an empty
    /// or whitespace-only field never announces; Announcer itself is a no-op
    /// with VoiceOver off.
    private func announceMatches(count: Int) {
        guard EpisodeSearchFilter.isActive(searchText) else { return }
        Announcer.announce(EpisodeSearchFilter.resultAnnouncement(count: count))
    }

    /// Re-anchors VoiceOver after a played or queued action removes an Inbox row.
    /// The neighbor comes from the list as displayed — folder scope and search
    /// included — and is captured before the mutation changes membership.
    private func focusAfterInboxRowLeaves(_ episode: Episode, in visible: [Episode]) {
        let neighbor = neighborID(of: episode, in: visible)
        pendingFocusedEpisode = neighbor
        pendingEmptyFocus = neighbor == nil
    }

    private func applyPendingFocus(_ snapshot: InboxPresentationSnapshot) {
        let target = InboxPendingFocusLogic.target(
            pendingEpisode: pendingFocusedEpisode,
            pendingEmpty: pendingEmptyFocus,
            publishedEpisodes: snapshot.episodes.map(\.persistentModelID),
            matchingCount: snapshot.matchingCount
        )
        switch target {
        case .episode(let episodeID):
            self.pendingFocusedEpisode = nil
            pendingEmptyFocus = false
            DispatchQueue.main.async { focusedEpisode = episodeID }
        case .empty:
            pendingFocusedEpisode = nil
            pendingEmptyFocus = false
            DispatchQueue.main.async { focusEmpty = true }
        case .wait:
            break
        }
    }

    private func applyPublishedInboxPage(_ snapshot: InboxPresentationSnapshot) {
        shellResultState.didPublish(matchingCount: snapshot.matchingCount)
        applyPendingFocus(snapshot)
        guard let publication = InboxShowMoreLogic.publication(
            pending: pendingShowMore,
            publishedIDs: snapshot.episodes.map(\.persistentModelID),
            totalCount: snapshot.matchingCount,
            noun: "episodes"
        ) else { return }
        pendingShowMore = nil
        DispatchQueue.main.async {
            Announcer.announce(publication.announcement)
            if let terminalFocus = publication.terminalFocus {
                focusedEpisode = terminalFocus
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

/// Event-driven, actor-backed Inbox page. Only resolved models for the requested
/// page enter the main context; folder traversal, status filtering, search, and
/// total counts remain off the VoiceOver-critical actor.
struct InboxCandidates<Content: View>: View {
    @Environment(\.modelContext) private var context
    @Environment(SettingsStore.self) private var settings
    let scope: InboxPageScope
    let optInOnly: Bool
    let searchText: String
    let requestedLimit: Int
    let onPagePublished: (InboxPresentationSnapshot) -> Void
    let content: (InboxPresentationSnapshot) -> Content
    @State private var snapshot: InboxPresentationSnapshot?
    @State private var publishedQuery: InboxCandidateQueryKey?
    @State private var failedQuery: InboxCandidateQueryKey?
    @State private var reloadCoalescer = InboxReloadCoalescer()
    @State private var generation = 0

    init(
        scope: InboxPageScope,
        optInOnly: Bool,
        searchText: String,
        requestedLimit: Int,
        onPagePublished: @escaping (InboxPresentationSnapshot) -> Void = { _ in },
        @ViewBuilder content: @escaping (InboxPresentationSnapshot) -> Content
    ) {
        self.scope = scope
        self.optInOnly = optInOnly
        self.searchText = searchText
        self.requestedLimit = requestedLimit
        self.onPagePublished = onPagePublished
        self.content = content
    }

    var body: some View {
        Group {
            switch InboxCandidatePresentationLogic.phase(
                requested: queryKey,
                published: publishedQuery,
                failed: failedQuery
            ) {
            case .content:
                if let snapshot { content(snapshot) }
            case .loading:
                ProgressView(loadingLabel)
                    .accessibilityLabel(loadingLabel)
            case .retry:
                ContentUnavailableView {
                    Label("Unable to load inbox", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("The inbox could not be loaded.")
                } actions: {
                    Button("Retry") {
                        failedQuery = nil
                        generation &+= 1
                    }
                }
            }
        }
        .task(id: RequestKey(
            scope: scope,
            optInOnly: optInOnly,
            searchText: searchText,
            requestedLimit: requestedLimit,
            generation: generation
        )) {
            await reload(query: queryKey, limit: requestedLimit)
        }
        // A pushed destination can mutate Inbox membership while this snapshot
        // is covered and not receiving notifications. Refresh when navigation
        // reveals it again so newly added candidates and policy changes also
        // catch up, while `currentEpisodes` removes stale rows immediately.
        .onAppear {
            if snapshot != nil { scheduleReload() }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .earshotInboxDidChange)
                .receive(on: DispatchQueue.main)
        ) { _ in
            scheduleReload()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .earshotQueueDidChange)
                .receive(on: DispatchQueue.main)
        ) { _ in
            scheduleReload()
        }
    }

    /// Inbox and Queue notifications commonly describe the same durable
    /// mutation. Collapse notifications delivered in one main-run-loop turn so
    /// the relationship query runs once without delaying later independent
    /// changes.
    private func scheduleReload() {
        guard reloadCoalescer.request() else { return }
        DispatchQueue.main.async {
            reloadCoalescer.consume()
            generation &+= 1
        }
    }

    private var queryKey: InboxCandidateQueryKey {
        InboxCandidateQueryKey(
            scope: scope,
            optInOnly: optInOnly,
            searchText: searchText
        )
    }

    private var loadingLabel: String {
        scope.loadingAccessibilityLabel
    }

    private func reload(query: InboxCandidateQueryKey, limit: Int) async {
        let interval = PerformanceSignposts.signposter.beginInterval("InboxReload")
        do {
            let repository = InboxRepository(context: context)
            let page = try await repository.identifierPage(
                scope: query.scope,
                optInOnly: query.optInOnly,
                searchText: query.searchText,
                limit: limit
            )
            try Task.checkCancellation()
            let resolved = repository.resolve(Array(Set(page.ids + page.downloadIDs)))
            let byID = Dictionary(uniqueKeysWithValues: resolved.map {
                ($0.persistentModelID, $0)
            })
            let episodes = page.ids.compactMap { byID[$0] }
            let downloadCandidates = page.downloadIDs.compactMap { byID[$0] }
            let speechRequests = episodes.map {
                SpokenDescriptionRequest(
                    identity: "episode:\($0.guid)\u{1}\($0.audioURL)",
                    html: $0.episodeDescription,
                    mode: settings.spokenEpisodeDescriptionMode,
                    briefLimit: 140
                )
            }
            await SpokenDescriptionCache.shared.prepare(speechRequests)
            try Task.checkCancellation()
            let published = InboxPresentationSnapshot(
                episodes: episodes,
                downloadCandidates: downloadCandidates,
                inboxCount: page.inboxCount,
                matchingCount: page.matchingCount,
                downloadEligibleCount: page.downloadEligibleCount,
                downloadSkippedCount: page.downloadSkippedCount
            )
            snapshot = published
            publishedQuery = query
            failedQuery = nil
            onPagePublished(published)
            PerformanceSignposts.signposter.endInterval(
                "InboxReload",
                interval,
                "candidateCount=\(page.candidateCount, privacy: .public) returnedCount=\(episodes.count, privacy: .public)"
            )
        } catch {
            PerformanceSignposts.signposter.endInterval("InboxReload", interval)
            guard !Task.isCancelled else { return }
            failedQuery = query
        }
    }

    private struct RequestKey: Hashable {
        let scope: InboxPageScope
        let optInOnly: Bool
        let searchText: String
        let requestedLimit: Int
        let generation: Int
    }
}
