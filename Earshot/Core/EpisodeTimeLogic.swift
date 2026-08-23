import Foundation

/// Pure, SwiftData-free helpers that turn an episode's stored
/// `positionSeconds` / `durationSeconds` into the compact time treatment shown
/// on episode rows (#493/#552). An in-progress episode exposes remaining and
/// total time, an untouched one exposes its total length, and a played (or
/// duration-less) one shows nothing. Kept pure so it is unit-testable and shared
/// by every list that uses ``EpisodeRow``.
enum EpisodeTimeLogic {

    /// What an episode row should surface for time, derived purely from stored
    /// progress. `Equatable` so the decision can be asserted directly in tests.
    enum Display: Equatable {
        /// In progress: seconds remaining until the end and the full duration.
        case remaining(Int, total: Int)
        /// Not started: the episode's total length in seconds.
        case total(Int)
        /// Nothing to show (played, finished-but-unmarked, or unknown duration).
        case none
    }

    /// Decides the time treatment for a row.
    ///
    /// - Played, or `durationSeconds` missing / non-positive: ``Display/none``
    ///   (the existing Played state stands on its own; no "--" artifact).
    /// - Position at or before 0: ``Display/total`` (show the full length).
    /// - 0 < position < duration: ``Display/remaining(_:total:)``.
    /// - Position at or past duration but not marked played: ``Display/none``
    ///   (effectively finished; never render "0 min left").
    static func display(positionSeconds: Int, durationSeconds: Int?, isPlayed: Bool) -> Display {
        guard !isPlayed, let duration = durationSeconds, duration > 0 else { return .none }
        let position = max(0, positionSeconds)
        if position == 0 { return .total(duration) }
        let remaining = duration - position
        if remaining <= 0 { return .none }
        return .remaining(remaining, total: duration)
    }

    /// Compact visible text for the row, e.g. "12 min left · 42 min total" or
    /// "1 hr 5 min". `nil` when there is nothing to show.
    static func visibleText(positionSeconds: Int, durationSeconds: Int?, isPlayed: Bool) -> String? {
        switch display(positionSeconds: positionSeconds, durationSeconds: durationSeconds, isPlayed: isPlayed) {
        case .none:
            return nil
        case let .total(seconds):
            return compactLength(seconds)
        case let .remaining(seconds, total):
            return "\(compactLength(seconds)) left · \(compactLength(total)) total"
        }
    }

    /// VoiceOver-friendly spoken text, e.g. "12 minutes left, 42 minutes total"
    /// or "1 hour 5 minutes". Minute-granular (no seconds) so rows stay terse.
    /// `nil` when there is nothing to speak.
    static func spokenText(positionSeconds: Int, durationSeconds: Int?, isPlayed: Bool) -> String? {
        switch display(positionSeconds: positionSeconds, durationSeconds: durationSeconds, isPlayed: isPlayed) {
        case .none:
            return nil
        case let .total(seconds):
            return spokenLength(seconds)
        case let .remaining(seconds, total):
            return "\(spokenLength(seconds)) left, \(spokenLength(total)) total"
        }
    }

    // MARK: - Formatting

    /// Whole minutes, rounded to nearest, with a floor of 1 for any positive
    /// remainder so a 20-second tail still reads as "1 min" rather than "0 min".
    static func wholeMinutes(_ seconds: Int) -> Int {
        let total = max(0, seconds)
        if total == 0 { return 0 }
        return max(1, Int((Double(total) / 60.0).rounded()))
    }

    private static func compactLength(_ seconds: Int) -> String {
        let minutes = wholeMinutes(seconds)
        let hours = minutes / 60
        let mins = minutes % 60
        if hours > 0 && mins > 0 { return "\(hours) hr \(mins) min" }
        if hours > 0 { return "\(hours) hr" }
        return "\(minutes) min"
    }

    private static func spokenLength(_ seconds: Int) -> String {
        let minutes = wholeMinutes(seconds)
        let hours = minutes / 60
        let mins = minutes % 60
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours) \(hours == 1 ? "hour" : "hours")") }
        if mins > 0 || hours == 0 { parts.append("\(mins) \(mins == 1 ? "minute" : "minutes")") }
        return parts.joined(separator: " ")
    }
}
