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

    private var downloaded: [Episode] {
        allEpisodes
            .filter { $0.downloadStatus == .downloaded }
            .sorted { ($0.pubDate ?? .distantPast) > ($1.pubDate ?? .distantPast) }
    }

    private var expiredEntries: [RecentlyExpired] {
        ExpirationService(context: context).recentlyExpired()
    }

    var body: some View {
        Group {
            if downloaded.isEmpty && expiredEntries.isEmpty {
                ContentUnavailableView(
                    "No downloads",
                    systemImage: "arrow.down.circle",
                    description: Text("Episodes you download appear here.")
                )
            } else {
                List {
                    if !downloaded.isEmpty {
                        Section(header: Text("Downloaded").accessibilityAddTraits(.isHeader)) {
                            ForEach(downloaded) { episode in
                                EpisodeRow(episode: episode, actions: actions(for: episode))
                            }
                        }
                    }
                    if !expiredEntries.isEmpty {
                        Section(header: Text("Recently Expired").accessibilityAddTraits(.isHeader)) {
                            ForEach(expiredEntries) { entry in
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
        .sheet(item: $showNotesEpisode) { ShowNotesView(episode: $0) }
        .sheet(item: $sharingEpisode) { ShareSheet(items: shareItems(for: $0)) }
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
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            [episode.title, episode.podcast?.title].compactMap { $0 }.joined(separator: ", ")
        )
        .accessibilityValue(days <= 0 ? "Recently expired, expiring soon" : "Recently expired, \(days) days left to restore")
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
            onShare: { sharingEpisode = episode }
        )
    }

    private func shareItems(for episode: Episode) -> [Any] {
        if let url = URL(string: episode.audioURL) {
            return [episode.title, url]
        }
        return [episode.title]
    }
}
