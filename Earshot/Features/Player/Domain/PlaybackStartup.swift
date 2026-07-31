import Foundation
import SwiftData

/// Restores the last-played episode on launch so the Now Playing bar is
/// populated (paused) without auto-starting audio. Kept separate from views so
/// the lookup runs once at startup, not inside a view's body.
@MainActor
enum PlaybackStartup {

    /// Loads the episode referenced by ``SettingsKey/lastPlayingEpisodeID`` into
    /// the player, paused, with its saved position restored. The stored value is
    /// the composite ``DownloadTaskKey`` (`"feedURL|guid"`, #576 — guids repeat
    /// across podcasts); values written by earlier builds are bare guids and
    /// still resolve by guid alone.
    static func restoreLastEpisode(into player: PlayerService, context: ModelContext) {
        let settings = AppSettingsStore(context: context)
        guard let stored = settings.rawValue(SettingsKey.lastPlayingEpisodeID), !stored.isEmpty else {
            return
        }
        guard let episode = DownloadTaskKey.episode(matching: stored, in: context) else {
            AppLog.player.info("No stored last episode found for stored key")
            return
        }
        player.load(episode, autoplay: false)
    }
}
