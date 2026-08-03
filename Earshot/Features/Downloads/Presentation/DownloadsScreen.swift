import SwiftUI
import SwiftData

/// The store-level bound for the Downloads tab's live episode query.
///
/// `DownloadStatus` is a Codable enum that SwiftData cannot use in a predicate.
/// `downloadPath`, however, is a queryable stored String and is present for every
/// valid completed download. The presentation layer still checks `.downloaded`
/// after this bound so an in-progress row that has written a destination path
/// cannot appear prematurely. (#701)
enum DownloadListQuery {
    static var hasPath: Predicate<Episode> {
        #Predicate<Episode> { $0.downloadPath != nil }
    }
}

/// Downloads: everything downloaded, plus Recently Expired (episodes auto-removed
/// from the queue, restorable for 7 days before their files are deleted).
struct DownloadsScreen: View {
    @Environment(\.modelContext) private var context
    @Environment(PlayerService.self) private var player
    @Environment(DownloadManager.self) private var downloads
    @Environment(QuickActionStore.self) private var quickActions

    // A TabView creates this screen even when Downloads is not selected, so an
    // unfiltered @Query here is launch-path work. On the 242k-episode library it
    // eagerly materialized the entire Episode table and held roughly 670 MB just
    // to find ~200 downloads. A valid completed download has a path; this stored
    // String is queryable even though the Codable `downloadStatus` enum is not.
    // Keep the status check below as the final invariant guard. (#701)
    @Query(filter: DownloadListQuery.hasPath,
           sort: \Episode.pubDate, order: .reverse)
    private var downloadCandidates: [Episode]
    @Query private var expiredRows: [RecentlyExpired]
    @Query(sort: [SortDescriptor(\PodcastFolder.sortOrder), SortDescriptor(\PodcastFolder.name)])
    private var folders: [PodcastFolder]

    @State private var showNotesEpisode: Episode?
    @State private var sharingEpisode: Episode?
    // The episode a pending "Export audio" Quick Action targets (#689). Setting
    // it drives the shared `.episodeAudioExport` flow (download-then-share).
    @State private var exportEpisode: Episode?
    @State private var bookmarksEpisode: Episode?
    // The pending "Add to folder" / "Move to folder" Quick Action target (#756).
    @State private var folderPickRequest: FolderPickRequest?
    // The podcast a pending "Unfollow this podcast" rotor Quick Action targets
    // (#572). Non-nil drives the destructive confirmation dialog below —
    // activation never unfollows directly. Same pattern and wording as
    // InboxScreen / SubscriptionsView.
    @State private var pendingUnfollow: Podcast?
    // The in-place `.searchable` filter (#457, Part A). Pure presentation: the
    // downloaded set and the expiration records are filtered in memory only.
    @State private var searchText = ""
    // Drives the "Clear all downloads" destructive confirmation from the toolbar.
    @State private var showClearAllConfirm = false
    // Global played/unheard filter for the Downloads list (#641). Loaded on
    // appear (default ``EpisodeListFilter/all`` — show everything) and persisted
    // globally on change. Applies only to the Downloaded section; Recently
    // Expired is unaffected. Reuses the validated ``EpisodeListFilter`` type.
    @State private var playedFilter: EpisodeListFilter = SettingsDefault.downloadsPlayedFilter
    // Session-local folder scope, matching Inbox: nil means All folders and a
    // selected folder includes podcasts filed anywhere in its subtree.
    @State private var selectedFolderID: PersistentIdentifier?
    // Focus targets for the rotor "Mark as played" under the Unheard filter,
    // where the marked download leaves the visible list (#641, mirroring the
    // #579 fix on EpisodeListView): the neighbor row, or the empty-filter state
    // when the last unheard download was just marked.
    @AccessibilityFocusState private var focusedEpisode: PersistentIdentifier?
    @AccessibilityFocusState private var focusEmptyFilter: Bool

    private var downloaded: [Episode] {
        downloadCandidates
            .filter { $0.downloadStatus == .downloaded }
    }

    private var orderedFolders: [PodcastFolder] {
        FolderLogic.orderedHierarchy(from: folders)
    }

    private var selectedFolder: PodcastFolder? {
        guard let selectedFolderID else { return nil }
        return folders.first { $0.persistentModelID == selectedFolderID }
    }

    private var selectedFolderName: String {
        selectedFolder.map { FolderLogic.pathString($0) } ?? "All folders"
    }

    private var selectedPodcastIDs: Set<PersistentIdentifier>? {
        guard let selectedFolder else { return nil }
        return Set(
            FolderRepository(context: context)
                .subtreeSubscriptions(of: selectedFolder)
                .map(\.persistentModelID)
        )
    }

    /// Binding that drives the segmented filter: persists the new value globally
    /// and announces how many played downloads it hides or reveals (#641).
    private func filterSelection(playedCount: Int) -> Binding<EpisodeListFilter> {
        Binding(
            get: { playedFilter },
            set: { newValue in
                guard newValue != playedFilter else { return }
                playedFilter = newValue
                AppSettingsStore(context: context).setDownloadsPlayedFilter(newValue)
                Announcer.announce(DownloadsFilterAnnouncement.text(filter: newValue, playedCount: playedCount))
            }
        )
    }

    private var expiredEntries: [RecentlyExpired] {
        ExpirationService(context: context).recentlyExpired()
    }

    var body: some View {
        // Compute each bounded source once, then compose folder scope, the
        // Downloaded-only played filter, and search in one tested pass. Recently
        // Expired follows folder scope and search but never the played filter.
        let rawDownloaded = downloaded
        let rawExpired = expiredEntries
        let searchActive = EpisodeSearchFilter.isActive(searchText)
        let result = DownloadsListFilter.apply(
            downloaded: rawDownloaded,
            expired: rawExpired,
            podcastIDs: selectedPodcastIDs,
            playedFilter: playedFilter,
            searchText: searchText
        )
        let visibleCount = result.visibleDownloaded.count + result.visibleExpired.count
        return VStack(spacing: 0) {
            if !folders.isEmpty {
                folderFilter(rawDownloaded: rawDownloaded, rawExpired: rawExpired)
            }
            Group {
                if rawDownloaded.isEmpty && rawExpired.isEmpty {
                    ContentUnavailableView(
                        "No downloads",
                        systemImage: "arrow.down.circle",
                        description: Text("Episodes you download appear here.")
                    )
                } else if searchActive && visibleCount == 0 {
                    // Search is last in the composition, so this state can mean
                    // no match within the selected folder and All/Unheard scope.
                    NoSearchMatchesView(query: searchText)
                } else if result.scopedDownloaded.isEmpty && result.scopedExpired.isEmpty {
                    ContentUnavailableView(
                        "No downloads in \(selectedFolderName)",
                        systemImage: "folder",
                        description: Text(
                            "Downloaded and recently expired episodes from this folder and its subfolders appear here."
                        )
                    )
                } else {
                    List {
                        // Played/unheard filter (#641). Only shown when there are
                        // downloads to filter; it never touches Recently Expired.
                        if !result.scopedDownloaded.isEmpty {
                            Section {
                                Picker(
                                    "Filter downloads",
                                    selection: filterSelection(playedCount: result.playedCount)
                                ) {
                                    ForEach(EpisodeListFilter.allCases) { option in
                                        Text(option.title).tag(option)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .accessibilityLabel("Filter downloads")
                            }
                        }
                        if !result.visibleDownloaded.isEmpty {
                            Section(header: Text("Downloaded").accessibilityAddTraits(.isHeader)) {
                                ForEach(result.visibleDownloaded) { episode in
                                    EpisodeRow(
                                        episode: episode,
                                        deferredActions: availableActions(for: episode),
                                        includesPodcastName: true,
                                        performAction: { action in
                                            perform(action, for: episode, in: result.visibleDownloaded)
                                        }
                                    )
                                        // Lets the rotor mark-played runner hand
                                        // VoiceOver focus to this row when its neighbor
                                        // vanishes under the Unheard filter (#641).
                                        .accessibilityFocused(
                                            $focusedEpisode,
                                            equals: episode.persistentModelID
                                        )
                                }
                            }
                        } else if !result.scopedDownloaded.isEmpty && !searchActive {
                            // The played filter hid every download (all played). Show
                            // a message and a one-tap way back, not a blank list (#641).
                            Section {
                                emptyPlayedFilterState(playedCount: result.playedCount)
                            }
                        }
                        if !result.visibleExpired.isEmpty {
                            Section(header: Text("Recently Expired").accessibilityAddTraits(.isHeader)) {
                                ForEach(result.visibleExpired) { entry in
                                    if let episode = entry.episode {
                                        expiredRow(episode, expiredAt: entry.expiredAt)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Downloads")
        .navigationBarTitleDisplayMode(.inline)
        // In-place search filter (#457, Part A). Standard accessible
        // `.searchable` field; the match count is announced on SUBMIT only —
        // never per keystroke, never while the field is empty — while the list
        // narrows live as the user types. The count spans both sections.
        .searchable(text: $searchText, prompt: "Search downloads")
        .onSubmit(of: .search) {
            announceMatches(count: visibleCount)
        }
        // Load the persisted global played filter on appear (#641). Mirrors the
        // per-podcast episode-list filter load; the default is All (show every
        // download) until the user opts into hiding played.
        .task {
            playedFilter = AppSettingsStore(context: context).downloadsPlayedFilter()
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Downloads")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
            }
            // Quick one-tap way to reclaim storage. Disabled (not hidden) when
            // there's nothing downloaded, so its position stays stable for
            // VoiceOver users. Never clears directly — routes through the
            // destructive confirmation below.
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showClearAllConfirm = true
                } label: {
                    Label("Clear all downloads", systemImage: "trash")
                }
                .disabled(downloaded.isEmpty)
                .accessibilityLabel("Clear all downloads")
                .accessibilityHint("Removes every downloaded episode from this device")
            }
        }
        .sheet(item: $showNotesEpisode) { ShowNotesView(episode: $0) }
        .sheet(item: $bookmarksEpisode) { BookmarksListView(episode: $0) }
        .sheet(item: $sharingEpisode) { ShareSheet(items: shareItems(for: $0)) }
        .folderPicker($folderPickRequest)
        .episodeAudioExport($exportEpisode)
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
            Text("This removes \(podcast.title) and its episodes from your library. This can't be undone.")
        }
        // Destructive "Clear all downloads" confirmation (toolbar trash button).
        // Same shape as the unfollow dialog above so the flow reads identically.
        .confirmationDialog(
            "Clear all downloads?",
            isPresented: $showClearAllConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear all downloads", role: .destructive) { clearAllDownloads() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes ^[\(downloaded.count) downloaded episode](inflect: true) from this device. This can't be undone.")
        }
    }

    /// Always-visible folder scope control, matching the Inbox vocabulary and
    /// hierarchy order. Keeping it above every empty state lets VoiceOver users
    /// escape a folder with no downloads. Native menu Picker semantics provide
    /// a predictable control and the explicit frame preserves a 44-point target.
    private func folderFilter(
        rawDownloaded: [Episode],
        rawExpired: [RecentlyExpired]
    ) -> some View {
        Picker(
            selection: folderSelection(
                rawDownloaded: rawDownloaded,
                rawExpired: rawExpired
            )
        ) {
            Text("All folders").tag(nil as PersistentIdentifier?)
            ForEach(orderedFolders) { folder in
                Text(FolderLogic.pathString(folder))
                    .tag(folder.persistentModelID as PersistentIdentifier?)
            }
        } label: {
            Label(
                "Downloads: \(selectedFolderName)",
                systemImage: "line.3.horizontal.decrease.circle"
            )
        }
        .pickerStyle(.menu)
        .frame(maxWidth: .infinity, minHeight: Spacing.minTouchTarget, alignment: .leading)
        .padding(.horizontal, Spacing.md)
        .accessibilityLabel("Downloads folder filter, \(selectedFolderName)")
        .accessibilityHint("Choose a folder to show episodes from its podcasts, including subfolders")
        .onChange(of: folders.map(\.persistentModelID)) { _, availableIDs in
            guard let selectedFolderID,
                  !availableIDs.contains(selectedFolderID) else { return }
            self.selectedFolderID = nil
        }
    }

    private func folderSelection(
        rawDownloaded: [Episode],
        rawExpired: [RecentlyExpired]
    ) -> Binding<PersistentIdentifier?> {
        Binding(
            get: { selectedFolderID },
            set: { newID in
                guard newID != selectedFolderID else { return }
                selectedFolderID = newID
                searchText = ""
                let folder = newID.flatMap { id in
                    folders.first { $0.persistentModelID == id }
                }
                let podcastIDs = folder.map { selected in
                    Set(
                        FolderRepository(context: context)
                            .subtreeSubscriptions(of: selected)
                            .map(\.persistentModelID)
                    )
                }
                let filtered = DownloadsListFilter.apply(
                    downloaded: rawDownloaded,
                    expired: rawExpired,
                    podcastIDs: podcastIDs,
                    playedFilter: playedFilter,
                    searchText: ""
                )
                Announcer.announce(
                    DownloadsFilterAnnouncement.folderText(
                        name: folder.map { FolderLogic.pathString($0) } ?? "All folders",
                        visibleCount: filtered.visibleDownloaded.count + filtered.visibleExpired.count
                    )
                )
            }
        )
    }

    /// Removes every downloaded file and resets download state in one pass. The
    /// `downloadPath != nil` @Query drops the cleared rows automatically, so the
    /// list empties without any manual refresh. Announces the outcome for
    /// VoiceOver (Announcer is a no-op when VoiceOver is off).
    private func clearAllDownloads() {
        Task {
            let removed = await downloads.clearAllDownloads()
            Announcer.announce(removed == 1 ? "Cleared 1 download" : "Cleared \(removed) downloads")
        }
    }

    /// Shown when the played filter hides every download (all played) and no
    /// search is active, so the list isn't blank (#641). The button switches back
    /// to All, which also announces the change via ``filterSelection``.
    private func emptyPlayedFilterState(playedCount: Int) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("All downloads played")
                .font(.headline)
                // Focus lands here when the rotor mark-played removes the last
                // unheard download (#641). The heading, not the container:
                // focusing the VStack would make VoiceOver group-summarize all
                // three children. Mirrors EpisodeListView.emptyFilterState.
                .accessibilityFocused($focusEmptyFilter)
            Text("^[\(playedCount) played episode](inflect: true) hidden. Switch to All to see them.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Show all downloads") {
                filterSelection(playedCount: playedCount).wrappedValue = .all
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Spacing.xs)
    }

    private func expiredRow(_ episode: Episode, expiredAt: Date) -> some View {
        let days = daysLeft(expiredAt: expiredAt)
        return HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(episode.title).font(.body)
                if let podcast = episode.podcast?.title {
                    Text(podcast).font(.caption).foregroundStyle(.secondary)
                }
                Text(days <= 0 ? "Expiring soon" : "^[\(days) day](inflect: true) left to restore")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Restore") { restore(episode) }
                .buttonStyle(.bordered)
                .controlSize(.large)
                // The action is exposed via the rotor below; hide the visible
                // button so the combined row doesn't add a duplicate VO stop.
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            [episode.title, episode.podcast?.title].compactMap { $0 }.joined(separator: ", ")
        )
        .accessibilityValue(days <= 0 ? "Recently expired, expiring soon" : "Recently expired, \(days) \(days == 1 ? "day" : "days") left to restore")
        .accessibilityHint("Restorable for a limited time")
        .rotorActions([
            QuickActionItem(id: "restoreToQueue", label: "Restore to queue", isDestructive: false) {
                restore(episode)
            },
        ])
    }

    /// Whole days remaining in the 7-day restore window.
    private func daysLeft(expiredAt: Date, now: Date = .now) -> Int {
        let elapsed = now.timeIntervalSince(expiredAt) / 86_400
        return max(0, ExpirationLogic.recentlyExpiredRetentionDays - Int(elapsed))
    }

    private func restore(_ episode: Episode) {
        ExpirationService(context: context).restore(episode)
        Announcer.announce("Restored \(episode.title) to the queue")
    }

    private func availableActions(for episode: Episode) -> [EpisodeAction] {
        availableEpisodeActions(
            episode: episode,
            order: quickActions.episodeActions,
            supportsUnfollow: true,
            supportsExport: true,
            supportsAddToFolder: true,
            supportsMoveToFolder: true
        )
    }

    /// Builds only the action that was activated, keeping UUIDs and captured
    /// closures out of the downloaded-row scrolling path.
    private func perform(_ action: EpisodeAction, for episode: Episode, in visible: [Episode]) {
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
            // confirmation above — activation never unfollows directly.
            onUnfollow: { pendingUnfollow = episode.podcast },
            // Under the Unheard filter, rotor "Mark as played" removes this row
            // from the Downloaded list (#641). The builder invokes this BEFORE
            // the played flip, so the neighbor is captured while the row is still
            // visible; focus moves after the list re-renders — to the neighbor,
            // or the empty-filter state when this was the last unheard download.
            // Under All the row stays put, so no focus management is needed.
            // Mirrors EpisodeListView's #579 wiring.
            onMarkPlayed: { nowPlayed in
                guard playedFilter == .unheard, nowPlayed else { return }
                let neighbor = neighborID(of: episode, in: visible)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if let neighbor {
                        focusedEpisode = neighbor
                    } else {
                        focusEmptyFilter = true
                    }
                }
            },
            // Rotor "Export audio" (#689): shares the local file (already
            // downloaded on this screen). Handled by `.episodeAudioExport`.
            onExport: { exportEpisode = episode },
            // Rotor "Add to folder" / "Move to folder" (#756): presents the
            // shared `FolderPickerView` for this single episode.
            onAddToFolder: { folderPickRequest = .episode($0, mode: .add) },
            onMoveToFolder: { folderPickRequest = .episode($0, mode: .move) }
        ).first?.run()
    }

    /// Unfollows `podcast` via the centralized repository path shared with
    /// Library, search, and the inbox (#499/#500) — never an inline delete. The
    /// repo logs failures and returns whether the delete saved, so we announce
    /// success only on `true`. The show's downloaded episodes drop out of the
    /// @Query-backed list automatically.
    private func unfollow(_ podcast: Podcast) {
        let title = podcast.title
        let removed = SubscriptionRepository(context: context).unsubscribe(podcast)
        pendingUnfollow = nil
        guard removed else { return }
        Announcer.announce("Unfollowed \(title)")
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
