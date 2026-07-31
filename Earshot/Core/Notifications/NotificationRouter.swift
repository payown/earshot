import Foundation
import Observation

/// What the user asked for by interacting with a "new episodes" notification.
/// Resolved from the notification's action identifier by ``NotificationDelegate``
/// and consumed by ``RootView`` (#72).
enum NotificationIntent: Sendable, Equatable {
    /// Default tap: deep-link to the podcast's detail screen.
    case openPodcast(feedURL: String)
    /// "Add to queue" action: enqueue the referenced new episode, then deep-link.
    case addEpisodeToQueue(feedURL: String, episodeGUID: String)
    /// "Play now" action: play the referenced new episode, then deep-link.
    case playEpisode(feedURL: String, episodeGUID: String)

    /// The podcast feed URL to navigate to, common to every intent.
    var feedURL: String {
        switch self {
        case let .openPodcast(feedURL),
             let .addEpisodeToQueue(feedURL, _),
             let .playEpisode(feedURL, _):
            return feedURL
        }
    }
}

/// Main-actor routing state bridging notification interactions into the SwiftUI
/// tree. ``NotificationDelegate`` sets `pendingIntent`; ``RootView`` observes it,
/// switches to the Library tab, performs any action (enqueue / play), and pushes
/// the podcast's detail screen, then clears it.
@MainActor
@Observable
final class NotificationRouter {
    /// The most recent unhandled notification intent, or nil when there's
    /// nothing pending.
    var pendingIntent: NotificationIntent?

    /// Set from the (possibly background) delegate callback. Hops to the main
    /// actor to publish so SwiftUI observation is safe.
    func handle(_ intent: NotificationIntent) {
        pendingIntent = intent
    }

    /// Clears the pending intent once ``RootView`` has routed it.
    func clear() {
        pendingIntent = nil
    }
}
