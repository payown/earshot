import Foundation

/// Pure, view-free formatting for a directory search result's position-in-set
/// context and the once-per-settled-query count announcement (#501).
///
/// Robin (VoiceOver) found stepping through a long directory result list one
/// swipe at a time slow and disorienting: nothing told her how large the list
/// was or where she was within it. These helpers feed two VoiceOver outputs:
///
///   - each directory row's `accessibilityValue` ("result 4 of 50"), composed
///     AFTER the existing "Following" state so a subscribed row reads
///     "Following, result 4 of 50" and an un-subscribed one just
///     "result 4 of 50"; and
///   - the single count summary spoken when a result set settles
///     ("50 directory results").
///
/// Kept free of SwiftUI so the index mapping, plural handling, and value
/// composition are unit-testable in isolation.
enum SearchResultPosition {

    /// "result 4 of 50" — the one-based position of a row within the displayed,
    /// relevance-ordered result set. `zeroBased` is the row's array index; the
    /// "+1" lives here so call sites never have to remember to add it.
    ///
    /// Out-of-range indices are clamped into `1...max(total, 1)` so VoiceOver
    /// never speaks "result 0 of 50" or a position past the end, even if a caller
    /// passes a stale index during a list update.
    static func phrase(index zeroBased: Int, total: Int) -> String {
        let safeTotal = max(total, 1)
        let oneBased = min(max(zeroBased + 1, 1), safeTotal)
        return "result \(oneBased) of \(safeTotal)"
    }

    /// The full `accessibilityValue` for a directory row: the position phrase,
    /// prefixed with "Following, " when the show is already subscribed.
    ///
    /// #499 set the value to "Following" only when subscribed (omitting it
    /// otherwise to avoid VoiceOver speaking an empty value as dead-air). The
    /// position phrase is always present, so the value is now never empty in
    /// either subscription state — no dead air either way — and the title stays
    /// in the row's `accessibilityLabel`, never buried in the value.
    static func rowValue(subscribed: Bool, index zeroBased: Int, total: Int) -> String {
        let position = phrase(index: zeroBased, total: total)
        return subscribed ? "Following, \(position)" : position
    }

    /// The once-per-settled-query spoken summary of how many shows the directory
    /// returned ("50 directory results", "1 directory result"). Singular and
    /// plural are handled explicitly so "1 directory result" reads correctly.
    /// Spoken through the existing deduped, polite announcer so it fires once per
    /// settled result set rather than on every keystroke.
    static func countAnnouncement(_ count: Int) -> String {
        count == 1 ? "1 directory result" : "\(count) directory results"
    }
}
