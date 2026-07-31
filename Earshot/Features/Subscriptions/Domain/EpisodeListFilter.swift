import Foundation

/// Whether a podcast's episode list shows every episode or only unheard ones.
///
/// Pure and SwiftData-free so the filtering rule is unit-testable without a
/// model context, and reusable by binge playback (#488), whose play set follows
/// whichever filter is active. Persisted per podcast as a String raw value under
/// the `podcast_filter_<feedURL>` ``AppSetting`` key (#489); the absent key falls
/// back to ``unheard``.
enum EpisodeListFilter: String, Codable, CaseIterable, Identifiable {
    /// Only episodes that have not been played (`isPlayed == false`). The default.
    case unheard
    /// Every episode, played or not.
    case all

    var id: String { rawValue }

    /// User-facing label for the segmented control.
    var title: String {
        switch self {
        case .unheard: return "Unheard"
        case .all: return "All"
        }
    }

    /// Filters an already-sorted list, preserving the input order. `.unheard`
    /// drops played episodes; `.all` returns the input unchanged.
    func apply(to episodes: [Episode]) -> [Episode] {
        switch self {
        case .unheard: return episodes.filter { !$0.isPlayed }
        case .all: return episodes
        }
    }

    /// VoiceOver announcement describing the visible set after a filter change,
    /// e.g. "Showing 12 unheard episodes" or "Showing all 316 episodes". Pure so
    /// the wording is unit-testable. Plural form is resolved here because the
    /// `^[…](inflect:)` markup is only honored by SwiftUI `Text`, not by the
    /// plain string passed to ``Announcer``.
    func announcement(count: Int) -> String {
        let noun = count == 1 ? "episode" : "episodes"
        switch self {
        case .unheard: return "Showing \(count) unheard \(noun)"
        case .all: return "Showing all \(count) \(noun)"
        }
    }
}
