import Foundation

/// Pure composition of the spoken strings used by ``FolderDetailScreen`` —
/// subfolder row labels, the breadcrumb, and the reorder announcement. Kept free
/// of SwiftUI/SwiftData so VoiceOver wording is unit-testable in isolation
/// (folders phase 1 — #753). Counts are always spoken, never implied by
/// indentation, so a screen reader user knows a folder's shape without seeing it.
enum FolderDetailLabel {

    /// The VoiceOver label for a subfolder row: name, then its nested subfolder
    /// and podcast counts, then the word "folder" so the row's kind is spoken
    /// (the chevron/artwork that signals "folder" visually is hidden from
    /// VoiceOver). Example: `News, 2 subfolders, 5 podcasts, folder`.
    static func subfolderRow(name: String, subfolderCount: Int, podcastCount: Int) -> String {
        let subfolders = "\(subfolderCount) \(subfolderCount == 1 ? "subfolder" : "subfolders")"
        let podcasts = "\(podcastCount) \(podcastCount == 1 ? "podcast" : "podcasts")"
        return "\(name), \(subfolders), \(podcasts), folder"
    }

    /// The spoken breadcrumb for the folder header — the root-to-leaf path with a
    /// plain comma between levels, so VoiceOver reads "News, Daily" rather than
    /// voicing the visual `›` separator. `path` is the folder names from
    /// ``FolderLogic/folderPath(_:)`` (root first). Prefixed with "Folder path:"
    /// so a user landing on the header knows what the list of names means.
    static func breadcrumb(path: [String]) -> String {
        let trail = path.joined(separator: ", ")
        return trail.isEmpty ? "Folder path" : "Folder path: \(trail)"
    }

    /// The announcement posted after a non-drag subfolder reorder, telling the
    /// user where the folder landed. `position` is 1-based. Mirrors the wording
    /// ``FoldersScreen`` and the Quick Actions list use.
    static func moveAnnouncement(name: String, position: Int, count: Int) -> String {
        "Moved \(name) to position \(position) of \(count)"
    }

    // MARK: Folder Inbox + listening actions (folders phase 3 — #763)

    static let newEpisodesSectionHeader = "New episodes"
    static let newEpisodesEmptyTitle = "No new episodes"
    static let newEpisodesEmptyDescription =
        "New episodes from podcasts in this folder and its subfolders appear here."

    static func queueAllAnnouncement(count: Int) -> String {
        "Added \(count) \(count == 1 ? "episode" : "episodes") to the queue"
    }

    static func playAllAnnouncement(count: Int, folderName: String) -> String {
        "Playing \(count) \(count == 1 ? "episode" : "episodes") from \(folderName). Added to the queue."
    }

    // MARK: Episodes section (folders phase 2 — #759)

    /// The header for the Episodes section — the hand-picked episodes filed
    /// directly in this folder (``EpisodeFolderMembership``). Rendered as a real
    /// `.isHeader` section header so a VoiceOver user can navigate to it by
    /// heading, the same way the Subfolders and Podcasts sections read.
    static let episodesSectionHeader = "Episodes"

    /// The title of the Episodes section's empty state, spoken when the folder
    /// holds no episodes of its own. A real label — never a blank section — so a
    /// VoiceOver user hears that the section exists and is simply empty, matching
    /// the descriptive empty states the rest of the app uses.
    static let episodesEmptyTitle = "No episodes in this folder"

    /// The Episodes empty-state description: says how episodes get here, since a
    /// folder's episodes are hand-picked from an episode's actions elsewhere (not
    /// added on this screen). Paired with ``episodesEmptyTitle`` in one combined
    /// accessibility element.
    static let episodesEmptyDescription =
        "Add an episode to this folder from its actions, using Add to another folder."

    /// The announcement posted after a single episode is removed from the folder
    /// via its "Remove from folder" rotor action. Names the episode and the
    /// folder so the removal is unambiguous. The episode itself is untouched —
    /// only its membership in this folder is dropped.
    static func removeEpisodeAnnouncement(title: String, folderName: String) -> String {
        "Removed \(title) from \(folderName)"
    }
}
