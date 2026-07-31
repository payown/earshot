import Foundation

/// Pure helpers for the "Export audio file" player action (issue #371).
///
/// Kept free of `AVPlayer`, `UIKit`, and SwiftData so the filename rules and the
/// stop-after-episode decision can be unit-tested without real audio.
///
/// Mirrors the Flutter export behaviour: the shared file is named
/// "Podcast name - Episode title" with the original audio extension, and the
/// share always targets the LOCAL downloaded file, never the remote enclosure
/// URL (the #401 concern).
enum EpisodeExportLogic {

    /// Builds the user-facing export filename "Podcast name - Episode title"
    /// with `fileExtension` appended. Both name parts are sanitized so the result
    /// is a single safe path component (no slashes, no control characters, not
    /// empty). When `podcastTitle` is missing or blank, only the episode title is
    /// used. The extension defaults to `mp3` when the source URL carries none.
    static func exportFileName(
        podcastTitle: String?,
        episodeTitle: String,
        sourceURL: URL?
    ) -> String {
        let podcast = sanitize(podcastTitle ?? "")
        let episode = sanitize(episodeTitle)

        let base: String
        if podcast.isEmpty, episode.isEmpty {
            base = "Episode"
        } else if podcast.isEmpty {
            base = episode
        } else if episode.isEmpty {
            base = podcast
        } else {
            base = "\(podcast) - \(episode)"
        }

        let ext = fileExtension(for: sourceURL)
        return "\(base).\(ext)"
    }

    /// The audio file extension to use, derived from `sourceURL`. Falls back to
    /// `mp3` when the URL has no usable path extension.
    static func fileExtension(for sourceURL: URL?) -> String {
        let raw = sourceURL?.pathExtension ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "mp3" : trimmed.lowercased()
    }

    /// Whether end-of-episode playback should STOP instead of auto-advancing,
    /// given the one-off "stop after this episode" flag. Trivial today, but kept
    /// as a named decision so the handlePlaybackEnded intercept stays testable and
    /// the flag's meaning is documented in one place.
    static func shouldStopAfterCurrent(stopAfterCurrentEpisode: Bool) -> Bool {
        stopAfterCurrentEpisode
    }

    /// Replaces path-illegal and control characters with spaces and collapses
    /// runs of whitespace, so the result is a single clean path component.
    private static func sanitize(_ value: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|")
            .union(.controlCharacters)
            .union(.newlines)
        let replaced = String(value.unicodeScalars.map { illegal.contains($0) ? " " : Character($0) })
        let collapsed = replaced
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed
    }
}
