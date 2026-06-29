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
    let id: String
    let title: String
    let pubDate: Date?
    let durationSeconds: Int?
}

/// Drives the podcast preview: fetches an UN-subscribed feed once via
/// ``FeedFetching`` (the same abstraction the subscribe flow uses) and exposes the
/// show description plus a few recent episodes so a user — VoiceOver or sighted —
/// can read about a show before deciding to follow it (#499).
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

    /// Fetches and parses the feed, then publishes the description and the newest
    /// `recentLimit` episodes. Never throws — a failure is folded into `.failed`
    /// (logged) so the view can offer a retry. Safe to call again (retry).
    func load(feedURL: String, recentLimit: Int = 5) async {
        state = .loading
        do {
            let parsed = try await feed.fetch(feedURL)
            state = .loaded(
                description: Self.cleanedDescription(parsed.description),
                episodes: Self.recentEpisodes(from: parsed, limit: recentLimit)
            )
        } catch {
            AppLog.networking.error(
                "Podcast preview feed load failed for \(feedURL, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            state = .failed
        }
    }

    /// Pure: the newest `limit` episodes of a parsed feed, newest-first, mapped to
    /// read-only ``PreviewEpisode`` values. Tested without any network.
    static func recentEpisodes(from feed: ParsedFeed, limit: Int) -> [PreviewEpisode] {
        feed.episodes
            .sorted { ($0.pubDate ?? .distantPast) > ($1.pubDate ?? .distantPast) }
            .prefix(max(0, limit))
            .map {
                PreviewEpisode(
                    id: $0.guid,
                    title: $0.title,
                    pubDate: $0.pubDate,
                    durationSeconds: $0.durationSeconds
                )
            }
    }

    /// Pure: trims a feed description and collapses an empty/whitespace-only value
    /// to `nil` so the view can decide cleanly whether to render a description
    /// section at all (no empty box, no dead VoiceOver stop).
    static func cleanedDescription(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
