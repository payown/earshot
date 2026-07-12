import SwiftUI
import SwiftData

/// Downloads: everything downloaded, plus Recently Expired (episodes auto-removed
/// from the queue, restorable for 7 days before their files are deleted).
struct DownloadsScreen: View {
    @Environment(\.modelContext) private var context
    @Environment(PlayerService.self) private var player
    @Environment(DownloadManager.self) private var downloads
    @Environment(QuickActionStore.self) private var quickActions

    @Query private var allEpisodes: [Episode]
    @Query private var expiredRows: [RecentlyExpired]

    @State private var showNotesEpisode: Episode?
    @State private var sharingEpisode: Episode?
    // The episode a pending "Export audio" Quick Action targets (#689). Setting
    // it drives the shared `.episodeAudioExport` flow (download-then-share).
    @State private var exportEpisode: Episode?
    @State private var bookmarksEpisode: Episode?
    // The podcast a pending "Unfollow this podcast" rotor Quick Action targets
    // (#572). Non-nil drives the destructive confirmation dialog below —
    // activation never unfollows directly. Same pattern and wording as
    // InboxScreen / SubscriptionsView.
    @State private var pendingUnfollow: Podcast?
    // The in-place `.searchable` filter (#457, Part A). Pure presentation: the
    // downloaded set and the expiration records are filtered in memory only.
    @State private var searchText = ""
    // Global played/unheard filter for the Downloads list (#641). Loaded on
    // appear (default ``EpisodeListFilter/all`` — show everything) and persisted
    // globally on change. Applies only to the Downloaded section; Recently
    // Expired is unaffected. Reuses the validated ``EpisodeListFilter`` type.
    @State private var playedFilter: EpisodeListFilter = SettingsDefault.downloadsPlayedFilter
    // Focus targets for the rotor "Mark as played" under the Unheard filter,
    // where the marked download leaves the visible list (#641, mirroring the
    // #579 fix on EpisodeListView): the neighbor row, or the empty-filter state
    // when the last unheard download was just marked.
    @AccessibilityFocusState private var focusedEpisode: PersistentIdentifier?
    @AccessibilityFocusState private var focusEmptyFilter: Bool

    private var downloaded: [Episode] {
        allEpisodes
            .filter { $0.downloadStatus == .downloaded }
            .sorted { ($0.pubDate ?? .distantPast) > ($1.pubDate ?? .distantPast) }
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
        // Compute each source once per body, then narrow both by the search
        // (#457). The Recently Expired section is searched too — an expired
        // episode matches on the same fields as a downloaded one — so a search
        // never silently hides a restorable episode the user is looking for.
        // With no search active the filters pass everything through unchanged.
        let allDownloaded = downloaded
        let allExpired = expiredEntries
        let searchActive = EpisodeSearchFilter.isActive(searchText)
        // Played count over the UNFILTERED downloads — what the played filter
        // hides — for the toggle announcement and empty-state message (#641).
        let playedCount = allDownloaded.filter(\.isPlayed).count
        // Played filter first (#641), then the in-place search (#457).
        let playedFilteredDownloaded = playedFilter.apply(to: allDownloaded)
        let visibleDownloaded = EpisodeSearchFilter.filter(playedFilteredDownloaded, query: searchText)
        let visibleExpired = searchActive
            ? allExpired.filter { entry in
                entry.episode.map { EpisodeSearchFilter.matches($0, query: searchText) } ?? false
            }
            : allExpired
        return Group {
            if allDownloaded.isEmpty && allExpired.isEmpty {
                ContentUnavailableView(
                    "No downloads",
                    systemImage: "arrow.down.circle",
                    description: Text("Episodes you download appear here.")
                )
            } else if searchActive && visibleDownloaded.isEmpty && visibleExpired.isEmpty {
                // A search is active (there IS content, it just doesn't match).
                // Guarded on `searchActive` so the played filter hiding every
                // download falls through to the list's empty-filter state (#641)
                // instead of the "no search matches" copy.
                NoSearchMatchesView(query: searchText)
            } else {
                List {
                    // Played/unheard filter (#641). Only shown when there are
                    // downloads to filter; it never touches Recently Expired.
                    if !allDownloaded.isEmpty {
                        Section {
                            Picker("Filter downloads", selection: filterSelection(playedCount: playedCount)) {
                                ForEach(EpisodeListFilter.allCases) { option in
                                    Text(option.title).tag(option)
                                }
                            }
                            .pickerStyle(.segmented)
                            .accessibilityLabel("Filter downloads")
                        }
                    }
                    if !visibleDownloaded.isEmpty {
                        Section(header: Text("Downloaded").accessibilityAddTraits(.isHeader)) {
                            ForEach(visibleDownloaded) { episode in
                                EpisodeRow(episode: episode, actions: actions(for: episode, in: visibleDownloaded), includesPodcastName: true)
                                    // Lets the rotor mark-played runner hand
                                    // VoiceOver focus to this row when its neighbor
                                    // vanishes under the Unheard filter (#641).
                                    .accessibilityFocused($focusedEpisode, equals: episode.persistentModelID)
                            }
                        }
                    } else if !allDownloaded.isEmpty && !searchActive {
                        // The played filter hid every download (all played). Show
                        // a message and a one-tap way back, not a blank list (#641).
                        Section {
                            emptyPlayedFilterState(playedCount: playedCount)
                        }
                    }
                    if !visibleExpired.isEmpty {
                        Section(header: Text("Recently Expired").accessibilityAddTraits(.isHeader)) {
                            ForEach(visibleExpired) { entry in
                                if let episode = entry.episode {
                                    expiredRow(episode, expiredAt: entry.expiredAt)
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
            announceMatches(count: visibleDownloaded.count + visibleExpired.count)
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
        }
        .sheet(item: $showNotesEpisode) { ShowNotesView(episode: $0) }
        .sheet(item: $bookmarksEpisode) { BookmarksListView(episode: $0) }
        .sheet(item: $sharingEpisode) { ShareSheet(items: shareItems(for: $0)) }
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
        .accessibilityActions {
            Button("Restore to queue") { restore(episode) }
        }
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

    private func actions(for episode: Episode, in visible: [Episode]) -> [QuickActionItem] {
        buildEpisodeActions(
            episode: episode,
            order: quickActions.episodeActions,
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
            onExport: { exportEpisode = episode }
        )
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
