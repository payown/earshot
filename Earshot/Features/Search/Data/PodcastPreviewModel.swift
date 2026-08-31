import Foundation

/// Pure label and announcement strings for the Follow / Unfollow toggle shared by
/// directory search rows and the podcast preview (#499). Kept free of SwiftUI and
/// SwiftData so the toggle's state-to-text mapping is unit-testable in isolation.
enum FollowToggle {
    /// The rotor-action and button label for the toggle, given the CURRENT
    /// subscription state: not followed reads "Follow", followed reads "Unfollow".
    static func actionLabel(subscribed: Bool) -> String {
        subscribed ? "Unfollow" : "Follow"
    }

    /// The VoiceOver announcement to post AFTER a successful toggle, described by
    /// the NEW state. Following announces "Now following <title>"; unfollowing
    /// announces "Unfollowed <title>".
    static func announcement(nowFollowing: Bool, title: String) -> String {
        nowFollowing ? "Now following \(title)" : "Unfollowed \(title)"
    }
}

/// A read-only episode summary shown in the podcast preview for an UN-subscribed
/// directory result. It is a plain value type derived from the parsed feed — not a
/// stored `Episode` — so the preview can show "what's recent" without subscribing,
/// inserting anything into the store, or fetching audio.
struct PreviewEpisode: Identifiable, Equatable, Sendable {
    /// Canonicalizable show identity carried with the value so a later queue
    /// action never has to recover persistence identity from visible text.
    let podcastFeedURL: String
    /// Directory metadata wins over the feed title/artwork. These values keep a
    /// materialized catalog episode grouped and presented under the show the
    /// listener selected in Discovery.
    let podcastTitle: String
    let podcastArtworkURL: String?
    let id: String
    let title: String
    let pubDate: Date?
    let durationSeconds: Int?
    /// The enclosure URL carried straight through from the parsed feed so the
    /// preview can STREAM the episode without subscribing or downloading (#517).
    /// Empty when the feed item has no playable enclosure — the view renders such
    /// a row as non-playable rather than offering a dead play action.
    let audioURL: String
    /// Show-notes HTML, passed through so a streamed preview can surface chapters
    /// embedded in the description and a sensible Now Playing description.
    let episodeDescription: String?
    /// Plain-text show notes prepared once while mapping the feed. Preview
    /// search reads this value rather than stripping HTML again for every
    /// keystroke across a potentially large publisher archive.
    let searchableDescription: String
    /// Per-episode artwork when the feed provides it; the Now Playing surfaces
    /// fall back to the show artwork when this is nil.
    let artworkURL: String?
    let episodeNumber: Int?
    let seasonNumber: Int?
    /// Podcasting 2.0 chapter feed URL, passed through so a streamed preview still
    /// gets chapter navigation.
    let chapterURL: String?
    let transcriptURL: String?
}

/// Chronological presentation order for an unsubscribed podcast preview.
/// Kept independent from the saved-podcast setting: auditing a feed must not
/// silently change how followed podcasts are ordered elsewhere in the app.
enum PreviewEpisodeSortOrder: String, CaseIterable, Identifiable, Equatable {
    case newestFirst
    case oldestFirst

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newestFirst: return "Newest to oldest"
        case .oldestFirst: return "Oldest to newest"
        }
    }

    var toggleTarget: PreviewEpisodeSortOrder {
        self == .newestFirst ? .oldestFirst : .newestFirst
    }

    var toggleTitle: String {
        switch toggleTarget {
        case .newestFirst: return "Sort newest to oldest"
        case .oldestFirst: return "Sort oldest to newest"
        }
    }

    var announcement: String { "Sorted by \(title)" }

    /// Missing dates always trail dated episodes. Date and title ties fall
    /// back to the feed GUID so changing sort order never destabilizes SwiftUI
    /// row identity or VoiceOver focus.
    func sorted(_ episodes: [PreviewEpisode]) -> [PreviewEpisode] {
        episodes.sorted { lhs, rhs in
            switch (lhs.pubDate, rhs.pubDate) {
            case let (left?, right?):
                if left != right {
                    return self == .oldestFirst ? left < right : left > right
                }
            case (nil, nil):
                break
            case (nil, _?):
                return false
            case (_?, nil):
                return true
            }

            let titleOrder = lhs.title.localizedStandardCompare(rhs.title)
            if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
            return lhs.id < rhs.id
        }
    }
}

/// Pure local matching for publisher-feed episodes. An empty query preserves
/// the exact input array and an active query preserves the selected sort order.
enum PreviewEpisodeSearchFilter {
    static func normalized(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isActive(_ query: String) -> Bool {
        !normalized(query).isEmpty
    }

    static func matches(_ episode: PreviewEpisode, query: String) -> Bool {
        let query = normalized(query)
        guard !query.isEmpty else { return true }
        return episode.title.localizedStandardContains(query)
            || episode.searchableDescription.localizedStandardContains(query)
    }

    static func filter(_ episodes: [PreviewEpisode], query: String) -> [PreviewEpisode] {
        guard isActive(query) else { return episodes }
        return episodes.filter { matches($0, query: query) }
    }
}

/// Fixed Discovery actions for a playable preview episode. The enum is stable
/// across SwiftUI body evaluations; queue state changes only replace the one
/// state-specific middle action and never replace the episode row itself.
enum PreviewEpisodeAction: String, Identifiable, Equatable, StableQuickActionPresentation {
    case playNow
    case addToQueueEnd
    case removeFromQueue
    case playNext

    var id: String { rawValue }

    var label: String {
        switch self {
        case .playNow: "Play now"
        case .addToQueueEnd: "Add to end of queue"
        case .removeFromQueue: "Remove from queue"
        case .playNext: "Play next"
        }
    }

    var isDestructive: Bool { self == .removeFromQueue }
}

/// Pure presentation policy shared by VoiceOver's Actions rotor and the sighted
/// long-press menu. Missing/whitespace audio exposes no dead actions.
enum PreviewEpisodeActions {
    static func resolved(audioURL: String, isQueued: Bool) -> [PreviewEpisodeAction] {
        guard !audioURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        return isQueued
            ? [.playNow, .removeFromQueue, .playNext]
            : [.playNow, .addToQueueEnd, .playNext]
    }

    static func announcement(
        for action: PreviewEpisodeAction,
        outcome: CatalogEpisodeQueueOutcome,
        title: String
    ) -> String? {
        switch (action, outcome) {
        case (.addToQueueEnd, .added):
            "Added \(title) to the end of the queue"
        case (.playNext, .movedNext):
            "\(title) will play next"
        case (.removeFromQueue, .removed):
            "Removed \(title) from the queue"
        default:
            nil
        }
    }

    /// Queue mutations publish `.earshotQueueDidChange` after their durable save,
    /// which is the preview's single refresh path for committed changes. No-op
    /// outcomes intentionally publish nothing, so explicitly reconcile those to
    /// recover from an earlier failed or stale screen snapshot without speaking.
    static func needsNoOpMembershipRefresh(
        after outcome: CatalogEpisodeQueueOutcome
    ) -> Bool {
        switch outcome {
        case .alreadyQueued, .alreadyNext, .alreadyRemoved:
            true
        case .added, .movedNext, .removed:
            false
        }
    }

    static func failureAnnouncement(
        for action: PreviewEpisodeAction,
        failure: CatalogEpisodeQueueFailure,
        title: String
    ) -> String? {
        guard failure != .cancelled else { return nil }
        switch action {
        case .playNow:
            return nil
        case .addToQueueEnd:
            return "Couldn't add \(title) to the queue"
        case .removeFromQueue:
            return "Couldn't remove \(title) from the queue"
        case .playNext:
            return "Couldn't move \(title) to play next"
        }
    }
}

extension PreviewEpisode {
    /// Canonical natural identity used by both the screen snapshot and queue
    /// mutations. Visible title is deliberately never part of membership.
    var catalogIdentity: CatalogEpisodeIdentity? {
        let feedURL = FeedURLIdentity.canonical(podcastFeedURL)
        let guid = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !feedURL.isEmpty, !guid.isEmpty else { return nil }
        return CatalogEpisodeIdentity(feedURL: feedURL, guid: guid)
    }
}

/// Drives the podcast preview: fetches an UN-subscribed feed once via
/// ``FeedFetching`` (the same abstraction the subscribe flow uses) and exposes the
/// show description plus every episode exposed by the publisher's current feed
/// so a user — VoiceOver or sighted — can audit a show without following it.
///
/// `@MainActor` because it owns view-facing state; the network fetch itself runs
/// inside `FeedService`/`HTTPClient` off the main thread and only the parsed,
/// value-type result is mapped here.
@MainActor
@Observable
final class PodcastPreviewModel {
    /// Where the one-shot feed load is in its lifecycle. Distinguishing `.loading`
    /// from `.failed` lets the view show a spinner, an error with retry, and the
    /// loaded content as three explicit states rather than a blank list.
    enum LoadState: Equatable {
        case loading
        case loaded(description: String?, episodes: [PreviewEpisode])
        case failed
    }

    private(set) var state: LoadState = .loading

    private let feed: FeedFetching

    init(feed: FeedFetching = FeedService()) {
        self.feed = feed
    }

    /// Fetches and parses the feed, then publishes the description and every
    /// episode the publisher exposes in that feed. Never throws — a failure is
    /// folded into `.failed`
    /// (logged) so the view can offer a retry. Safe to call again (retry).
    func load(
        feedURL: String,
        podcastTitle: String? = nil,
        podcastArtworkURL: String? = nil
    ) async {
        state = .loading
        do {
            let parsed = try await feed.fetch(feedURL)
            // Large publisher feeds can contain thousands of descriptions. HTML
            // sanitizing and deterministic deduplication are pure work, so keep
            // them off the main actor and publish only the finished value graph.
            let prepared = await Task.detached(priority: .userInitiated) {
                (
                    description: Self.cleanedDescription(parsed.description),
                    episodes: Self.availableEpisodes(
                        from: parsed,
                        feedURL: feedURL,
                        podcastTitle: podcastTitle,
                        podcastArtworkURL: podcastArtworkURL
                    )
                )
            }.value
            state = .loaded(
                description: prepared.description,
                episodes: prepared.episodes
            )
        } catch {
            AppLog.networking.error(
                "Podcast preview feed load failed for \(feedURL, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            state = .failed
        }
    }

    /// Pure: every episode exposed by a parsed feed, newest-first, mapped to
    /// read-only ``PreviewEpisode`` values. This is feed-bounded: a publisher
    /// may omit older archive entries from its RSS document.
    nonisolated static func availableEpisodes(
        from feed: ParsedFeed,
        feedURL: String = "",
        podcastTitle: String? = nil,
        podcastArtworkURL: String? = nil
    ) -> [PreviewEpisode] {
        let directoryTitle = podcastTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = directoryTitle.flatMap { $0.isEmpty ? nil : $0 } ?? feed.title
        let resolvedArtworkURL = podcastArtworkURL ?? feed.artworkURL
        let uniqueEpisodes = deduplicatedEpisodes(feed.episodes)
        let previews = uniqueEpisodes.map {
                PreviewEpisode(
                    podcastFeedURL: feedURL,
                    podcastTitle: resolvedTitle,
                    podcastArtworkURL: resolvedArtworkURL,
                    id: $0.guid,
                    title: $0.title,
                    pubDate: $0.pubDate,
                    durationSeconds: $0.durationSeconds,
                    audioURL: $0.audioURL,
                    episodeDescription: $0.description,
                    searchableDescription: EpisodeSummary.plainText($0.description),
                    artworkURL: $0.artworkURL,
                    episodeNumber: $0.episodeNumber,
                    seasonNumber: $0.seasonNumber,
                    chapterURL: $0.chapterURL,
                    transcriptURL: $0.transcriptURL
                )
            }
        return PreviewEpisodeSortOrder.newestFirst.sorted(previews)
    }

    /// Feed GUID is the stable SwiftUI row identity and the playback identity,
    /// so collapse malformed duplicate items before rendering. Match the saved
    /// feed refresh policy: newest publication wins, then a stable payload key.
    nonisolated private static func deduplicatedEpisodes(_ episodes: [ParsedEpisode]) -> [ParsedEpisode] {
        var order: [String] = []
        var winnerByGUID: [String: ParsedEpisode] = [:]
        for episode in episodes {
            guard let current = winnerByGUID[episode.guid] else {
                order.append(episode.guid)
                winnerByGUID[episode.guid] = episode
                continue
            }
            let candidateDate = episode.pubDate ?? .distantPast
            let currentDate = current.pubDate ?? .distantPast
            if candidateDate > currentDate
                || (candidateDate == currentDate
                    && stableSignature(for: episode) < stableSignature(for: current)) {
                winnerByGUID[episode.guid] = episode
            }
        }
        return order.compactMap { winnerByGUID[$0] }
    }

    nonisolated private static func stableSignature(for episode: ParsedEpisode) -> String {
        [
            episode.audioURL,
            episode.title,
            episode.description ?? "",
            episode.artworkURL ?? "",
            episode.durationSeconds.map(String.init) ?? "",
            episode.episodeNumber.map(String.init) ?? "",
            episode.seasonNumber.map(String.init) ?? "",
            episode.chapterURL ?? "",
            episode.transcriptURL ?? "",
            episode.episodeType ?? "",
        ].joined(separator: "\u{1F}")
    }

    /// Pure: trims a feed description and collapses an empty/whitespace-only value
    /// to `nil` so the view can decide cleanly whether to render a description
    /// section at all (no empty box, no dead VoiceOver stop).
    nonisolated static func cleanedDescription(_ raw: String?) -> String? {
        // Strip HTML tags and decode entities first (some feeds emit raw markup
        // and numeric entities in the show description, #518), then collapse an
        // empty/whitespace-only result to nil so the "About" section hides.
        let stripped = EpisodeSummary.plainText(raw)
        guard !stripped.isEmpty else { return nil }
        return stripped
    }
}
