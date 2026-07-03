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
        isPlayed: Bool,
        pubDate: Date?
    ) -> String {
        var parts = [episodeTitle]
        if let podcastName, !podcastName.isEmpty {
            parts.append(podcastName)
        }
        if isPlayed { parts.append("Played") }
        if let pubDate {
            parts.append(pubDate.formatted(date: .abbreviated, time: .omitted))
        }
        return parts.joined(separator: ", ")
    }
}
