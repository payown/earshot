import Foundation

/// Pure, view-free formatting for directory result speech.
///
/// The result count is announced once when a search settles. Individual rows do
/// not repeat their position because that made browsing needlessly verbose.
enum SearchResultPosition {
    /// The once-per-settled-query spoken summary of how many shows the directory
    /// returned ("50 directory results", "1 directory result"). Singular and
    /// plural are handled explicitly so "1 directory result" reads correctly.
    /// Spoken through the existing deduped, polite announcer so it fires once per
    /// settled result set rather than on every keystroke.
    static func countAnnouncement(_ count: Int) -> String {
        count == 1 ? "1 directory result" : "\(count) directory results"
    }
}

enum DirectoryPodcastRowSpeech {
    @MainActor
    static func value(
        subscribed: Bool,
        feedURL: String,
        description: String?,
        mode: SpokenDescriptionMode
    ) -> String? {
        var parts = subscribed ? ["Following"] : []
        if let spokenDescription = SpokenDescriptionCache.shared.text(
            identity: "directory-podcast:\(FeedURLIdentity.canonical(feedURL))",
            html: description,
            mode: mode,
            briefLimit: 240
        ) {
            parts.append(spokenDescription)
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}
