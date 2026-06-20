import Foundation
import SwiftData

/// A resolved, runnable action for one episode.
struct EpisodeActionItem: Identifiable {
    let id = UUID()
    let label: String
    let isDestructive: Bool
    let run: () -> Void
}

/// Builds the runnable actions for [episode] in the user's configured [order].
/// The order is preserved exactly, so it drives both the default double-tap
/// (first) and the VoiceOver rotor order. Dynamic labels (Mark as
/// played/unplayed) are resolved here from the episode's state.
@MainActor
func buildEpisodeActions(
    episode: Episode,
    order: [EpisodeAction],
    player: PlayerService,
    context: ModelContext,
    onShowNotes: @escaping () -> Void,
    onShare: @escaping () -> Void
) -> [EpisodeActionItem] {
    order.map { action in
        switch action {
        case .playNow:
            return EpisodeActionItem(label: "Play now", isDestructive: false) {
                player.play(episode)
            }
        case .markPlayed:
            let played = episode.isPlayed
            return EpisodeActionItem(
                label: played ? "Mark as unplayed" : "Mark as played",
                isDestructive: false
            ) {
                episode.isPlayed.toggle()
                do {
                    try context.save()
                } catch {
                    AppLog.quickActions.error("Failed to save played state: \(error.localizedDescription, privacy: .public)")
                }
            }
        case .openShowNotes:
            return EpisodeActionItem(label: "Open show notes", isDestructive: false) {
                onShowNotes()
            }
        case .share:
            return EpisodeActionItem(label: "Share", isDestructive: false) {
                onShare()
            }
        }
    }
}
