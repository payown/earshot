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
    @State private var bookmarksEpisode: Episode?
    // The podcast a pending "Unfollow this podcast" rotor Quick Action targets
    // (#572). Non-nil drives the destructive confirmation dialog below —
    // activation never unfollows directly. Same pattern and wording as
    // InboxScreen / SubscriptionsView.
    @State private var pendingUnfollow: Podcast?
    // The in-place `.searchable` filter (#457, Part A). Pure presentation: the
    // downloaded set and the expiration records are filtered in memory only.
    @State private var searchText = ""

    private var downloaded: [Episode] {
        allEpisodes
            .filter { $0.downloadStatus == .downloaded }
            .sorted { ($0.pubDate ?? .distantPast) > ($1.pubDate ?? .distantPast) }
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
        let visibleDownloaded = EpisodeSearchFilter.filter(allDownloaded, query: searchText)
        let visibleExpired = EpisodeSearchFilter.isActive(searchText)
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
            } else if visibleDownloaded.isEmpty && visibleExpired.isEmpty {
                // A search is active (there IS content, it just doesn't match).
                NoSearchMatchesView(query: searchText)
            } else {
                List {
                    if !visibleDownloaded.isEmpty {
                        Section(header: Text("Downloaded").accessibilityAddTraits(.isHeader)) {
                            ForEach(visibleDownloaded) { episode in
                                EpisodeRow(episode: episode, actions: actions(for: episode), includesPodcastName: true)
                            }
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
            // Rotor "Unfollow this podcast" (#572): opens the destructive
            // confirmation above — activation never unfollows directly.
            onUnfollow: { pendingUnfollow = episode.podcast }
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
