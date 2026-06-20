import Foundation

/// Pure, view- and AVFoundation-free playback rules. These are factored out of
/// ``PlayerService`` so they can be unit-tested without starting real audio:
/// source resolution, speed resolution, and the completion / resume threshold.
enum PlaybackLogic {

    /// Fraction of an episode's duration at which it counts as "played". Past
    /// this point we mark it played and restart from the top on the next play.
    static let playedThreshold = 0.95

    /// Resolves which URL to hand to the player for an episode.
    ///
    /// Prefers a downloaded local file when `downloadPath` is set and the file
    /// exists on disk; otherwise streams `audioURL`. Returns `nil` when neither
    /// a usable file nor a valid stream URL is available, so callers can fail
    /// gracefully instead of crashing.
    ///
    /// - Parameters:
    ///   - downloadPath: The local file path, if the episode was downloaded.
    ///   - audioURL: The remote stream URL string from the feed.
    ///   - fileExists: Injectable existence check (defaults to `FileManager`),
    ///     so tests don't need real files on disk.
    static func resolvePlaybackURL(
        downloadPath: String?,
        audioURL: String,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> URL? {
        if let path = downloadPath, !path.isEmpty, fileExists(path) {
            return URL(fileURLWithPath: path)
        }
        let trimmed = audioURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), url.scheme != nil else {
            return nil
        }
        return url
    }

    /// The effective playback rate for an episode: the podcast's per-show
    /// override wins, otherwise the global speed, otherwise 1.0. Non-positive or
    /// missing values fall through to the next source.
    static func effectivePlaybackRate(
        podcastSpeedOverride: Double?,
        globalSpeed: Double
    ) -> Double {
        if let override = podcastSpeedOverride, override > 0 {
            return override
        }
        if globalSpeed > 0 {
            return globalSpeed
        }
        return 1.0
    }

    /// The result of evaluating a playback position against its duration.
    struct CompletionDecision: Equatable {
        /// True once the episode crosses the played threshold (or completes).
        let shouldMarkPlayed: Bool
        /// Where a subsequent `play` should resume. Zero when the episode is
        /// past the threshold (restart from the top) or has no saved progress.
        let resumePosition: Int
    }

    /// The id of the episode to play next after `current` finishes: the first
    /// queue entry that isn't the one that just played. `nil` when the queue is
    /// empty or holds only the current episode. Drives gapless advance.
    static func nextUpID<ID: Equatable>(queue: [ID], after current: ID?) -> ID? {
        queue.first { $0 != current }
    }

    /// Decides whether an episode at `position` of `duration` seconds should be
    /// marked played, and where to resume from on the next play.
    ///
    /// - Below the threshold: resume from `position`.
    /// - At or above the threshold (>= 95%): mark played and resume from 0.
    /// - Unknown / non-positive duration: never auto-mark; resume from
    ///   `position` so saved progress is honored.
    static func completionDecision(position: Int, duration: Int?) -> CompletionDecision {
        let safePosition = max(0, position)
        guard let duration, duration > 0 else {
            return CompletionDecision(shouldMarkPlayed: false, resumePosition: safePosition)
        }
        let fraction = Double(safePosition) / Double(duration)
        if fraction >= playedThreshold {
            return CompletionDecision(shouldMarkPlayed: true, resumePosition: 0)
        }
        return CompletionDecision(shouldMarkPlayed: false, resumePosition: safePosition)
    }
}
