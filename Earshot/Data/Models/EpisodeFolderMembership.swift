import Foundation
import SwiftData

/// Join row linking an episode to a folder, with per-folder ordering. The
/// episode-level analogue of ``FolderMembership`` (which links a *podcast* to a
/// folder). New entity in schema V6 (folders phase 1 — #751).
///
/// Mirrors the ``FolderMembership`` conventions deliberately: both relationships
/// are optional (`folder` / `episode`), and there is NO inverse `@Relationship`
/// collection on ``Episode``. An inverse on `Episode` would change `Episode`'s
/// shape and put a real library's ~242k episode rows into the V5→V6 migration's
/// path — the exact thing the download-entity design (#701) exists to avoid.
///
/// Because ``episode`` has no inverse, SwiftData maintains no referential
/// integrity for it: rows must be cleaned up manually before their episode (or
/// its podcast) is deleted, the same discipline ``FolderMembership`` and
/// ``ActiveDownload`` follow. That cleanup is wired in folders phase 2 (#756):
/// ``FolderRepository/removePodcastEpisodesFromAllFolders(_:)`` runs at the
/// unsubscribe choke point before the podcast (and its cascaded episodes) is
/// deleted, ``FolderRepository/removeEpisodeFromAllFolders(_:)`` covers any
/// future per-episode delete, and ``FolderRepository`` also drops these rows when
/// a folder is deleted (no inverse on ``PodcastFolder`` either).
@Model
final class EpisodeFolderMembership {
    var folder: PodcastFolder?
    var episode: Episode?
    var sortOrder: Int = 0

    init(folder: PodcastFolder? = nil, episode: Episode? = nil, sortOrder: Int = 0) {
        self.folder = folder
        self.episode = episode
        self.sortOrder = sortOrder
    }
}
