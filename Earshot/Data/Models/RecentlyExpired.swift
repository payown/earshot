import Foundation
import SwiftData

/// An episode auto-expired from the queue, recoverable for 7 days. Mirrors the
/// Flutter drift `recently_expired` table.
@Model
final class RecentlyExpired {
    var episode: Episode?
    var expiredAt: Date

    init(episode: Episode? = nil, expiredAt: Date = .now) {
        self.episode = episode
        self.expiredAt = expiredAt
    }
}
