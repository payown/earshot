import SwiftUI
import SwiftData

struct EpisodeListView: View {
    let podcast: Podcast

    @Environment(\.modelContext) private var context
    @Environment(PlayerService.self) private var player
    @Environment(DownloadManager.self) private var downloads
    @Environment(QuickActionStore.self) private var quickActions
    @Environment(SettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var showNotesEpisode: Episode?
    @State private var sharingEpisode: Episode?
    @State private var bookmarksEpisode: Episode?
    @State private var showingPodcastSettings = false
    // The pending "Unfollow this podcast" rotor Quick Action (#572). This is a
    // single-show screen, so unfollow always targets the shown `podcast`; it
    // still confirms, and the screen pops after the delete since its podcast is
    // gone. Wording matches InboxScreen / SubscriptionsView.
    @State private var pendingUnfollow: Podcast?

    // Focus targets for the rotor "Mark as played" under the Unheard filter,
    // where the marked row leaves the visible list (#579): the neighbor row, or
    // the empty-filter state when the last unheard episode was just marked.
    // Mirrors the Inbox's neighbor-focus wiring.
    @AccessibilityFocusState private var focusedEpisode: PersistentIdentifier?
    @AccessibilityFocusState private var focusEmptyFilter: Bool

    /// Played/unheard filter for this podcast's list. Loaded per podcast on
    /// appear (default ``EpisodeListFilter/unheard``) and persisted on change
    /// under the `podcast_filter_<feedURL>` AppSetting key (#489).
    @State private var filter: EpisodeListFilter = SettingsDefault.episodeListFilter

    /// All episodes in the user's chosen order (global ``EpisodeSortOrder``,
    /// default ``EpisodeSortOrder/latestFirst`` which preserves the pre-existing
    /// newest-first order). The filter is applied on top of this (#459).
    private var sortedEpisodes: [Episode] {
        settings.episodeSortOrder.sorted(podcast.episodes)
    }

    /// The visible set: the active filter applied to the sorted episodes.
    private var filteredSortedEpisodes: [Episode] {
        filter.apply(to: sortedEpisodes)
    }

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
                Announcer.announce(newValue.announcement(count: newValue.apply(to: sortedEpisodes).count))
            }
        )
    }

    /// Persists and announces only on a genuine user change. The global sort is
    /// loaded by ``SettingsStore/configure(context:)`` (not by this view), so the
    /// binding fires only on a real pick and never speaks on load.
    private var sortSelection: Binding<EpisodeSortOrder> {
        Binding(
            get: { settings.episodeSortOrder },
            set: { newValue in
                guard newValue != settings.episodeSortOrder else { return }
                settings.episodeSortOrder = newValue
                Announcer.announce(newValue.announcement)
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
            if !filteredSortedEpisodes.isEmpty {
                Section {
                    bingeButton
                }
            }
            if sortedEpisodes.isEmpty && podcast.refreshedAt == nil {
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
            } else if filteredSortedEpisodes.isEmpty {
                // Episodes exist but none match the current filter. Give a
                // descriptive message and a one-tap way out, not a blank list.
                Section {
                    emptyFilterState
                }
            } else {
                Section {
                    ForEach(filteredSortedEpisodes) { episode in
                        EpisodeRow(
                            episode: episode,
                            actions: buildEpisodeActions(
                                episode: episode,
                                order: quickActions.episodeActions,
                                player: player,
                                downloads: downloads,
                                context: context,
                                onShowNotes: { showNotesEpisode = episode },
                                onShare: { sharingEpisode = episode },
                                onBookmarks: { bookmarksEpisode = episode },
                                // Rotor "Unfollow this podcast" (#572): opens the
                                // destructive confirmation below — activation
                                // never unfollows directly.
                                onUnfollow: { pendingUnfollow = podcast },
                                // Under the Unheard filter, rotor "Mark as
                                // played" removes this row (#579). The builder
                                // invokes this BEFORE the played flip, so the
                                // neighbor is captured while the row is still
                                // visible; focus moves after the list has
                                // re-rendered — to the neighbor, or the
                                // empty-filter state when this was the last
                                // unheard episode. Under All the row stays put,
                                // so no focus management is needed.
                                onMarkPlayed: { nowPlayed in
                                    guard filter == .unheard, nowPlayed else { return }
                                    let neighbor = neighborID(of: episode, in: filteredSortedEpisodes)
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                        if let neighbor {
                                            focusedEpisode = neighbor
                                        } else {
                                            focusEmptyFilter = true
                                        }
                                    }
                                }
                            )
                        )
                        // Lets the rotor mark-played runner hand VoiceOver focus
                        // to this row when its neighbor vanishes (#579).
                        .accessibilityFocused($focusedEpisode, equals: episode.persistentModelID)
                    }
                } header: {
                    Text(filter == .unheard
                         ? "^[\(filteredSortedEpisodes.count) unheard episode](inflect: true)"
                         : "^[\(filteredSortedEpisodes.count) episode](inflect: true)")
                }
            }
        }
        .onAppear {
            filter = AppSettingsStore(context: context).episodeListFilter(forFeedURL: podcast.feedURL)
        }
        .navigationTitle(podcast.title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await refresh() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort episodes", selection: sortSelection) {
                        ForEach(EpisodeSortOrder.allCases) { order in
                            Text(order.title).tag(order)
                        }
                    }
                } label: {
                    Label("Sort episodes", systemImage: "arrow.up.arrow.down")
                }
                // Speak the active order on the menu button itself so VoiceOver
                // users know the current sort without opening the menu.
                .accessibilityValue(settings.episodeSortOrder.title)
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
        }
        .sheet(isPresented: $showingPodcastSettings) {
            PodcastSettingsView(podcast: podcast)
        }
        .sheet(item: $showNotesEpisode) { ShowNotesView(episode: $0) }
        .sheet(item: $bookmarksEpisode) { BookmarksListView(episode: $0) }
        .sheet(item: $sharingEpisode) { episode in
            ShareSheet(items: shareItems(for: episode))
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
            Text("This removes \(podcast.title) and its episodes from your library. This can't be undone.")
        }
    }

    /// Unfollows the shown podcast via the centralized repository path shared
    /// with Library, search, and the inbox (#499/#500) — never an inline delete.
    /// The repo logs failures and returns whether the delete saved, so we
    /// announce and pop only on `true`; this screen's subject no longer exists,
    /// so it dismisses back to the list it was pushed from.
    private func unfollow(_ podcast: Podcast) {
        let title = podcast.title
        let removed = SubscriptionRepository(context: context).unsubscribe(podcast)
        pendingUnfollow = nil
        guard removed else { return }
        Announcer.announce("Unfollowed \(title)")
        dismiss()
    }

    /// Podcast-level "Play oldest first" binge entry point (#488). Seeds the
    /// queue with the active-filter set and starts the oldest episode, so
    /// auto-advance continues through this podcast oldest→newest instead of
    /// jumping to an unrelated inbox episode.
    private var bingeButton: some View {
        Button(action: playOldestFirst) {
            Label("Play oldest first", systemImage: "play.circle")
        }
        .accessibilityLabel("Play oldest first")
        .accessibilityHint("Plays this podcast's episodes from oldest to newest")
    }

    /// Starts the binge run from the currently visible (filtered) episodes.
    private func playOldestFirst() {
        let episodes = filteredSortedEpisodes
        guard !episodes.isEmpty else { return }
        let repo = QueueRepository(context: context)
        guard let first = repo.bingeOldestFirst(podcast, episodes: episodes) else { return }
        // playFromEpisodeList so the binge honors the #562 open-player setting (Item 1).
        player.playFromEpisodeList(first)
        let noun = episodes.count == 1 ? "episode" : "episodes"
        Announcer.announce("Playing \(podcast.title) oldest first, \(episodes.count) \(noun)")
    }

    private var header: some View {
        VStack(alignment: .center, spacing: Spacing.sm) {
            PodcastArtwork(urlString: podcast.artworkURL, size: 120, cornerRadius: 12)
            Text(podcast.title)
                .font(.headline)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
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
            try await SubscriptionRepository(context: context).refresh(podcast)
            Announcer.announce("\(podcast.title) refreshed")
        } catch {
            AppLog.subscriptions.error("Refresh failed: \(error.localizedDescription, privacy: .public)")
            Announcer.announce("Couldn't refresh \(podcast.title)")
        }
    }

    private func shareItems(for episode: Episode) -> [Any] {
        if let url = URL(string: episode.audioURL) {
            return [episode.title, url]
        }
        return [episode.title]
    }
}
