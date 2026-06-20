import SwiftUI
import SwiftData

struct EpisodeListView: View {
    let podcast: Podcast

    @Environment(\.modelContext) private var context
    @Environment(PlayerService.self) private var player
    @Environment(QuickActionStore.self) private var quickActions

    @State private var showNotesEpisode: Episode?
    @State private var sharingEpisode: Episode?

    private var sortedEpisodes: [Episode] {
        podcast.episodes.sorted { ($0.pubDate ?? .distantPast) > ($1.pubDate ?? .distantPast) }
    }

    var body: some View {
        List(sortedEpisodes) { episode in
            EpisodeRow(
                episode: episode,
                actions: buildEpisodeActions(
                    episode: episode,
                    order: quickActions.actions,
                    player: player,
                    context: context,
                    onShowNotes: { showNotesEpisode = episode },
                    onShare: { sharingEpisode = episode }
                )
            )
        }
        .navigationTitle(podcast.title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $showNotesEpisode) { ShowNotesView(episode: $0) }
        .sheet(item: $sharingEpisode) { episode in
            ShareSheet(items: shareItems(for: episode))
        }
    }

    private func shareItems(for episode: Episode) -> [Any] {
        if let url = URL(string: episode.audioURL) {
            return [episode.title, url]
        }
        return [episode.title]
    }
}
