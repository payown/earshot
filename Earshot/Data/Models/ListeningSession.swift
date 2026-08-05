import Foundation
import SwiftData

/// A span of listening, written for every play session. The source of all
/// stats. Mirrors the Flutter drift `listening_sessions` table.
@Model
final class ListeningSession {
    var episode: Episode?
    var podcast: Podcast?
    var durationSeconds: Int = 0
    var speed: Double = 1.0
    var date: Date = Date.distantPast

    init(
        episode: Episode? = nil,
        podcast: Podcast? = nil,
        durationSeconds: Int,
        speed: Double = 1.0,
        date: Date = .now
    ) {
        self.episode = episode
        self.podcast = podcast
        self.durationSeconds = durationSeconds
        self.speed = speed
        self.date = date
    }
}
