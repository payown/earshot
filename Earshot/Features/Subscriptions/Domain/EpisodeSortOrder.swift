import Foundation

/// User-selectable ordering for a podcast's episode list. Persisted globally as
/// a String raw value under ``SettingsKey/episodeSortOrder``.
///
/// Kept pure so the ordering rules are unit-testable without a model context
/// (mirrors ``EpisodeListFilter`` and ``LibrarySort``). Date ties fall back to
/// article-aware title order so the result is stable and deterministic
/// (important for predictable VoiceOver focus).
enum EpisodeSortOrder: String, Codable, Identifiable {
    /// Newest published first. The default for a podcast's episode list, which
    /// preserves the pre-existing pubDate-descending order.
    case latestFirst
    /// Oldest published first.
    case latestLast

    var id: String { rawValue }

    /// User-facing label for the sort menu.
    var title: String {
        switch self {
        case .latestFirst: return "Newest to oldest"
        case .latestLast: return "Oldest to newest"
        }
    }

    /// VoiceOver announcement spoken once when the user genuinely changes the
    /// sort, e.g. "Sorted by Latest first". Pure so the wording is testable.
    var announcement: String {
        "Sorted by \(title)"
    }

    /// The single podcast-screen control toggles only between chronological
    /// directions.
    var chronologicalToggleTarget: EpisodeSortOrder {
        self == .latestLast ? .latestFirst : .latestLast
    }

    /// Describes the action the chronological toggle will perform.
    var chronologicalToggleTitle: String {
        switch chronologicalToggleTarget {
        case .latestFirst: return "Sort newest to oldest"
        case .latestLast: return "Sort oldest to newest"
        }
    }

    /// Orders episodes by this sort. `latestFirst`/`latestLast` order by
    /// `pubDate`; episodes with no `pubDate` always sort last regardless of
    /// direction, so undated episodes never jump to the top.
    func sorted(_ episodes: [Episode]) -> [Episode] {
        switch self {
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
