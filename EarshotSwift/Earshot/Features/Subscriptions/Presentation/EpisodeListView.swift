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

    private var sortedEpisodes: [Episode] {
        podcast.episodes.sorted { ($0.pubDate ?? .distantPast) > ($1.pubDate ?? .distantPast) }
    }

    var body: some View {
        List {
            Section {
                header
            }
            Section {
                ForEach(sortedEpisodes) { episode in
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
                Text("^[\(sortedEpisodes.count) episode](inflect: true)")
            }
        }
        .navigationTitle(podcast.title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await refresh() }
        .sheet(item: $showNotesEpisode) { ShowNotesView(episode: $0) }
        .sheet(item: $bookmarksEpisode) { BookmarksListView(episode: $0) }
        .sheet(item: $sharingEpisode) { episode in
            ShareSheet(items: shareItems(for: episode))
        }
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
            if let description = podcast.podcastDescription, !description.isEmpty {
                Text(description)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .padding(.top, Spacing.xs)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.sm)
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
