import Foundation
import SwiftData

/// Restores the last-played episode on launch so the Now Playing bar is
/// populated (paused) without auto-starting audio. Kept separate from views so
/// the lookup runs once at startup, not inside a view's body.
@MainActor
enum PlaybackStartup {

    /// Loads the episode referenced by ``SettingsKey/lastPlayingEpisodeID`` (its
    /// `guid`) into the player, paused, with its saved position restored.
    static func restoreLastEpisode(into player: PlayerService, context: ModelContext) {
        let settings = AppSettingsStore(context: context)
        guard let guid = settings.rawValue(SettingsKey.lastPlayingEpisodeID), !guid.isEmpty else {
            return
        }
        var descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate { $0.guid == guid }
        )
        descriptor.fetchLimit = 1
        guard let episode = (try? context.fetch(descriptor))?.first else {
            AppLog.player.info("No stored last episode found for guid")
            return
        }
        player.load(episode, autoplay: false)
    }
}
