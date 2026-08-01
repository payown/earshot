import SwiftUI
import SwiftData

/// The Inbox: new, untriaged episodes. Each row carries the configured episode
/// Quick Actions (rotor + default tap). "Clear inbox" dismisses everything
/// currently shown.
struct InboxScreen: View {
    @Environment(\.modelContext) private var context
    @Environment(PlayerService.self) private var player
    @Environment(DownloadManager.self) private var downloads
    @Environment(QuickActionStore.self) private var quickActions
    @Environment(SettingsStore.self) private var settings

    // Membership is wholly store-queryable. This prevents an in-memory access to
    // each Episode's Podcast from faulting the Podcast's full inverse episode
    // collection on large libraries. Restricted to unplayed episodes
    // (`playedAt == nil`) so a 5-second playback-position save doesn't
    // re-materialize the whole non-dismissed library — which grows without bound
    // over listening history — while this screen is on top during playback. The
    // `.newEpisode` narrowing below is unchanged, so the displayed rows are
    // identical (played episodes were already filtered out); this only keeps them
    // out of the fetch. Mirrors `RootView.InboxTabBadge`.
    @Query(filter: InboxQuery.normalUnplayed, sort: \Episode.pubDate, order: .reverse)
    private var normalCandidates: [Episode]
    @Query(filter: InboxQuery.optInOnlyUnplayed, sort: \Episode.pubDate, order: .reverse)
    private var optedInCandidates: [Episode]

    @State private var showNotesEpisode: Episode?
    @State private var sharingEpisode: Episode?
    // The episode a pending "Export audio" Quick Action targets (#689). Drives
    // the shared `.episodeAudioExport` download-then-share flow.
    @State private var exportEpisode: Episode?
    @State private var bookmarksEpisode: Episode?
    // The pending "Add to folder" / "Move to folder" Quick Action target (#756).
    // Non-nil presents the shared `FolderPickerView` for the single episode.
    @State private var folderPickRequest: FolderPickRequest?
    @State private var confirmingClear = false
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
    @AccessibilityFocusState private var focusEmpty: Bool
    // Focus target for the row that should take VoiceOver focus after the rotor
    // "Mark as played" removes the focused row from the inbox (#579). Mirrors
    // the Queue's neighbor-focus wiring.
    @AccessibilityFocusState private var focusedEpisode: PersistentIdentifier?
    // Tracked by SwiftUI, so toggling VoiceOver while the Inbox is on screen
    // re-renders the rows and attaches/removes the swipe actions immediately —
    // no relaunch. (Reading UIAccessibility.isVoiceOverRunning in body would
    // not invalidate.) Mirrors the Queue's SightedRowActions gate.
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    var body: some View {
        // Compute the inbox once per body so the list, empty-state check, title,
        // count, and Clear dialog all read a single value instead of re-running
        // the filter (formerly a re-fetch) several times per render.
        // EpisodeStatus is stored as a Codable enum and is not translated by
        // SwiftData predicates. This bounded scalar check is safe; the expensive
        // Podcast relationship rules have already run in SQLite.
        let candidates = settings.inboxOptInOnly ? optedInCandidates : normalCandidates
        let inbox = candidates.filter { $0.status == .newEpisode }
        // What the list actually shows: the inbox narrowed by the search field
        // (#457). With no search active this IS `inbox` (same array, no copy).
        let visible = EpisodeSearchFilter.filter(inbox, query: searchText)
        let displayed = visible.prefix(displayedEpisodeLimit)
        return Group {
            if inbox.isEmpty {
                ContentUnavailableView(
                    "Inbox is empty",
                    systemImage: "tray",
                    description: Text("New episodes you haven't triaged appear here.")
                )
                .accessibilityElement(children: .combine)
                .accessibilityFocused($focusEmpty)
            } else if visible.isEmpty {
                // Search matched nothing. Bound to the same focus target as the
                // true empty state, so the rotor mark-played / unfollow flows
                // that park VoiceOver on "the empty state" land here when a
                // search is active.
                NoSearchMatchesView(query: searchText)
                    .accessibilityFocused($focusEmpty)
            } else {
                List {
                    // The rotor is owned EXCLUSIVELY by the row's configurable
                    // episode Quick Actions ("Mark as played" via `.markPlayed`,
                    // "Unfollow this podcast" via `.unfollow`, #572). Both swipes
                    // below are sighted-only affordances, attached only when
                    // VoiceOver is off: on device, iOS mirrors swipe actions into
                    // the rotor even through `.accessibilityHidden(true)` — the
                    // hidden-swipe suppression this file used to rely on for
                    // mark-played did NOT survive contact with iOS (a duplicate
                    // "Mark as played" stop, #572), and the unfollow swipe's
                    // mirror was made redundant by the `.unfollow` Quick Action.
                    // Toggling VoiceOver mid-session updates `voiceOverEnabled`
                    // and re-renders these rows — no relaunch needed.
                    ForEach(displayed) { episode in
                        rowContainer(for: episode)
                            // Lets the rotor mark-played runner hand VoiceOver
                            // focus to this row when its neighbor vanishes (#579).
                            .accessibilityFocused($focusedEpisode, equals: episode.persistentModelID)
                            // Same focus id on whichever row variant renders, so
                            // focus can be moved onto the first row when selection
                            // mode is entered (#758).
                            .accessibilityFocused($focusedRowID, equals: episode.persistentModelID)
                    }
                    if displayed.count < visible.count {
                        Button {
                            displayedEpisodeLimit = InboxLogic.nextDisplayLimit(
                                current: displayedEpisodeLimit,
                                total: visible.count
                            )
                            let newCount = displayedEpisodeLimit
                            Announcer.announce("Showing \(newCount) of \(visible.count) episodes")
                        } label: {
                            Label("Show 100 more", systemImage: "chevron.down.circle")
                        }
                        .accessibilityLabel("Show 100 more episodes")
                        .accessibilityHint("Currently showing \(displayed.count) of \(visible.count) episodes")
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
                    Button {
                        confirmingClear = true
                    } label: {
                        Label("Clear inbox", systemImage: "tray.and.arrow.down")
                    }
                }
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
            actions: actions(for: episode),
            includesPodcastName: true
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
            if InboxRepository(context: context).inboxEpisodes().isEmpty {
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

    private func clearInbox() {
        InboxRepository(context: context).clearInbox()
        Announcer.announce("Inbox cleared")
        // The list collapses to the empty state; move focus there so VoiceOver
        // isn't orphaned on the vanished Clear button.
        // Delay so the list has collapsed to the empty state (the focus target)
        // before we request focus on it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { focusEmpty = true }
    }

    /// Marks `episode` played and dismisses it from the inbox via the shared
    /// repository path (#546), then announces it. If that empties the inbox the
    /// focused row is gone, so move VoiceOver focus to the empty state (mirrors
    /// `clearInbox` / `unfollow`).
    private func markPlayed(_ episode: Episode) {
        InboxRepository(context: context).markPlayed(episode)
        Announcer.announce("Marked as played")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if InboxRepository(context: context).inboxEpisodes().isEmpty {
                focusEmpty = true
            }
        }
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
                InboxRepository(context: context).inboxEpisodes(), query: searchText
            ).isEmpty {
                focusEmpty = true
            }
        }
    }

    private func actions(for episode: Episode) -> [QuickActionItem] {
        buildEpisodeActions(
            episode: episode,
            order: quickActions.episodeActions,
            player: player,
            downloads: downloads,
            context: context,
            onShowNotes: { showNotesEpisode = episode },
            onShare: { sharingEpisode = episode },
            onBookmarks: { bookmarksEpisode = episode },
            // Rotor "Unfollow this podcast" (#572): opens the SAME destructive
            // confirmation the trailing swipe uses — activation never unfollows
            // directly.
            onUnfollow: { pendingUnfollow = episode.podcast },
            // Rotor "Mark as played" removes this row from the inbox (#579).
            // The builder invokes this BEFORE the played flip, so the neighbor
            // is captured while the row is still in the list; focus moves after
            // the list has re-rendered — to the neighbor, or the empty state
            // when this was the last row (mirrors clearInbox / unfollow).
            onMarkPlayed: { nowPlayed in
                guard nowPlayed else { return }
                // Neighbors come from the list as DISPLAYED: when a search is
                // active the inbox is narrowed by the filter, so the neighbor
                // must be the adjacent VISIBLE row, not an inbox row the filter
                // is hiding (#457). With no search active the filter returns
                // the array unchanged, preserving the original #579 behavior.
                let neighbor = neighborID(
                    of: episode,
                    in: EpisodeSearchFilter.filter(
                        InboxRepository(context: context).inboxEpisodes(),
                        query: searchText
                    )
                )
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if let neighbor {
                        focusedEpisode = neighbor
                    } else {
                        focusEmpty = true
                    }
                }
            },
            // Rotor "Export audio" (#689): downloads if needed, then shares the
            // local file. Handled by `.episodeAudioExport`.
            onExport: { exportEpisode = episode },
            // Rotor "Add to folder" / "Move to folder" (#756): presents the
            // shared `FolderPickerView` for this single episode. The picker files
            // it, announces, and dismisses.
            onAddToFolder: { folderPickRequest = .episode($0, mode: .add) },
            onMoveToFolder: { folderPickRequest = .episode($0, mode: .move) }
        )
    }

    /// Announces the search's match count on submit (#457). Guarded so an empty
    /// or whitespace-only field never announces; Announcer itself is a no-op
    /// with VoiceOver off.
    private func announceMatches(count: Int) {
        guard EpisodeSearchFilter.isActive(searchText) else { return }
        Announcer.announce(EpisodeSearchFilter.resultAnnouncement(count: count))
    }

    private func shareItems(for episode: Episode) -> [Any] {
        if let url = URL(string: episode.audioURL) {
            return [episode.title, url]
        }
        return [episode.title]
    }
}
