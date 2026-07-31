import Foundation
import SwiftData

/// Join row linking a podcast to a folder, with per-folder ordering. Mirrors
/// the Flutter drift `podcast_folder_memberships` table. Uniqueness of
/// (folder, podcast) is enforced in the folder repository.
@Model
final class FolderMembership {
    var folder: PodcastFolder?
    var podcast: Podcast?
    var sortOrder: Int

    init(folder: PodcastFolder? = nil, podcast: Podcast? = nil, sortOrder: Int = 0) {
        self.folder = folder
        self.podcast = podcast
        self.sortOrder = sortOrder
    }
}
