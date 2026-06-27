import Foundation
import SwiftData

/// A resolved, runnable Quick Action for one content item (episode, podcast, or
/// queue row). The user's configured order drives both the default double-tap
/// (first) and the VoiceOver Actions rotor order.
struct QuickActionItem: Identifiable {
    let id = UUID()
    let label: String
    let isDestructive: Bool
    let run: () -> Void
}

/// Back-compat alias: episode rows referred to this type before Quick Actions
/// covered three content sets.
typealias EpisodeActionItem = QuickActionItem

/// Builds the runnable actions for `episode` in the user's configured `order`.
/// The order is preserved exactly. Dynamic labels (Mark as played/unplayed) are
/// resolved here from the episode's state.
@MainActor
func buildEpisodeActions(
    episode: Episode,
    order: [EpisodeAction],
    player: PlayerService,
    downloads: DownloadManager,
    context: ModelContext,
    onShowNotes: @escaping () -> Void,
    onShare: @escaping () -> Void,
    onBookmarks: @escaping () -> Void
) -> [QuickActionItem] {
    order.map { action in
        switch action {
        case .playNow:
            return QuickActionItem(label: "Play now", isDestructive: false) {
                player.play(episode)
            }
        case .download:
            let downloaded = episode.downloadStatus == .downloaded
            return QuickActionItem(
                label: downloaded ? "Remove download" : "Download",
                isDestructive: downloaded
            ) {
                if downloaded {
                    downloads.removeDownload(episode)
                } else {
                    Task { await downloads.download(episode) }
                }
            }
        case .addToQueueTop:
            return QuickActionItem(label: "Play next", isDestructive: false) {
                QueueRepository(context: context).playNext(episode, after: player.nowPlayingEpisode)
                Announcer.announce("\(episode.title) will play next")
            }
        case .addToQueueBottom:
            return QuickActionItem(label: "Add to end of queue", isDestructive: false) {
                QueueRepository(context: context).add(episode)
                Announcer.announce("Added \(episode.title) to the end of the queue")
            }
        case .markPlayed:
            let played = episode.isPlayed
            return QuickActionItem(
                label: played ? "Mark as unplayed" : "Mark as played",
                isDestructive: false
            ) {
                episode.isPlayed.toggle()
                saveQuickAction(context, "played state")
            }
        case .viewBookmarks:
            return QuickActionItem(label: "Bookmarks", isDestructive: false) {
                onBookmarks()
            }
        case .openShowNotes:
            return QuickActionItem(label: "Open show notes", isDestructive: false) {
                onShowNotes()
            }
        case .share:
            return QuickActionItem(label: "Share", isDestructive: false) {
                onShare()
            }
        }
    }
}

/// Saves the context, logging (not throwing) on failure — Quick Action runners
/// are fire-and-forget from a VoiceOver gesture.
@MainActor
func saveQuickAction(_ context: ModelContext, _ what: String) {
    guard context.hasChanges else { return }
    do {
        try context.save()
    } catch {
        AppLog.quickActions.error("Failed to save \(what, privacy: .public): \(error.localizedDescription, privacy: .public)")
    }
}
