import SwiftUI
import SwiftData

/// Which corpus a ``SearchView`` searches, and which result sections it renders.
///
/// - `.library`: the user's OWN content only — their subscribed podcasts plus the
///   episodes and bookmarks already in the local store. The iTunes directory is
///   NOT searched at all: no network request fires, no "From the directory"
///   section appears. This is the Library tab's toolbar search. Shows local
///   podcasts, episodes, and bookmarks.
/// - `.addPodcast`: the "find a podcast to follow" search used by the Add Podcast
///   flow and onboarding. It is podcast-focused: it shows local matching podcasts
///   (so the user can see a show they already follow) PLUS the iTunes podcast
///   directory (searched automatically as the user types). It deliberately does
///   NOT show episodes or bookmarks — when adding a podcast the user wants SHOWS,
///   not episodes.
enum SearchScope: Equatable {
    case library
    case addPodcast

    /// Whether the local "Podcasts" section renders in this scope. Both scopes show
    /// local matching podcasts.
    var showsPodcasts: Bool { true }

    /// Whether the local "Episodes" section renders. Only `.library` searches
    /// episodes; the Add-Podcast search is show-focused and omits them.
    var showsEpisodes: Bool {
        switch self {
        case .library: return true
        case .addPodcast: return false
        }
    }

    /// Whether the local "Bookmarks" section renders. Only `.library` searches
    /// bookmarks; the Add-Podcast search omits them.
    var showsBookmarks: Bool {
        switch self {
        case .library: return true
        case .addPodcast: return false
        }
    }

    /// Whether the iTunes podcast directory is searched and its "From the
    /// directory" section renders. Only `.addPodcast` reaches the network.
    var showsDirectory: Bool {
        switch self {
        case .library: return false
        case .addPodcast: return true
        }
    }
}

/// Search across local content and — in the `.addPodcast` scope only — the iTunes
/// podcast directory. The set of result sections is driven entirely by the scope
/// (see ``SearchScope``): `.library` shows local podcasts, episodes, and bookmarks
/// with no directory; `.addPodcast` is podcast-focused, showing local podcasts plus
/// the directory but no episodes or bookmarks. When the directory is in scope it is
/// searched automatically as the user types (debounced), so directory results appear
/// alongside the live local results without any extra tap. In `.library` scope the
/// directory path is fully disabled: no iTunes call, no debounce task, no directory
/// section. Results are grouped into clearly-headed sections for a logical VoiceOver
/// structure.
struct SearchView<HeaderContent: View>: View {

    /// The corpus this instance searches and the sections it renders. Defaults to
    /// `.addPodcast` so existing callers keep their directory-backed behaviour;
    /// call sites pass `.library` explicitly to scope the search to the user's own
    /// content.
    let scope: SearchScope

    /// Overrides the navigation title. The Library toolbar search keeps the default
    /// "Search"; the search-first Add Podcast screen passes "Add podcast" so the bar
    /// reads as the add flow it now is.
    private let titleOverride: String?

    /// Whether to move keyboard focus onto the search field as the screen appears,
    /// so a VoiceOver user can start typing a show to follow immediately. Off for
    /// the Library toolbar search (a push within an existing stack), on for the
    /// Add Podcast sheet where searching is the whole point. Honoured on iOS 18+,
    /// where `.searchFocused` exists; on iOS 17 the field still appears, the user
    /// just taps it to begin (no container focus is ever forced).
    private let autoFocusSearch: Bool

    /// Drives the optional search-field autofocus. Bound to the `.searchable` field
    /// via `.searchFocused` so we focus the field itself, never a container.
    @FocusState private var searchFieldFocused: Bool

    /// Caller-supplied content rendered as the FIRST section of the results `List`,
    /// above any local or directory results. This is the reliable home for screen
    /// affordances that must stay reachable while the search field is focused and the
    /// keyboard is up: because it's ordinary `List` content (not nav-bar or keyboard
    /// chrome), VoiceOver always has it in the swipe path and scrolls it into view —
    /// unlike toolbar/keyboard-accessory items, which iOS hides or skips once
    /// `.searchable` is active. The Add Podcast screen uses this to host its
    /// "Add by RSS URL" / "Import OPML file" rows; other callers pass nothing.
    @ViewBuilder private let headerContent: HeaderContent

    init(
        scope: SearchScope = .addPodcast,
        title: String? = nil,
        autoFocusSearch: Bool = false,
        @ViewBuilder headerContent: () -> HeaderContent = { EmptyView() }
    ) {
        self.scope = scope
        self.titleOverride = title
        self.autoFocusSearch = autoFocusSearch
        self.headerContent = headerContent()
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
    /// Programmatic navigation target for a directory row (#499). Set by the row's
    /// primary tap and its VoiceOver Activate action alike, so both paths land on
    /// the same destination.
    @State private var directoryNavigation: DirectoryNavigation?

    private let itunes = ITunesSearchService()

    /// How long the query must be quiet before a directory request fires. Computed
    /// rather than stored because `SearchView` is generic (over its header content)
    /// and generic types can't hold static stored properties.
    private static var debounce: Duration { .milliseconds(350) }

    private var matchedPodcasts: [Podcast] {
        SearchLogic.filter(podcasts, query: query) { "\($0.title) \($0.author ?? "")" }
    }
    private var matchedEpisodes: [Episode] {
        SearchLogic.filter(episodes, query: query) { $0.title }
    }
    private var matchedBookmarks: [Bookmark] {
        SearchLogic.filter(bookmarks, query: query) { "\($0.note) \($0.episode?.title ?? "")" }
    }

    /// Whether this scope surfaced any LOCAL results to the user. Only counts the
    /// sections this scope actually renders, so the Add-Podcast scope (which hides
    /// episodes and bookmarks) doesn't treat a matching episode as a local hit.
    private var hasLocalResults: Bool {
        if !matchedPodcasts.isEmpty { return true }
        if scope.showsEpisodes && !matchedEpisodes.isEmpty { return true }
        if scope.showsBookmarks && !matchedBookmarks.isEmpty { return true }
        return false
    }

    var body: some View {
        List {
            // Caller-supplied rows (e.g. the Add Podcast screen's secondary add
            // paths) live at the top of the List as real content, so they stay in
            // VoiceOver's swipe path with the keyboard up.
            headerContent

            if scope.showsPodcasts && !matchedPodcasts.isEmpty {
                Section(header: Text("Podcasts").accessibilityAddTraits(.isHeader)) {
                    ForEach(matchedPodcasts) { podcast in
                        NavigationLink(value: podcast) {
                            Text(podcast.title)
                        }
                    }
                }
            }
            if scope.showsEpisodes && !matchedEpisodes.isEmpty {
                Section(header: Text("Episodes").accessibilityAddTraits(.isHeader)) {
                    ForEach(matchedEpisodes) { episode in
                        EpisodeRow(episode: episode, actions: episodeActions(episode))
                    }
                }
            }
            if scope.showsBookmarks && !matchedBookmarks.isEmpty {
                Section(header: Text("Bookmarks").accessibilityAddTraits(.isHeader)) {
                    ForEach(matchedBookmarks) { bookmark in
                        bookmarkRow(bookmark)
                    }
                }
            }

            if scope.showsDirectory {
                directorySection
            }
        }
        .navigationTitle(titleOverride ?? "Search")
        .searchable(text: $query, prompt: searchPrompt)
        .modifier(SearchFieldFocus(focused: $searchFieldFocused, autoFocus: autoFocusSearch))
        // The directory search only ever fires in a directory-backed scope (Add
        // Podcast); in `.library` scope `scheduleDirectorySearch` is never wired
        // up, so no network request, debounce task, or directory state change can
        // occur.
        .onChange(of: query) { _, newValue in
            if scope.showsDirectory { scheduleDirectorySearch(for: newValue) }
        }
        .onDisappear { directoryTask?.cancel() }
        .navigationDestination(for: Podcast.self) { EpisodeListView(podcast: $0) }
        // Programmatic destination for a directory row's primary Activate / tap.
        // An un-subscribed hit opens the lightweight preview; an already-subscribed
        // one routes to the existing EpisodeListView (acceptance #4, #499).
        .navigationDestination(item: $directoryNavigation) { destination in
            switch destination {
            case let .preview(result): PodcastPreviewView(result: result)
            case let .subscribed(podcast): EpisodeListView(podcast: podcast)
            }
        }
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
        case .addPodcast:
            return "Search podcasts to follow"
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
                                       description: Text("Find podcasts you follow, episodes, and bookmarks."))
            case .addPodcast:
                ContentUnavailableView("Find a podcast to follow", systemImage: "magnifyingglass",
                                       description: Text("Search by show or author. The directory is searched automatically as you type."))
            }
        } else if scope == .library && !hasLocalResults {
            ContentUnavailableView("No results in your library", systemImage: "magnifyingglass",
                                   description: Text("Nothing in your podcasts, episodes, or bookmarks matches “\(query)”. To find new podcasts, use Add podcast."))
        }
    }

    @ViewBuilder
    private var directorySection: some View {
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
                    // Enumerate so each row knows its one-based position and the
                    // total, for the "result N of M" VoiceOver value (#501). The
                    // index/count follow the displayed relevance order. `results`
                    // is a plain in-memory array (max ~50 iTunes hits), not a
                    // SwiftData `@Query`, so `enumerated()` here doesn't defeat
                    // lazy `@Query` rendering.
                    //
                    // Identify rows by the enumerated `offset` (always unique
                    // 0..<count), NOT by `element.id`. A result's `id` is its feed
                    // URL, and iTunes can return the same feed twice; the upstream
                    // dedupe collapses those, but keying on `offset` guarantees
                    // index↔row can never desync even if any other field ever
                    // collides, so the "result N of M" position stays in step (#501).
                    ForEach(Array(results.enumerated()), id: \.offset) { offset, result in
                        directoryRow(result, index: offset, total: results.count)
                    }
                }
            }
        }
    }

    /// A directory result row with TWO distinct VoiceOver actions (#499):
    ///
    /// - Primary Activate (double-tap) opens the podcast: an un-subscribed hit goes
    ///   to ``PodcastPreviewView`` to read about the show first; an already-followed
    ///   one to the existing `EpisodeListView`. It does NOT follow.
    /// - A single Follow / Unfollow rotor action toggles subscription, with the
    ///   label reflecting current state and an announcement on completion.
    ///
    /// The whole row is collapsed into ONE accessibility element with
    /// `children: .ignore`, so the inner navigate Button and Follow Button don't
    /// each create their own VoiceOver stop. The element is marked a button, its
    /// `.default` action navigates, and the toggle is exposed as a named action —
    /// keeping Activate and Follow genuinely separate. Sighted users still get two
    /// real tap targets: the row body navigates, the trailing button toggles.
    ///
    /// `index` (zero-based) and `total` drive the "result N of M" position context
    /// in the row's accessibility value (#501), composed after the "Following"
    /// state so a subscribed row reads "Following, result 4 of 50" and an
    /// un-subscribed one "result 4 of 50".
    private func directoryRow(_ result: PodcastSearchResult, index: Int, total: Int) -> some View {
        let subscribed = isSubscribed(result)
        let toggleLabel = FollowToggle.actionLabel(subscribed: subscribed)
        return HStack(spacing: Spacing.md) {
            Button {
                openDetail(result)
            } label: {
                HStack(spacing: Spacing.md) {
                    PodcastArtwork(urlString: result.artworkURL)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.title).font(.headline).lineLimit(2)
                        if let author = result.author {
                            Text(author).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(toggleLabel) { toggleFollow(result) }
                .buttonStyle(.bordered)
                .controlSize(.large)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([result.title, result.author].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens this podcast")
        // Value carries "result N of M" position-in-set context (#501), prefixed
        // with "Following, " when subscribed. The phrase is always present, so the
        // value is never empty in either state — no VoiceOver dead-air pause — and
        // the title stays in the label above, never buried in the value.
        .accessibilityValue(
            SearchResultPosition.rowValue(subscribed: subscribed, index: index, total: total)
        )
        // Default action = Activate (double-tap): navigate, never follow.
        .accessibilityAction { openDetail(result) }
        // Single follow control, a toggle that reads "Follow" / "Unfollow".
        .accessibilityAction(named: Text(toggleLabel)) { toggleFollow(result) }
    }

    private func isSubscribed(_ result: PodcastSearchResult) -> Bool {
        podcasts.contains { $0.feedURL == result.feedURL }
    }

    /// Routes a directory row's primary tap / Activate: an already-followed show to
    /// the existing episode list, an un-subscribed one to the read-first preview.
    private func openDetail(_ result: PodcastSearchResult) {
        if let existing = podcasts.first(where: { $0.feedURL == result.feedURL }) {
            directoryNavigation = .subscribed(existing)
        } else {
            directoryNavigation = .preview(result)
        }
    }

    /// Follow / Unfollow toggle for a directory row. The `@Query` updates
    /// reactively, so the row's label, value, and rotor action flip on completion
    /// without the user re-entering the row.
    private func toggleFollow(_ result: PodcastSearchResult) {
        if let existing = podcasts.first(where: { $0.feedURL == result.feedURL }) {
            if SubscriptionRepository(context: context).unsubscribe(existing) {
                Announcer.announce(FollowToggle.announcement(nowFollowing: false, title: result.title))
            }
        } else {
            subscribe(result)
        }
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
        // Deliberately no `onUnfollow` (default nil), so the `.unfollow` Quick
        // Action is omitted from search rows' rotors (#572). Unfollow from
        // search already lives on the result row's Follow toggle (#499), and
        // preview episodes are detached — zero store writes (#517).
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
                announceDirectory(SearchResultPosition.countAnnouncement(results.count))
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
                Announcer.announce(FollowToggle.announcement(nowFollowing: true, title: result.title))
            } catch {
                AppLog.networking.error("Subscribe from search failed for \(result.feedURL, privacy: .public): \(error.localizedDescription, privacy: .public)")
                Announcer.announce("Couldn't follow \(result.title)")
            }
        }
    }

    private func shareItems(for episode: Episode) -> [Any] {
        if let url = URL(string: episode.audioURL) { return [episode.title, url] }
        return [episode.title]
    }
}

/// The destination a directory search row navigates to on its primary Activate /
/// tap (#499). `Hashable` so it drives `navigationDestination(item:)`. An
/// un-subscribed result opens the read-first ``PodcastPreviewView``; an
/// already-followed one routes to the existing `EpisodeListView`.
private enum DirectoryNavigation: Hashable {
    case preview(PodcastSearchResult)
    case subscribed(Podcast)
}

/// Optionally moves keyboard focus onto the `.searchable` field as the screen
/// appears. `.searchFocused` is iOS 18+, so on iOS 17 this is a no-op and the user
/// simply taps the visible search field. We never force focus onto a container —
/// only the search field itself — so VoiceOver lands somewhere it can type, never
/// on a merged group summary.
///
/// Autofocus is suppressed while VoiceOver is running. Auto-popping the keyboard
/// puts `.searchable` into its active state immediately; with VoiceOver that is
/// exactly the state in which iOS-managed chrome (nav-bar items, keyboard-accessory
/// items) gets hidden or dropped from the swipe path, which previously stranded the
/// secondary add controls. Leaving the field unfocused for VoiceOver users keeps the
/// screen calm and fully swipe-navigable — they land on content, read the screen,
/// and swipe to the search field when ready. Sighted users still land in the field
/// and type straight away. The check is read once on appear; if a user toggles
/// VoiceOver while this screen is open the secondary add rows live in the List
/// content (always reachable) so nothing is stranded either way.
private struct SearchFieldFocus: ViewModifier {
    @FocusState.Binding var focused: Bool
    let autoFocus: Bool

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
                .searchFocused($focused)
                .onAppear {
                    if autoFocus && !UIAccessibility.isVoiceOverRunning {
                        focused = true
                    }
                }
        } else {
            content
        }
    }
}
