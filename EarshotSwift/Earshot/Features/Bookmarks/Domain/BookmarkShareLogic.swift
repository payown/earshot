import Foundation

/// Pure share-text builder for a single bookmark (issue #372).
///
/// Flutter shares a deep link (`episode/{id}?t={seconds}`), but the SwiftUI app
/// has no episode deep-link handler yet (that's #383), so sharing a bare scheme
/// would give the recipient nothing actionable. Instead we share useful, human-
/// readable text: the episode title, the bookmarked timestamp, the note if the
/// user wrote one, and the audio URL so the spot can still be found in any
/// player.
///
/// Kept free of SwiftData and UIKit so the format can be unit-tested directly.
enum BookmarkShareLogic {

    /// Builds the multi-line text shared for one bookmark.
    ///
    /// Lines, in order, omitting any that have no content:
    ///   1. Episode title (falls back to "Bookmark" when blank).
    ///   2. "Bookmarked at H:MM:SS" using ``BookmarkLogic/clock(_:)``.
    ///   3. The trimmed note, when non-empty.
    ///   4. The audio URL, when present and non-blank.
    ///
    /// - Parameters:
    ///   - episodeTitle: The episode's title; trimmed, with a safe fallback.
    ///   - positionSeconds: The bookmarked position; clamped to >= 0 by `clock`.
    ///   - note: The user's optional note; whitespace-only counts as empty.
    ///   - audioURL: The episode enclosure URL string; blank is treated as none.
    static func shareText(
        episodeTitle: String,
        positionSeconds: Int,
        note: String,
        audioURL: String?
    ) -> String {
        var lines: [String] = []

        let title = episodeTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append(title.isEmpty ? "Bookmark" : title)

        lines.append("Bookmarked at \(BookmarkLogic.clock(positionSeconds))")

        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNote.isEmpty {
            lines.append(trimmedNote)
        }

        if let audioURL {
            let trimmedURL = audioURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedURL.isEmpty {
                lines.append(trimmedURL)
            }
        }

        return lines.joined(separator: "\n")
    }
}
