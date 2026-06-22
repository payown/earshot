import Foundation

/// A request to notify the user that a subscribed podcast has new episodes.
///
/// Pure value type produced by the refresh path and consumed by
/// ``NotificationService``. Carries everything needed to build the notification
/// content and to deep-link / act on it from the notification's actions. Uses
/// the models' natural keys (feed URL, episode guid) rather than
/// `PersistentIdentifier`, mirroring the rest of the app (e.g.
/// `lastPlayingEpisodeID` stores `episode.guid`) so the references resolve
/// reliably across launches:
///   - `podcastFeedURL`: the unique feed URL, for the deep link to the show.
///   - `episodeGUID`: guid of the single newest new episode, used by the
///     "Add to queue" / "Play now" actions.
///   - `podcastTitle`: notification title (plain text — no emoji, per #72 a11y).
///   - `newEpisodeCount`: how many genuinely-new episodes were detected.
///
/// `Sendable` so it can cross the background-refresh actor boundary safely.
struct NewEpisodeNotification: Sendable, Equatable {
    let podcastFeedURL: String
    let episodeGUID: String
    let podcastTitle: String
    let newEpisodeCount: Int

    /// The notification body, correctly pluralized. Plain text only — VoiceOver
    /// reads emoji names aloud, so the issue forbids them here (#72).
    /// "1 new episode" / "3 new episodes".
    var body: String {
        NewEpisodeNotification.bodyText(newEpisodeCount: newEpisodeCount)
    }

    /// Pure, testable pluralization. Exposed statically so tests don't need to
    /// build a full value.
    static func bodyText(newEpisodeCount count: Int) -> String {
        let n = max(count, 0)
        return n == 1 ? "1 new episode" : "\(n) new episodes"
    }
}
