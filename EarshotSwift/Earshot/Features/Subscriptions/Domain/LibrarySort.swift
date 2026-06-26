import Foundation

/// Pure sorting helpers for the Library list. Kept separate from the view so the
/// rules are unit-testable without SwiftData (mirrors the project's logic-test
/// convention).
enum LibrarySort {
    /// Leading articles dropped when alphabetizing, so "The Archers" files under
    /// "A" (Archers) and "An Oral History" under "O". Lowercased with a trailing
    /// space so only whole leading words match (never "Theatre" -> "atre").
    private static let articles = ["the ", "a ", "an "]

    /// Normalizes a title for alphabetical sorting: trimmed, and with a single
    /// leading article removed. Case is preserved so the caller can compare with
    /// `localizedStandardCompare` (which is itself case- and diacritic-insensitive).
    /// A title that is *only* an article (e.g. "The") is left as-is so it doesn't
    /// collapse to an empty key.
    static func sortKey(for title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        for article in articles where lowered.hasPrefix(article) {
            let stripped = String(trimmed.dropFirst(article.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Guard against an article-only title leaving nothing to sort on.
            return stripped.isEmpty ? trimmed : stripped
        }
        return trimmed
    }

    /// Orders two titles alphabetically, ignoring a leading article. Ties (same
    /// article-stripped key) fall back to the full title so the order is stable
    /// and deterministic. Uses `localizedStandardCompare` for Finder-like,
    /// locale-aware ordering (case-insensitive, diacritic-aware, numbers natural).
    static func titlesInOrder(_ lhs: String, _ rhs: String) -> Bool {
        let keyComparison = sortKey(for: lhs).localizedStandardCompare(sortKey(for: rhs))
        if keyComparison == .orderedSame {
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
        return keyComparison == .orderedAscending
    }
}
