import Foundation

/// User-selectable ordering for a podcast's episode list. Persisted globally as
/// a String raw value under ``SettingsKey/episodeSortOrder``.
///
/// Kept pure so the ordering rules are unit-testable without a model context
/// (mirrors ``EpisodeListFilter`` and ``LibrarySort``). Alphabetical reuses
/// ``LibrarySort/titlesInOrder(_:_:)`` so leading articles are ignored the same
/// way the Library list treats them, and ties everywhere fall back to that
/// article-aware title order so the result is stable and deterministic
/// (important for predictable VoiceOver focus).
enum EpisodeSortOrder: String, Codable, CaseIterable, Identifiable {
    /// A→Z by title, ignoring a leading article (see ``LibrarySort``).
    case alphabetical
    /// Newest published first. The default for a podcast's episode list, which
    /// preserves the pre-existing pubDate-descending order.
    case latestFirst
    /// Oldest published first.
    case latestLast

    var id: String { rawValue }

    /// User-facing label for the sort menu.
    var title: String {
        switch self {
        case .alphabetical: return "Alphabetical"
        case .latestFirst: return "Latest first"
        case .latestLast: return "Latest last"
        }
    }

    /// VoiceOver announcement spoken once when the user genuinely changes the
    /// sort, e.g. "Sorted by Latest first". Pure so the wording is testable.
    var announcement: String {
        "Sorted by \(title)"
    }

    /// Orders episodes by this sort. `latestFirst`/`latestLast` order by
    /// `pubDate`; episodes with no `pubDate` always sort last regardless of
    /// direction, so undated episodes never jump to the top.
    func sorted(_ episodes: [Episode]) -> [Episode] {
        switch self {
        case .alphabetical:
            return episodes.sorted { LibrarySort.titlesInOrder($0.title, $1.title) }
        case .latestFirst:
            return episodes.sorted {
                Self.inDateOrder(
                    lhsDate: $0.pubDate, lhsTitle: $0.title,
                    rhsDate: $1.pubDate, rhsTitle: $1.title,
                    ascending: false
                )
            }
        case .latestLast:
            return episodes.sorted {
                Self.inDateOrder(
                    lhsDate: $0.pubDate, lhsTitle: $0.title,
                    rhsDate: $1.pubDate, rhsTitle: $1.title,
                    ascending: true
                )
            }
        }
    }

    /// Orders two optional dates. `ascending == false` is newest-first. Missing
    /// dates always sort last regardless of direction. Ties (equal dates, or two
    /// missing dates) fall back to article-aware title order so ordering is
    /// stable and deterministic.
    private static func inDateOrder(
        lhsDate: Date?, lhsTitle: String,
        rhsDate: Date?, rhsTitle: String,
        ascending: Bool
    ) -> Bool {
        switch (lhsDate, rhsDate) {
        case let (l?, r?):
            if l == r { return LibrarySort.titlesInOrder(lhsTitle, rhsTitle) }
            return ascending ? (l < r) : (l > r)
        case (nil, nil):
            return LibrarySort.titlesInOrder(lhsTitle, rhsTitle)
        case (nil, _?):
            return false  // lhs undated → sorts after rhs
        case (_?, nil):
            return true   // rhs undated → lhs sorts before
        }
    }
}
