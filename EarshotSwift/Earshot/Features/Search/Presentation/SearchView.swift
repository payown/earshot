import SwiftUI
import SwiftData

/// Which corpus a ``SearchView`` searches.
///
/// - `.library`: the user's OWN content only — their subscribed podcasts plus the
///   episodes and bookmarks already in the local store. The iTunes directory is
///   NOT searched at all: no network request fires, no "From the directory"
///   section appears. This is the Library tab's toolbar search.
/// - `.everywhere`: local content PLUS the iTunes podcast directory (searched
///   automatically as the user types). This is the "find new podcasts" search
///   used by the Add Podcast flow and onboarding.
enum SearchScope: Equatable {
    case library
    case everywhere
}

/// Search across local content (podcasts, episodes, bookmarks) and — in the
/// `.everywhere` scope only — the iTunes podcast directory. When the directory is
/// in scope it is searched automatically as the user types (debounced), so
/// directory results appear alongside the live local results without any extra
/// tap. In `.library` scope the directory path is fully disabled: no iTunes call,
/// no debounce task, no directory section. Results are grouped into clearly-headed
/// sections for a logical VoiceOver structure.
struct SearchView: View {

    /// The corpus this instance searches. Defaults to `.everywhere` so existing
    /// callers keep their behaviour; call sites pass `.library` explicitly to scope
    /// the search to the user's own content.
    let scope: SearchScope

    init(scope: SearchScope = .everywhere) {
        self.scope = scope
    }

    /// The current state of the automatic directory search.
    private enum DirectoryState: Equatable {
        case idle
        case searching
        case results([PodcastSearchResult])
        case empty
        case failed
    }

    @Environment(\.modelContext) private var context
    @Environment(PlayerService.self) private var player
    @Environment(DownloadManager.self) private var downloads
    @Environment(QuickActionStore.self) private var quickActions

    @Query private var podcasts: [Podcast]
    @Query private var episodes: [Episode]
    @Query private var bookmarks: [Bookmark]

    @State private var query = ""
    @State private var directoryState: DirectoryState = .idle
    @State private var directoryTask: Task<Void, Never>?
    /// The last directory summary spoken to VoiceOver. Used to suppress repeat
    /// announcements: because the search fires on a debounce as the user types,
    /// settling on the same outcome twice (e.g. two "failed" in a row, or the
    /// same result count) must not re-interrupt the user.
    @State private var lastAnnouncedSummary = ""
    @State private var showNotesEpisode: Episode?
    @State private var sharingEpisode: Episode?
    @State private var bookmarksEpisode: Episode?

    private let itunes = ITunesSearchService()

    /// How long the query must be quiet before a directory request fires.
    private static let debounce: Duration = .milliseconds(350)

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

            if scope == .everywhere {
                searchEverywhereSection
            }
        }
        .navigationTitle("Search")
        .searchable(text: $query, prompt: searchPrompt)
        // The directory search only ever fires in `.everywhere` scope; in
        // `.library` scope `scheduleDirectorySearch` is never wired up, so no
        // network request, debounce task, or directory state change can occur.
        .onChange(of: query) { _, newValue in
            if scope == .everywhere { scheduleDirectorySearch(for: newValue) }
        }
        .onDisappear { directoryTask?.cancel() }
        .navigationDestination(for: Podcast.self) { EpisodeListView(podcast: $0) }
        .sheet(item: $showNotesEpisode) { ShowNotesView(episode: $0) }
        .sheet(item: $bookmarksEpisode) { BookmarksListView(episode: $0) }
        .sheet(item: $sharingEpisode) { ShareSheet(items: shareItems(for: $0)) }
        .overlay { emptyOverlay }
    }

    /// The prompt shown in the search field, tailored to the scope so VoiceOver and
    /// sighted users both understand what's being searched.
    private var searchPrompt: String {
        switch scope {
        case .library:
            return "Search your library"
        case .everywhere:
            return "Search podcasts, episodes, bookmarks"
        }
    }

    /// The placeholder shown before any query is typed, and — in `.library` scope —
    /// the "no results" message when a query matches nothing in the user's content.
    /// In `.library` scope there is no directory fallback, so an empty result set is
    /// terminal and must be announced clearly rather than implying more is coming.
    @ViewBuilder
    private var emptyOverlay: some View {
        if query.isEmpty {
            switch scope {
            case .library:
                ContentUnavailableView("Search your library", systemImage: "magnifyingglass",
                                       description: Text("Find your subscribed podcasts, episodes, and bookmarks."))
            case .everywhere:
                ContentUnavailableView("Search Earshot", systemImage: "magnifyingglass",
                                       description: Text("Find podcasts, episodes, and bookmarks. The directory is searched automatically as you type."))
            }
        } else if scope == .library && !hasLocalResults {
            ContentUnavailableView("No results in your library", systemImage: "magnifyingglass",
                                   description: Text("Nothing in your podcasts, episodes, or bookmarks matches “\(query)”. To find new podcasts, use Add podcast."))
        }
    }

    @ViewBuilder
    private var searchEverywhereSection: some View {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            Section(header: Text("From the directory").accessibilityAddTraits(.isHeader)) {
                switch directoryState {
                case .idle:
                    EmptyView()
                case .searching:
                    HStack { ProgressView(); Text("Searching the directory…") }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Searching the directory")
                case .empty:
                    Text("No podcasts found in the directory.")
                        .foregroundStyle(.secondary)
                case .failed:
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        // Error is signalled by icon + text, not colour alone.
                        Label {
                            Text("Couldn't search the directory. Check your connection.")
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                        .accessibilityElement(children: .combine)
                        Button {
                            scheduleDirectorySearch(for: query, immediate: true)
                        } label: {
                            Label("Try Again", systemImage: "arrow.clockwise")
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityHint("Retry searching the iTunes podcast directory")
                    }
                case .results(let results):
                    ForEach(results) { result in
                        directoryRow(result)
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
        // Only set a value when there's something to say. An empty
        // accessibilityValue("") is spoken as a pause (dead air) in VoiceOver.
        .modifier(SubscribedValue(subscribed: subscribed))
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

    /// Debounces directory searches: each keystroke cancels the previous in-flight
    /// task and schedules a fresh one after a quiet period. Whitespace-only or
    /// empty queries cancel any pending search and clear results without firing a
    /// request. Pass `immediate: true` (the retry button) to skip the debounce.
    private func scheduleDirectorySearch(for term: String, immediate: Bool = false) {
        directoryTask?.cancel()

        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            directoryState = .idle
            // Clearing the field resets the dedup token so the next real search
            // always announces its outcome.
            lastAnnouncedSummary = ""
            return
        }

        directoryState = .searching
        directoryTask = Task {
            if !immediate {
                try? await Task.sleep(for: Self.debounce)
                if Task.isCancelled { return }
            }

            let outcome = await itunes.search(trimmed)
            if Task.isCancelled { return }

            switch outcome {
            case .results(let results) where results.isEmpty:
                directoryState = .empty
                announceDirectory("No podcasts found in the directory")
            case .results(let results):
                directoryState = .results(results)
                announceDirectory("^[\(results.count) directory result](inflect: true)")
            case .failure:
                directoryState = .failed
                announceDirectory("Couldn't search the directory. Check your connection.")
            }
        }
    }

    /// Speaks a directory-search summary only when it differs from the last one
    /// spoken. The search runs on a debounce as the user types, so without this
    /// guard a user who pauses several times would hear a stack of queued count
    /// announcements. Announcements stay polite (queued behind the user's current
    /// speech) so they never cut off the letter the user is typing.
    @MainActor
    private func announceDirectory(_ summary: String) {
        guard summary != lastAnnouncedSummary else { return }
        lastAnnouncedSummary = summary
        Announcer.announce(summary)
    }

    private func subscribe(_ result: PodcastSearchResult) {
        Task {
            do {
                _ = try await SubscriptionRepository(context: context).subscribe(feedURL: result.feedURL)
                Announcer.announce("Subscribed to \(result.title)")
            } catch {
                AppLog.networking.error("Subscribe from search failed for \(result.feedURL, privacy: .public): \(error.localizedDescription, privacy: .public)")
                Announcer.announce("Couldn't subscribe to \(result.title)")
            }
        }
    }

    private func shareItems(for episode: Episode) -> [Any] {
        if let url = URL(string: episode.audioURL) { return [episode.title, url] }
        return [episode.title]
    }
}

/// Applies an `accessibilityValue` only when the podcast is subscribed. Omitting
/// the modifier entirely (rather than passing "") avoids VoiceOver speaking an
/// empty value as a pause on every not-yet-subscribed directory row.
private struct SubscribedValue: ViewModifier {
    let subscribed: Bool

    func body(content: Content) -> some View {
        if subscribed {
            content.accessibilityValue("Subscribed")
        } else {
            content
        }
    }
}
