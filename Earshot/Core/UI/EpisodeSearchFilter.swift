import SwiftUI

/// Pure matching for the per-screen `.searchable` filters on the Inbox, Queue,
/// and Downloads lists (#457, Part A). Presentation-only: callers filter the
/// arrays they already loaded — no repository or query changes.
///
/// Matching is case- AND diacritic-insensitive (`localizedStandardContains`,
/// the same matching Finder/Music use) across, in short-circuit order:
///
/// 1. episode title
/// 2. podcast title
/// 3. the episode's cached full description
///
/// Description matching deliberately goes through ``SpokenDescriptionCache``
/// in full mode rather than re-stripping `EpisodeSummary.plainText` per
/// keystroke. The cache is pressure-evictable and cost-bounded, while its key
/// includes the source content hash so refreshed notes cannot return stale
/// matches. This lets podcast-detail search find terms anywhere in feed notes,
/// not only in the brief row-summary prefix.
@MainActor
enum EpisodeSearchFilter {

    /// The query with surrounding whitespace removed — what matching actually
    /// runs against.
    static func normalized(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether a search is in effect. A whitespace-only field is not a search.
    static func isActive(_ query: String) -> Bool {
        !normalized(query).isEmpty
    }

    /// Whether `episode` matches `query`. An inactive (empty/whitespace) query
    /// matches everything, so callers can filter unconditionally.
    static func matches(_ episode: Episode, query: String) -> Bool {
        let trimmed = normalized(query)
        guard !trimmed.isEmpty else { return true }
        if episode.title.localizedStandardContains(trimmed) { return true }
        if let podcast = episode.podcast?.title,
           podcast.localizedStandardContains(trimmed) {
            return true
        }
        if let description = SpokenDescriptionCache.shared.text(
            identity: "episode-search:\(episode.guid)\u{1}\(episode.audioURL)",
            html: episode.episodeDescription,
            mode: .full,
            briefLimit: 140
        ), description.localizedStandardContains(trimmed) {
            return true
        }
        return false
    }

    /// `episodes` narrowed to the ones matching `query`, preserving order.
    /// Returns the array unchanged (not a re-allocation) when no search is
    /// active, so attaching this to a list is free until the user types.
    static func filter(_ episodes: [Episode], query: String) -> [Episode] {
        guard isActive(query) else { return episodes }
        return episodes.filter { matches($0, query: query) }
    }

    /// The VoiceOver result-count announcement ("5 episodes match"). Callers
    /// announce this on search submit only — never per keystroke, never while
    /// the field is empty.
    static func resultAnnouncement(count: Int) -> String {
        switch count {
        case 0: return "No episodes match"
        case 1: return "1 episode matches"
        default: return "\(count) episodes match"
        }
    }
}

/// The shared "no results" state for an active per-screen search (#457): shown
/// in place of the list when the user's search text matches nothing on the
/// screen. One combined accessibility element, standard search iconography,
/// and the echoed query so the user can hear exactly what didn't match.
struct NoSearchMatchesView: View {
    let query: String

    var body: some View {
        ContentUnavailableView {
            Label("No episodes match", systemImage: "magnifyingglass")
        } description: {
            Text("Nothing here matches “\(EpisodeSearchFilter.normalized(query))”. Try a different search.")
        }
        .accessibilityElement(children: .combine)
    }
}
