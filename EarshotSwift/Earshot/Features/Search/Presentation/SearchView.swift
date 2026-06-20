import SwiftUI
import SwiftData

/// Search across local content (podcasts, episodes, bookmarks), with a "Search
/// Everywhere" button that expands to the iTunes podcast directory. Results are
/// grouped into clearly-headed sections for a logical VoiceOver structure.
struct SearchView: View {
    @Environment(\.modelContext) private var context
    @Environment(PlayerService.self) private var player
    @Environment(DownloadManager.self) private var downloads
    @Environment(QuickActionStore.self) private var quickActions

    @Query private var podcasts: [Podcast]
    @Query private var episodes: [Episode]
    @Query private var bookmarks: [Bookmark]

    @State private var query = ""
    @State private var searchEverywhere = false
    @State private var directoryResults: [PodcastSearchResult] = []
    @State private var searchingDirectory = false
    @State private var showNotesEpisode: Episode?
    @State private var sharingEpisode: Episode?
    @State private var bookmarksEpisode: Episode?

    private let itunes = ITunesSearchService()

    private var matchedPodcasts: [Podcast] {
        SearchLogic.filter(podcasts, query: query) { "\($0.title) \($0.author ?? "")" }
    }
    private var matchedEpisodes: [Episode] {
        SearchLogic.filter(episodes, query: query) { $0.title }
    }
    private var matchedBookmarks: [Bookmark] {
        SearchLogic.filter(bookmarks, query: query) { "\($0.note) \($0.episode?.title ?? "")" }
    }

    private var hasLocalResults: Bool {
        !matchedPodcasts.isEmpty || !matchedEpisodes.isEmpty || !matchedBookmarks.isEmpty
    }

    var body: some View {
        List {
            if !matchedPodcasts.isEmpty {
                Section(header: Text("Podcasts").accessibilityAddTraits(.isHeader)) {
                    ForEach(matchedPodcasts) { podcast in
                        NavigationLink(value: podcast) {
                            Text(podcast.title)
                        }
                    }
                }
            }
            if !matchedEpisodes.isEmpty {
                Section(header: Text("Episodes").accessibilityAddTraits(.isHeader)) {
                    ForEach(matchedEpisodes) { episode in
                        EpisodeRow(episode: episode, actions: episodeActions(episode))
                    }
                }
            }
            if !matchedBookmarks.isEmpty {
                Section(header: Text("Bookmarks").accessibilityAddTraits(.isHeader)) {
                    ForEach(matchedBookmarks) { bookmark in
                        bookmarkRow(bookmark)
                    }
                }
            }

            searchEverywhereSection
        }
        .navigationTitle("Search")
        .searchable(text: $query, prompt: "Search podcasts, episodes, bookmarks")
        .onChange(of: query) { _, _ in if searchEverywhere { runDirectorySearch() } }
        .navigationDestination(for: Podcast.self) { EpisodeListView(podcast: $0) }
        .sheet(item: $showNotesEpisode) { ShowNotesView(episode: $0) }
        .sheet(item: $bookmarksEpisode) { BookmarksListView(episode: $0) }
        .sheet(item: $sharingEpisode) { ShareSheet(items: shareItems(for: $0)) }
        .overlay {
            if query.isEmpty {
                ContentUnavailableView("Search Earshot", systemImage: "magnifyingglass",
                                       description: Text("Find podcasts, episodes, and bookmarks. Use Search Everywhere to browse the directory."))
            } else if !hasLocalResults && !searchEverywhere {
                ContentUnavailableView.search(text: query)
            }
        }
    }

    @ViewBuilder
    private var searchEverywhereSection: some View {
        if !query.isEmpty {
            if !searchEverywhere {
                Section {
                    Button {
                        searchEverywhere = true
                        runDirectorySearch()
                    } label: {
                        Label("Search Everywhere", systemImage: "globe")
                    }
                    .accessibilityHint("Also search the iTunes podcast directory")
                }
            } else {
                Section(header: Text("From the directory").accessibilityAddTraits(.isHeader)) {
                    if searchingDirectory {
                        HStack { ProgressView(); Text("Searching the directory…") }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("Searching the directory")
                    } else if directoryResults.isEmpty {
                        Text("No podcasts found in the directory.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(directoryResults) { result in
                            directoryRow(result)
                        }
                    }
                }
            }
        }
    }

    private func directoryRow(_ result: PodcastSearchResult) -> some View {
        let subscribed = isSubscribed(result)
        return HStack(spacing: Spacing.md) {
            PodcastArtwork(urlString: result.artworkURL)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.title).font(.headline)
                if let author = result.author {
                    Text(author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Button(subscribed ? "Subscribed" : "Subscribe") { subscribe(result) }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(subscribed)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel([result.title, result.author].compactMap { $0 }.joined(separator: ", "))
        .accessibilityValue(subscribed ? "Subscribed" : "")
        .accessibilityActions {
            if !subscribed { Button("Subscribe") { subscribe(result) } }
        }
    }

    private func isSubscribed(_ result: PodcastSearchResult) -> Bool {
        podcasts.contains { $0.feedURL == result.feedURL }
    }

    private func bookmarkRow(_ bookmark: Bookmark) -> some View {
        Button {
            guard let episode = bookmark.episode else {
                Announcer.announce("This bookmark's episode is unavailable")
                return
            }
            player.play(episode, at: Double(bookmark.positionSeconds))
            Announcer.announce("Playing from \(BookmarkLogic.spoken(bookmark.positionSeconds))")
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(bookmark.note.isEmpty ? "Bookmark" : bookmark.note).font(.body)
                if let title = bookmark.episode?.title {
                    Text(title).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Double tap to play from the bookmarked spot")
    }

    private func episodeActions(_ episode: Episode) -> [QuickActionItem] {
        buildEpisodeActions(
            episode: episode, order: quickActions.episodeActions, player: player,
            downloads: downloads, context: context,
            onShowNotes: { showNotesEpisode = episode }, onShare: { sharingEpisode = episode },
            onBookmarks: { bookmarksEpisode = episode }
        )
    }

    private func runDirectorySearch() {
        let term = query
        searchingDirectory = true
        Task {
            let results = await itunes.search(term)
            // Ignore stale responses if the query moved on.
            if term == query {
                directoryResults = results
                searchingDirectory = false
                Announcer.announce(results.isEmpty
                    ? "No podcasts found in the directory"
                    : "^[\(results.count) directory result](inflect: true)")
            }
        }
    }

    private func subscribe(_ result: PodcastSearchResult) {
        Task {
            do {
                _ = try await SubscriptionRepository(context: context).subscribe(feedURL: result.feedURL)
                Announcer.announce("Subscribed to \(result.title)")
            } catch {
                Announcer.announce("Couldn't subscribe to \(result.title)")
            }
        }
    }

    private func shareItems(for episode: Episode) -> [Any] {
        if let url = URL(string: episode.audioURL) { return [episode.title, url] }
        return [episode.title]
    }
}
