import Foundation
import SwiftData

/// A position in the play queue. One per episode (enforced in the queue
/// repository). Mirrors the Flutter drift `queue_items` table.
@Model
final class QueueItem {
    var episode: Episode?
    /// Ordering key. Can go negative for front-insert; compacted periodically.
    var position: Int
    var addedAt: Date

    init(episode: Episode? = nil, position: Int, addedAt: Date = .now) {
        self.episode = episode
        self.position = position
        self.addedAt = addedAt
    }
}
