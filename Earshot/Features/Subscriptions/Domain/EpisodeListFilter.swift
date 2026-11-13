import Foundation

/// Whether a podcast's episode list shows every episode or only unplayed ones.
///
/// Pure and SwiftData-free so the filtering rule is unit-testable without a
/// model context, and reusable by binge playback (#488), whose play set follows
/// whichever filter is active. Persisted per podcast as a String raw value under
/// the `podcast_filter_<feedURL>` ``AppSetting`` key (#489); the absent key falls
/// back to ``unheard``.
enum EpisodeListFilter: String, Codable, CaseIterable, Identifiable {
    /// Episodes not marked played (`isPlayed == false`), including those started
    /// but not finished. The default. Keep the raw value for saved preferences.
    case unheard
    /// Unfinished episodes with a saved position above zero.
    case partiallyPlayed
    /// Every episode, played or not.
    case all

    static let podcastChoices: [Self] = [.unheard, .partiallyPlayed, .all]
    static let downloadsChoices: [Self] = [.unheard, .all]

    var id: String { rawValue }

    /// User-facing label for the segmented control.
    var title: String {
        switch self {
        case .unheard: return "Unplayed"
        case .partiallyPlayed: return "Partially Played"
        case .all: return "All"
        }
    }

    /// Filters an already-sorted list, preserving the input order. `.unheard`
    /// drops played episodes; `.all` returns the input unchanged.
    func apply(to episodes: [Episode]) -> [Episode] {
        switch self {
        case .unheard, .partiallyPlayed: return episodes.filter { includes($0) }
        case .all: return episodes
        }
    }

    /// Shared eligibility test for the filter and the live player observer.
    func includes(_ episode: Episode) -> Bool {
        switch self {
        case .unheard: return !episode.isPlayed
        case .partiallyPlayed:
            return episode.positionSeconds > 0 && !episode.isPlayed && episode.playedAt == nil
        case .all: return true
        }
    }

    /// VoiceOver announcement describing the visible set after a filter change,
    /// e.g. "Showing 12 unplayed episodes" or "Showing all 316 episodes". Pure so
    /// the wording is unit-testable. Plural form is resolved here because the
    /// `^[…](inflect:)` markup is only honored by SwiftUI `Text`, not by the
    /// plain string passed to ``Announcer``.
    func announcement(count: Int) -> String {
        let noun = count == 1 ? "episode" : "episodes"
        switch self {
        case .unheard: return "Showing \(count) unplayed \(noun)"
        case .partiallyPlayed: return "Showing \(count) partially played \(noun)"
        case .all: return "Showing all \(count) \(noun)"
        }
    }
}
