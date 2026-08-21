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
        pubDate: Date?,
        downloadState: DownloadStatus? = nil,
        isNowPlaying: Bool = false,
        contextDetail: String? = nil,
        details: EpisodeSpokenDetails = EpisodeSpokenDetails()
    ) -> String {
        // "Now Playing" leads the label so VoiceOver announces the current
        // episode's state before its title ("Now Playing, [title], …"). One state
        // regardless of playing or paused (Item 2). Callers that don't track
        // playback pass the default false and the prefix is omitted.
        var parts = isNowPlaying ? ["Now Playing", episodeTitle] : [episodeTitle]
        if details.includesPodcastName, let podcastName, !podcastName.isEmpty {
            parts.append(podcastName)
        }
        // Spoken season/episode numbering, after the show name so VoiceOver reads
        // "Title, Show, Season 2, Episode 14, …" (#452).
        if let numbering = spokenNumber(season: seasonNumber, episode: episodeNumber) {
            parts.append(numbering)
        }
        if let contextDetail, !contextDetail.isEmpty { parts.append(contextDetail) }
        if isPlayed { parts.append("Played") }
        if details.includesPublishedDate, let pubDate {
            parts.append(pubDate.formatted(date: .abbreviated, time: .omitted))
        }
        // Downloaded / streaming state, last so the user always hears — before
        // choosing Play — whether the audio is local or will stream (#513). Folded
        // into this single comma-joined label so it's part of the one row element,
        // never a separate VoiceOver stop. Omitted entirely when a caller passes
        // nil (e.g. surfaces that don't carry the state).
        if details.includesDownloadStatus, let downloadState {
            parts.append(spokenDownloadState(downloadState))
        }
        return parts.joined(separator: ", ")
    }

    /// Naturally spoken download/streaming state for VoiceOver (#513), folded into
    /// the row label so it never adds a second stop. Four buckets:
    /// - ``DownloadStatus/downloaded`` → `"Downloaded"`
    /// - ``DownloadStatus/downloading`` → `"Downloading"`
    /// - ``DownloadStatus/pending`` → `"Waiting for Wi-Fi"` (parked by the
    ///   Wi-Fi-only gate, not transferring — saying "Downloading" here was a lie
    ///   that hid why nothing was happening, #576)
    /// - ``DownloadStatus/none``, ``DownloadStatus/failed`` → `"Streams when played"`
    ///   (a failed download falls back to streaming, so it reads the same as an
    ///   episode that was never downloaded).
    static func spokenDownloadState(_ status: DownloadStatus) -> String {
        switch status {
        case .downloaded: return "Downloaded"
        case .downloading: return "Downloading"
        case .pending: return "Waiting for Wi-Fi"
        case .none, .failed: return "Streams when played"
        }
    }

    /// Pure data for the compact visible download/streaming badge (#513): an SF
    /// Symbol name plus a short label. Rendered as icon + text (never colour-only,
    /// never icon-only) by ``DownloadStateBadge``; colour is layered on in the
    /// view. Mirrors ``spokenDownloadState(_:)``'s three buckets.
    struct DownloadBadge: Equatable {
        let systemImage: String
        let text: String
    }

    static func downloadBadge(_ status: DownloadStatus) -> DownloadBadge {
        switch status {
        case .downloaded:
            return DownloadBadge(systemImage: "arrow.down.circle.fill", text: "Downloaded")
        case .downloading:
            return DownloadBadge(systemImage: "arrow.down.circle", text: "Downloading")
        case .pending:
            // Wi-Fi-gated, not transferring (#576).
            return DownloadBadge(systemImage: "wifi", text: "Waiting for Wi-Fi")
        case .none, .failed:
            return DownloadBadge(systemImage: "dot.radiowaves.up.forward", text: "Streaming")
        }
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
