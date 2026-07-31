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
}
