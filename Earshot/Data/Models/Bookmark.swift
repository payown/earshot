import Foundation
import SwiftData

/// A saved timestamp within an episode. Mirrors the Flutter drift `bookmarks`
/// table.
@Model
final class Bookmark {
    var episode: Episode?
    var positionSeconds: Int
    var note: String
    var createdAt: Date

    init(
        episode: Episode? = nil,
        positionSeconds: Int,
        note: String = "",
        createdAt: Date = .now
    ) {
        self.episode = episode
        self.positionSeconds = positionSeconds
        self.note = note
        self.createdAt = createdAt
    }
}
