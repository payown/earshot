import SwiftUI
import SwiftData

struct EpisodeListView: View {
    let podcast: Podcast

    @Environment(\.modelContext) private var context
    @Environment(PlayerService.self) private var player
    @Environment(DownloadManager.self) private var downloads
    @Environment(QuickActionStore.self) private var quickActions

    @State private var showNotesEpisode: Episode?
    @State private var sharingEpisode: Episode?
    @State private var bookmarksEpisode: Episode?
    @State private var showingPodcastSettings = false

    /// Played/unheard filter for this podcast's list. Loaded per podcast on
    /// appear (default ``EpisodeListFilter/unheard``) and persisted on change
    /// under the `podcast_filter_<feedURL>` AppSetting key (#489).
    @State private var filter: EpisodeListFilter = SettingsDefault.episodeListFilter

    /// All episodes, newest-first. The filter is applied on top of this so the
    /// existing sort order is preserved.
    private var sortedEpisodes: [Episode] {
        podcast.episodes.sorted { ($0.pubDate ?? .distantPast) > ($1.pubDate ?? .distantPast) }
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
                                onBookmarks: { bookmarksEpisode = episode }
                            )
                        )
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
        player.play(first)
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
