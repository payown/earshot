import Foundation

/// Pure builder for an ``EpisodeRow``'s VoiceOver label, extracted so the
/// composition is unit-testable without a view (#535).
///
/// Order matches the Queue's row label (QueueScreen): episode title first so
/// quick flicking still leads with the title, then the podcast name in
/// mixed-show lists (Inbox, Downloads), then Played state and date. Single-show
/// lists (a podcast's episode list, the search preview) pass `podcastName: nil`
/// so VoiceOver users don't hear their own show repeated on every row.
enum EpisodeRowLabel {
    static func label(
        episodeTitle: String,
        podcastName: String?,
        seasonNumber: Int? = nil,
        episodeNumber: Int? = nil,
        isPlayed: Bool,
        pubDate: Date?
    ) -> String {
        var parts = [episodeTitle]
        if let podcastName, !podcastName.isEmpty {
            parts.append(podcastName)
        }
        // Spoken season/episode numbering, after the show name so VoiceOver reads
        // "Title, Show, Season 2, Episode 14, …" (#452).
        if let numbering = spokenNumber(season: seasonNumber, episode: episodeNumber) {
            parts.append(numbering)
        }
        if isPlayed { parts.append("Played") }
        if let pubDate {
            parts.append(pubDate.formatted(date: .abbreviated, time: .omitted))
        }
        return parts.joined(separator: ", ")
    }

    /// Compact visible badge for a row, e.g. `"S2 · E14"`, `"E14"`, `"S2"`, or nil
    /// when neither number is present. Non-positive numbers are treated as absent
    /// so a feed's `0`/negative placeholder never renders (#452).
    static func numberBadge(season: Int?, episode: Int?) -> String? {
        var parts: [String] = []
        if let season, season > 0 { parts.append("S\(season)") }
        if let episode, episode > 0 { parts.append("E\(episode)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Naturally spoken numbering for VoiceOver, e.g. `"Season 2, Episode 14"`,
    /// `"Episode 14"`, `"Season 2"`, or nil. Kept separate from ``numberBadge`` so
    /// the screen reader hears words, not the terse `"S2 · E14"` glyph form (#452).
    static func spokenNumber(season: Int?, episode: Int?) -> String? {
        var parts: [String] = []
        if let season, season > 0 { parts.append("Season \(season)") }
        if let episode, episode > 0 { parts.append("Episode \(episode)") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}
