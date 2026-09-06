import Combine
import SwiftUI
import SwiftData

struct EpisodeListView: View {
    let podcast: Podcast

    @Environment(\.modelContext) private var context
    @Environment(PlayerService.self) private var player
    @Environment(DownloadManager.self) private var downloads
    @Environment(QuickActionStore.self) private var quickActions
    @Environment(SettingsStore.self) private var settings
    @Environment(EntitlementStore.self) private var entitlements
    @Environment(\.dismiss) private var dismiss

    @State private var showNotesEpisode: Episode?
    @State private var sharingEpisode: Episode?
    // The episode a pending "Export audio" Quick Action targets (#689). Drives
    // the shared `.episodeAudioExport` download-then-share flow.
    @State private var exportEpisode: Episode?
    @State private var exportTranscriptEpisode: Episode?
    @State private var bookmarksEpisode: Episode?
    // The pending "Add to folder" / "Move to folder" Quick Action target (#756).
    @State private var folderPickRequest: FolderPickRequest?
    @State private var showingPodcastSettings = false
    // The pending "Unfollow this podcast" rotor Quick Action (#572). This is a
    // single-show screen, so unfollow always targets the shown `podcast`; it
    // still confirms, and the screen pops after the delete since its podcast is
    // gone. Wording matches InboxScreen / SubscriptionsView.
    @State private var pendingUnfollow: Podcast?
    // "Mark all as played" confirmation gate (#640). Shared by the toolbar
    // button and the screen-level rotor action so both entry points drive the
    // exact same confirm-then-execute flow instead of duplicating it.
    @State private var confirmingMarkAllPlayed = false
    @State private var olderEpisodesState: OlderEpisodesState = .ready
    // Episode multi-select (#758). `selection` is the shared ``MultiSelectState``
    // holder (keyed on persistent identity); `batchRequest` presents the shared
    // ``FolderPickerView`` for the whole selection. Entering selection mode swaps
    // every episode row for a ``SelectableRow`` and shows a bottom
    // ``MultiSelectBar`` with Add/Move to folder plus the natural Add-to-queue
    // batch.
    @State private var selection = MultiSelectState()
    @State private var batchRequest: FolderPickRequest?
    // Podcast-detail search (#457). Applied after the existing played/unheard
    // filter and chronological sort, so it only narrows the list the user is
    // already viewing and never changes either preference.
    @State private var searchText = ""
    /// Store-backed page state. It owns only the requested models and never
    /// touches the potentially 45,000-row `podcast.episodes` inverse.
    @State private var episodeList: EpisodeListDataSource?
    @State private var searchReloadTask: Task<Void, Never>?
    @State private var episodeStateReloadTask: Task<Void, Never>?
    @State private var isBulkEpisodeMutation = false
    // Moves VoiceOver focus onto the first episode row when entering selection
    // mode, and to the Select/Done button on exit; keyed on the stable
    // PersistentIdentifier so focus rides the row across the select-mode toggle
    // (mirrors SubscriptionsView's podcast multi-select, #757).
    @AccessibilityFocusState private var focusedRowID: PersistentIdentifier?
    @AccessibilityFocusState private var focusSelectButton: Bool

    // Focus targets for the rotor "Mark as played" under the Unheard filter,
    // where the marked row leaves the visible list (#579): the neighbor row, or
    // the empty-filter state when the last unheard episode was just marked.
    // Mirrors the Inbox's neighbor-focus wiring.
    @AccessibilityFocusState private var focusedEpisode: PersistentIdentifier?
    @AccessibilityFocusState private var focusEmptyFilter: Bool
    @AccessibilityFocusState private var focusResultsHeading: Bool

    /// Played/unheard filter for this podcast's list. Loaded per podcast on
    /// appear (default ``EpisodeListFilter/unheard``) and persisted on change
    /// under the `podcast_filter_<feedURL>` AppSetting key (#489).
    @State private var filter: EpisodeListFilter = SettingsDefault.episodeListFilter

    /// The currently loaded, still-live page. Filtering, sorting, and search all
    /// happen in the store before these models enter view state.
    private var visibleEpisodes: [Episode] {
        (episodeList?.episodes ?? []).filter { !$0.isDeleted && $0.modelContext == context }
    }

    /// Count of unplayed episodes across the WHOLE podcast, not just the
    /// current filter (#640) — `EpisodeRepository.markAllPlayed` marks every
    /// unplayed episode in the podcast regardless of which filter is showing,
    /// so this drives both the toolbar button's disabled state and the
    /// confirmation copy. Derived from `sortedEpisodes` (the view's existing
    /// unfiltered, sorted source) rather than re-deriving from
    /// `podcast.episodes` directly, so it stays consistent with what the list
    /// is already computing.
    private var unplayedCount: Int {
        episodeList?.unplayedCount ?? 0
    }

    private var allEpisodeCount: Int { episodeList?.allCount ?? 0 }
    private var filteredCount: Int { episodeList?.filteredCount ?? 0 }
    private var matchingCount: Int { episodeList?.matchingCount ?? 0 }

    /// Persists and announces only on a genuine user change, so loading the
    /// stored value on appear doesn't speak over VoiceOver.
    private var filterSelection: Binding<EpisodeListFilter> {
        Binding(
            get: { filter },
            set: { newValue in
                guard newValue != filter else { return }
                filter = newValue
                let store = AppSettingsStore(context: context)
                store.setEpisodeListFilter(newValue, forFeedURL: podcast.feedURL)
                let count = ensureEpisodeList().count(filter: newValue, searchText: "")
                Announcer.announce(newValue.announcement(count: count))
                resetEpisodePage(moveFocusToResults: true)
            }
        )
    }

    var body: some View {
        List {
            Section {
                header
            }
            Section {
                Picker("Filter episodes", selection: filterSelection) {
                    ForEach(EpisodeListFilter.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Filter episodes")
            }
            if filteredCount > 0 {
                Section {
                    chronologicalSortButton
                }
            }
            if allEpisodeCount == 0 && podcast.refreshedAt == nil {
                // Freshly-migrated show whose episodes haven't been fetched yet.
                // Distinguish "still loading" from a genuinely empty feed so a
                // VoiceOver user isn't told "no episodes" prematurely.
                Section {
                    Label("Loading episodes…", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.secondary)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Loading episodes")
                        .accessibilityAddTraits(.updatesFrequently)
                }
            } else if filteredCount == 0 {
                // Episodes exist but none match the current filter. Give a
                // descriptive message and a one-tap way out, not a blank list.
                Section {
                    emptyFilterState
                }
            } else if visibleEpisodes.isEmpty {
                Section {
                    NoSearchMatchesView(query: searchText)
                        .accessibilityFocused($focusEmptyFilter)
                }
            } else {
                Section {
                    ForEach(visibleEpisodes) { episode in
                        rowContainer(for: episode)
                            // Lets the rotor mark-played runner hand VoiceOver focus
                            // to this row when its neighbor vanishes (#579).
                            .accessibilityFocused($focusedEpisode, equals: episode.persistentModelID)
                            // Same focus id on whichever row variant renders, so
                            // focus can be moved onto the first row when selection
                            // mode is entered (#758).
                            .accessibilityFocused($focusedRowID, equals: episode.persistentModelID)
                    }
                    if episodeList?.hasMore == true {
                        Button(showMoreEpisodesLabel) {
                            episodeList?.loadMore(
                                filter: filter,
                                sort: settings.episodeSortOrder,
                                searchText: searchText
                            )
                        }
                    }
                } header: {
                    Text(filter == .unheard
                         ? "^[\(matchingCount) unheard episode](inflect: true)"
                         : "^[\(matchingCount) episode](inflect: true)")
                        .accessibilityFocused($focusResultsHeading)
                }
            }
            if episodeList != nil && episodeList?.hasMore == false {
                Section {
                    olderEpisodesControl
                }
            }
        }
        .task {
            filter = AppSettingsStore(context: context).episodeListFilter(forFeedURL: podcast.feedURL)
            resetEpisodePage(moveFocusToResults: false)
        }
        .navigationTitle(podcast.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search episodes")
        .onChange(of: podcast.displayName) { reloadEpisodePage() }
        .onChange(of: searchText) {
            scheduleSearchReload()
        }
        .onSubmit(of: .search) {
            guard EpisodeSearchFilter.isActive(searchText) else { return }
            searchReloadTask?.cancel()
            resetEpisodePage(moveFocusToResults: false)
            Announcer.announce(EpisodeSearchFilter.resultAnnouncement(count: matchingCount))
            focusResultsHeading = true
        }
        .refreshable { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .earshotWillDeleteEpisodes)
            .receive(on: DispatchQueue.main)) { note in
            guard let deletedPodcastID = note.userInfo?[PlayerService.willDeletePodcastIDKey]
                    as? PersistentIdentifier,
                  deletedPodcastID == podcast.persistentModelID else { return }
            dismiss()
        }
        .onReceive(NotificationCenter.default.publisher(for: .earshotCloudProjectionDidApply)
            .receive(on: DispatchQueue.main)) { _ in
            if podcast.isDeleted {
                dismiss()
            } else {
                reloadEpisodePage()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .earshotEpisodeUserStateDidChange)
            .receive(on: DispatchQueue.main)) { note in
            guard !isBulkEpisodeMutation,
                  let snapshots = note.object as? [EpisodeUserStateSnapshot],
                  snapshots.contains(where: {
                      $0.feedURL == FeedURLIdentity.canonical(podcast.feedURL)
                  })
            else { return }
            // State setters can publish multiple saves in one run-loop turn.
            // Cancel and replace the pending task so the screen performs one
            // scoped page reload, not one reload per notification.
            episodeStateReloadTask?.cancel()
            episodeStateReloadTask = Task { @MainActor in
                await Task.yield()
                guard !Task.isCancelled else { return }
                reloadEpisodePage()
            }
        }
        // Persistent episode multi-select bar (#758): Add to folder is primary and
        // its label carries the live count ("Add 3 episodes to folder") — the
        // accessibility source of truth for the count. Move to folder follows, and
        // the natural Add-to-queue batch rounds it out. Reuses the shared
        // ``MultiSelectBar`` unchanged from podcast multi-select.
        .safeAreaInset(edge: .bottom) {
            if selection.isSelecting {
                MultiSelectBar(
                    count: selection.count,
                    primary: MultiSelectAction(
                        id: "add",
                        title: MultiSelectActionLabel.addToFolder(count: selection.count, itemSingular: "episode"),
                        systemImage: "folder",
                        handler: { presentBatch(.add) }
                    ),
                    secondary: [
                        MultiSelectAction(
                            id: "move",
                            title: MultiSelectActionLabel.moveToFolder(count: selection.count, itemSingular: "episode"),
                            systemImage: "folder",
                            handler: { presentBatch(.move) }
                        ),
                        MultiSelectAction(
                            id: "queue",
                            title: EpisodeBatchLabel.addToQueue(count: selection.count),
                            systemImage: "text.badge.plus",
                            handler: { addSelectedToQueue() }
                        ),
                    ],
                    announcementNoun: "episode"
                )
                .transition(.move(edge: .bottom))
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // Bulk "Mark all as played" (#640) for shows with hundreds or
                // thousands of episodes, where scrolling to mark each one is
                // impractical. Disabled — not hidden — when there's nothing
                // unplayed, mirroring InboxScreen's "Add to Queue" pattern, so
                // VoiceOver users can still find it and learn why it's
                // inactive rather than have it vanish unexplained.
                Button {
                    requestMarkAllPlayed()
                } label: {
                    Label("Mark all as played", systemImage: "checklist.checked")
                }
                .disabled(unplayedCount == 0)
                .accessibilityLabel("Mark all as played")
                .accessibilityHint(
                    unplayedCount == 0
                        ? "No unplayed episodes"
                        : "Marks all \(unplayedCount) unplayed episodes in \(podcast.displayName) as played"
                )
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingPodcastSettings = true
                } label: {
                    Label("Podcast settings", systemImage: "gearshape")
                }
                .accessibilityLabel("Podcast settings")
                .accessibilityHint("Opens settings for this podcast")
            }
            // Enter/leave episode multi-select (#758). "Select" is the entry point
            // (a real Button, so it's reachable by VoiceOver swipe and rotor);
            // while selecting it becomes "Done", which exits and announces the
            // change. Only offered when there are episodes to select. The batch
            // actions live in the bottom MultiSelectBar.
            if !visibleEpisodes.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    if selection.isSelecting {
                        Button("Done") { exitSelection(announce: true) }
                            .accessibilityHint("Leaves selection mode")
                            .accessibilityFocused($focusSelectButton)
                    } else {
                        Button {
                            enterSelection(first: visibleEpisodes.first)
                        } label: {
                            Label("Select episodes", systemImage: "checkmark.circle")
                        }
                        .accessibilityFocused($focusSelectButton)
                    }
                }
            }
        }
        .sheet(isPresented: $showingPodcastSettings) {
            PodcastSettingsView(podcast: podcast)
        }
        .sheet(item: $showNotesEpisode) { ShowNotesView(episode: $0) }
        .sheet(item: $bookmarksEpisode) { BookmarksListView(episode: $0) }
        .sheet(item: $sharingEpisode) { episode in
            ShareSheet(items: shareItems(for: episode))
        }
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
        // Podcast-level destructive confirmation for the row's "Unfollow this
        // podcast" Quick Action (#572). Wording copied from InboxScreen so the
        // flow reads identically everywhere it appears.
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
            Text("This removes \(podcast.displayName) and its episodes from your library. This can't be undone.")
        }
        // Confirmation for the bulk "Mark all as played" action (#640),
        // reached from either the toolbar button or the rotor action above.
        // Destructive role + plain-text buttons (no icon) match the
        // Clear-inbox / Unfollow confirmationDialog precedent in this app —
        // unlike a `Menu` or custom bottom sheet, the system confirmation
        // dialog doesn't render button icons.
        .confirmationDialog(
            markAllPlayedConfirmationTitle,
            isPresented: $confirmingMarkAllPlayed,
            titleVisibility: .visible
        ) {
            Button("Mark All as Played", role: .destructive) { markAllPlayed() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(markAllPlayedConfirmationMessage)
        }
    }

    /// Whichever row variant applies: a selectable checkmark row while in
    /// selection mode (#758, via the shared ``SelectableRow`` scaffold),
    /// otherwise the normal navigate/rotor row with its full Quick Actions.
    @ViewBuilder
    private func rowContainer(for episode: Episode) -> some View {
        if selection.isSelecting {
            EpisodeSelectableRow(
                episode: episode,
                isSelected: selection.isSelected(episode.persistentModelID),
                onToggle: { selection.toggle(episode.persistentModelID) }
            )
        } else {
            EpisodeRow(
                episode: episode,
                deferredActions: availableEpisodeActions(
                    episode: episode,
                    order: quickActions.episodeActions,
                    supportsUnfollow: true,
                    supportsExport: true,
                    supportsTranscriptExport: true,
                    supportsAddToFolder: true,
                    supportsMoveToFolder: true
                ),
                performAction: { action in perform(action, for: episode) }
            )
        }
    }

    /// Resolves a runnable item only after activation. A single show can contain
    /// many thousands of episodes, so row recycling must not construct the full
    /// UUID/closure action set for every visible row.
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
            // Rotor "Unfollow this podcast" (#572): opens the destructive
            // confirmation — activation never unfollows directly.
            onUnfollow: { pendingUnfollow = podcast },
            // Under the Unheard filter, rotor "Mark as played" removes this row
            // (#579). Capture the visible neighbor before the state changes.
            onMarkPlayed: { nowPlayed in
                guard filter == .unheard, nowPlayed else { return }
                let neighbor = neighborID(of: episode, in: visibleEpisodes)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if let neighbor {
                        focusedEpisode = neighbor
                    } else {
                        focusEmptyFilter = true
                    }
                }
            },
            onExport: { exportEpisode = episode },
            onExportTranscript: { exportTranscriptEpisode = episode },
            onAddToFolder: { folderPickRequest = .episode($0, mode: .add) },
            onMoveToFolder: { folderPickRequest = .episode($0, mode: .move) }
        ).first?.run()
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
    /// announced their result. Re-anchors VoiceOver focus to the Select/Done
    /// button — a stable element that's always present while there are episodes,
    /// never a row that a batch may have removed. `focusDelay` lets a folder batch
    /// push the focus move past the picker's own +0.5s result announcement.
    private func exitSelection(announce: Bool, focusDelay: TimeInterval = 0.5) {
        withAnimation(Motion.preferred(.easeInOut(duration: 0.2))) {
            selection.exit()
        }
        if announce {
            Announcer.announce("Selection mode off")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + focusDelay) {
            focusSelectButton = true
        }
    }

    /// Presents the shared picker for the whole selection. No-op with an empty
    /// selection (the bar's buttons are already disabled there).
    private func presentBatch(_ mode: FolderPickMode) {
        let selected = selectedEpisodes()
        guard !selected.isEmpty else { return }
        batchRequest = .episodes(selected, mode: mode)
    }

    /// Called by the batch folder picker once it has applied the add/move. Filing
    /// into a folder doesn't remove episodes from this list, so we leave selection
    /// mode silently (the picker announced the result) and re-anchor focus,
    /// staggered past the picker's +0.5s result announcement.
    private func finishBatch() {
        exitSelection(announce: false, focusDelay: 0.9)
    }

    /// The selected episodes, in the current filtered, sorted, searched display order.
    private func selectedEpisodes() -> [Episode] {
        visibleEpisodes.filter { selection.isSelected($0.persistentModelID) }
    }

    /// Adds every selected episode to the end of the queue, in list order, then
    /// exits selection mode. Reuses the same ``QueueRepository/add(_:)`` batch the
    /// Inbox bulk-add uses.
    private func addSelectedToQueue() {
        let toAdd = selectedEpisodes()
        guard !toAdd.isEmpty else { return }
        QueueRepository(context: context).add(toAdd)
        // Noun-carrying result ("Added 3 episodes to queue"), matching the folder
        // batch announcement's phrasing.
        Announcer.announce("Added \(EpisodeBatchLabel.episodePhrase(toAdd.count)) to queue", assertive: true)
        exitSelection(announce: false)
    }

    /// Unfollows the shown podcast via the centralized repository path shared
    /// with Library, search, and the inbox (#499/#500) — never an inline delete.
    /// The repo logs failures and returns whether the delete saved, so we
    /// announce and pop only on `true`; this screen's subject no longer exists,
    /// so it dismisses back to the list it was pushed from.
    private func unfollow(_ podcast: Podcast) {
        let title = podcast.displayName
        let removed = SubscriptionRepository(context: context).unsubscribe(podcast)
        pendingUnfollow = nil
        guard removed else { return }
        Announcer.announce("Unfollowed \(title)")
        dismiss()
    }

    /// Shared entry point for both the toolbar button and the rotor action
    /// (#640) — both just open the same confirmation, never mark directly.
    private func requestMarkAllPlayed() {
        confirmingMarkAllPlayed = true
    }

    /// Title for the "Mark all as played" confirmation, e.g. "Mark all 1,204
    /// episodes as played?" / "Mark all 1 episode as played?".
    private var markAllPlayedConfirmationTitle: String {
        MarkAllPlayedConfirmationCopy.title(unplayedCount: unplayedCount)
    }

    /// Body copy for the "Mark all as played" confirmation, naming the show
    /// and stating the action can't be undone.
    private var markAllPlayedConfirmationMessage: String {
        MarkAllPlayedConfirmationCopy.message(unplayedCount: unplayedCount, podcastTitle: podcast.displayName)
    }

    /// Runs the batched repository call (#640) and announces the result.
    /// Assertive so it interrupts current speech the way
    /// InboxScreen.addSelectedToQueue's completion announcement does — the
    /// user just confirmed a deliberate bulk action and needs to hear it
    /// landed.
    private func markAllPlayed() {
        Task { @MainActor in
            isBulkEpisodeMutation = true
            let count = await EpisodeRepository(context: context).markAllPlayed(in: podcast)
            isBulkEpisodeMutation = false
            reloadEpisodePage()
            Announcer.announce(MarkAllPlayedAnnouncement.text(count: count), assertive: true)
        }
    }

    /// A reversible chronological sort control. Sorting changes only the list's
    /// presentation; it never starts playback or mutates the queue.
    private var chronologicalSortButton: some View {
        let target = settings.episodeSortOrder.chronologicalToggleTarget
        return Button {
            settings.episodeSortOrder = target
            resetEpisodePage(moveFocusToResults: true)
            Announcer.announce(target.announcement)
        } label: {
            Label(settings.episodeSortOrder.chronologicalToggleTitle, systemImage: "arrow.up.arrow.down")
        }
        .accessibilityHint("Changes the episode order without starting playback")
    }

    private var header: some View {
        VStack(alignment: .center, spacing: Spacing.sm) {
            PodcastArtwork(urlString: podcast.artworkURL, size: 120, cornerRadius: 12)
            Text(podcast.displayName)
                .font(.headline)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                // Screen-level VoiceOver rotor equivalent of the toolbar button
                // (#640) — this is a whole-podcast bulk action, not a per-row
                // one, so there's no natural row to hang it off of. Attached
                // here (the header title Text), not to the enclosing `List`:
                // every other `.accessibilityAction(named:)` in this codebase
                // (NowPlayingScreen transport buttons, ChapterListView rows,
                // SearchView result rows) hangs off a real accessible leaf
                // element. A `List` doesn't collapse into one — VoiceOver
                // lands on its rows/sections, never on the List itself — so an
                // action attached to the List directly is unreachable from the
                // rotor. The title is the first element on this screen in every
                // state (including the empty-list and loading states), so it's
                // always reachable when there's something to mark. Only
                // attached when there's something to mark, since a rotor
                // action can't visually gray itself out the way the toolbar
                // button can.
                .markAllPlayedAccessibilityAction(enabled: unplayedCount > 0) {
                    requestMarkAllPlayed()
                }
            if let author = podcast.author, !author.isEmpty {
                Text(author)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            let cleanedDescription = EpisodeSummary.plainText(podcast.podcastDescription)
            if !cleanedDescription.isEmpty {
                Text(cleanedDescription)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .padding(.top, Spacing.xs)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.sm)
    }

    /// Shown when every episode is played and the filter is set to Unheard.
    /// Offers a one-tap switch to All rather than leaving a blank list.
    private var emptyFilterState: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("No unheard episodes")
                .font(.headline)
                // Focus lands here when the rotor mark-played removes the last
                // unheard row (#579), so VoiceOver isn't orphaned on a vanished
                // element. The heading, not the container: focusing the VStack
                // would make VoiceOver group-summarize all three children.
                .accessibilityFocused($focusEmptyFilter)
            Text("You've played everything here. Switch to All to see every episode.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Show all episodes") {
                filterSelection.wrappedValue = .all
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Spacing.xs)
    }

    private func refresh() async {
        do {
            let outcome = try await SubscriptionRepository(
                context: context,
                downloader: downloads,
                queue: QueueRepository(context: context),
                isEntitled: entitlements.isEntitled
            ).refresh(podcast, reconcileEpisodeModels: false)
            resetEpisodePage(moveFocusToResults: false)
            RefreshCompletionHaptics.playIfNeeded(
                trigger: .manualPullToRefresh,
                succeeded: true,
                enabled: settings.hapticFeedbackEnabled
            )
            if outcome.rejectedAllNewCandidates {
                Announcer.announce(
                    "\(podcast.displayName) refreshed. Episode filters excluded all new episodes. Review this podcast's filters."
                )
            } else {
                Announcer.announce("\(podcast.displayName) refreshed")
            }
        } catch {
            AppLog.subscriptions.error("Refresh failed: \(error.localizedDescription, privacy: .public)")
            Announcer.announce("Couldn't refresh \(podcast.displayName)")
        }
    }

    @ViewBuilder
    private var olderEpisodesControl: some View {
        switch olderEpisodesState {
        case .loading:
            LabeledContent("Older episodes", value: "Loading")
                .accessibilityAddTraits(.updatesFrequently)
        case .end:
            LabeledContent("Older episodes", value: "All available episodes loaded")
        case .failed:
            Button("Retry loading older episodes") {
                Task { await loadOlderEpisodes() }
            }
            .accessibilityHint("Loads the next 10 older episodes from this podcast")
        case .ready:
            Button("Load 10 older episodes") {
                Task { await loadOlderEpisodes() }
            }
            .accessibilityHint("Adds older episodes without placing them in Inbox")
        }
    }

    private func loadOlderEpisodes() async {
        guard olderEpisodesState != .loading else { return }
        olderEpisodesState = .loading
        do {
            let outcome = try await SubscriptionRepository(
                context: context,
                downloader: downloads,
                isEntitled: entitlements.isEntitled
            ).loadOlderEpisodes(for: podcast, reconcileEpisodeModels: false)
            olderEpisodesState = outcome.hasMore ? .ready : .end
            if outcome.inserted > 0 {
                resetEpisodePage(moveFocusToResults: false)
                Announcer.announce("Loaded \(outcome.inserted) older episodes")
            } else {
                Announcer.announce("All available episodes loaded")
            }
        } catch is CancellationError {
            olderEpisodesState = .ready
        } catch {
            olderEpisodesState = .failed
            AppLog.subscriptions.error(
                "Loading older episodes failed: \(error.localizedDescription, privacy: .public)"
            )
            Announcer.announce("Couldn't load older episodes")
        }
    }

    private func shareItems(for episode: Episode) -> [Any] {
        if let url = URL(string: episode.audioURL) {
            return [episode.title, url]
        }
        return [episode.title]
    }

    private var showMoreEpisodesLabel: String {
        "Show 100 more episodes, \(visibleEpisodes.count.formatted()) loaded of \(matchingCount.formatted())"
    }

    @discardableResult
    private func ensureEpisodeList() -> EpisodeListDataSource {
        if let episodeList {
            episodeList.podcastTitle = "\(podcast.title) \(podcast.displayName)"
            return episodeList
        }
        let source = EpisodeListDataSource(
            context: context,
            podcastID: podcast.persistentModelID,
            podcastTitle: "\(podcast.title) \(podcast.displayName)"
        )
        episodeList = source
        return source
    }

    private func resetEpisodePage(moveFocusToResults: Bool) {
        guard !podcast.isDeleted else { return }
        ensureEpisodeList().resetAndLoad(
            filter: filter,
            sort: settings.episodeSortOrder,
            searchText: searchText
        )
        if moveFocusToResults, matchingCount > 0 {
            DispatchQueue.main.async { focusResultsHeading = true }
        }
    }

    private func reloadEpisodePage() {
        guard !podcast.isDeleted, let episodeList else { return }
        episodeList.podcastTitle = "\(podcast.title) \(podcast.displayName)"
        episodeList.reloadKeepingLoadedLimit(
            filter: filter,
            sort: settings.episodeSortOrder,
            searchText: searchText
        )
    }

    /// Keeps store search work off the keystroke path and prevents a superseded
    /// query from publishing late results. Submit bypasses the delay above.
    private func scheduleSearchReload() {
        searchReloadTask?.cancel()
        searchReloadTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            resetEpisodePage(moveFocusToResults: false)
        }
    }
}

private enum OlderEpisodesState: Equatable {
    case ready
    case loading
    case end
    case failed
}

/// Pure VoiceOver completion wording for "Mark all as played" (#640).
/// Comma-grouped (`1,204`, not `1204`) so large counts read correctly, and
/// singular/plural correct for `count == 1`. Kept as a standalone pure
/// function (not inline in the view) so it's unit-testable without a model
/// context, mirroring `EpisodeListFilter.announcement(count:)`.
enum MarkAllPlayedAnnouncement {
    static func text(count: Int) -> String {
        let noun = count == 1 ? "episode" : "episodes"
        return "Marked \(count.formatted()) \(noun) as played"
    }
}

/// Pure "Mark all as played" confirmation dialog copy (#640). Extracted
/// alongside ``MarkAllPlayedAnnouncement`` so the singular/plural,
/// comma-grouping, and podcast-title interpolation are unit-testable without
/// standing up the view.
enum MarkAllPlayedConfirmationCopy {
    static func title(unplayedCount: Int) -> String {
        let noun = unplayedCount == 1 ? "episode" : "episodes"
        return "Mark all \(unplayedCount.formatted()) \(noun) as played?"
    }

    static func message(unplayedCount: Int, podcastTitle: String) -> String {
        let noun = unplayedCount == 1 ? "episode" : "episodes"
        return "This marks all \(unplayedCount.formatted()) unplayed \(noun) in \(podcastTitle) as played. This can't be undone."
    }
}

private extension View {
    /// Conditionally attaches the "Mark all as played" rotor action (#640).
    /// A rotor action has no way to visually gray itself out the way a
    /// toolbar button can via `.disabled`, so when there's nothing to mark
    /// the action is omitted from the accessibility tree entirely rather than
    /// left attached as a silent no-op.
    @ViewBuilder
    func markAllPlayedAccessibilityAction(enabled: Bool, action: @escaping () -> Void) -> some View {
        if enabled {
            self.accessibilityAction(named: "Mark all as played", action)
        } else {
            self
        }
    }
}
