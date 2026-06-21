import Foundation
import SwiftData

/// Abstraction over feed fetching so the repository can be tested without
/// hitting the network. ``FeedService`` is the production implementation.
///
/// `Sendable` because the `@MainActor` repository calls `fetch(_:)` (a
/// `nonisolated async` requirement), which sends the conformer off the main
/// actor. All conformers are value types whose stored state is Sendable.
protocol FeedFetching: Sendable {
    func fetch(_ urlString: String) async throws -> ParsedFeed
}

// `@unchecked Sendable` because `FeedFetching` now refines `Sendable` and the
// conformance lives here rather than in FeedService.swift (the compiler requires
// the Sendable conformance in the declaring file otherwise). It is safe:
// `FeedService` is a value-type struct whose only stored property (`HTTPClient`,
// itself a value type wrapping a Sendable `URLSession`) is Sendable.
extension FeedService: @unchecked Sendable, FeedFetching {}

/// Owns subscribe and refresh logic for podcasts. Views call into this instead
/// of touching the model graph directly.
@MainActor
final class SubscriptionRepository {
    private let context: ModelContext
    private let feed: FeedFetching

    init(context: ModelContext, feed: FeedFetching = FeedService()) {
        self.context = context
        self.feed = feed
    }

    /// Subscribes to a feed URL. If already subscribed, returns the existing
    /// podcast. The existing backlog is pre-dismissed from the inbox and the
    /// high-water mark is set to the newest episode, so subscribing never floods
    /// the inbox — only episodes published after this point surface later.
    @discardableResult
    func subscribe(feedURL: String) async throws -> Podcast {
        let trimmed = feedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = podcast(forFeedURL: trimmed) { return existing }

        let parsed = try await feed.fetch(trimmed)
        let podcast = Podcast(
            feedURL: trimmed,
            title: parsed.title.isEmpty ? "Untitled podcast" : parsed.title,
            author: parsed.author,
            podcastDescription: parsed.description,
            artworkURL: parsed.artworkURL,
            websiteURL: parsed.websiteURL,
            language: parsed.language,
            category: parsed.category
        )
        context.insert(podcast)

        var newest: Date?
        for item in parsed.episodes {
            let episode = makeEpisode(from: item)
            episode.podcast = podcast
            episode.inboxDismissed = true // pre-dismiss backlog on subscribe
            context.insert(episode)
            newest = laterOf(newest, item.pubDate)
        }
        podcast.lastSeenPubDate = newest
        podcast.refreshedAt = .now
        try context.save()
        AppLog.subscriptions.info("Subscribed to \(podcast.title, privacy: .public) with \(parsed.episodes.count) episodes")
        return podcast
    }

    /// Re-fetches a feed and inserts only episodes not already present (by guid).
    /// Episodes newer than the high-water mark surface in the inbox; older ones
    /// are pre-dismissed. The high-water mark then advances to the newest seen.
    func refresh(_ podcast: Podcast) async throws {
        let parsed = try await feed.fetch(podcast.feedURL)
        let existingGUIDs = Set(podcast.episodes.map(\.guid))
        let mark = podcast.lastSeenPubDate
        var newest = mark
        var added = 0

        for item in parsed.episodes where !existingGUIDs.contains(item.guid) {
            let episode = makeEpisode(from: item)
            episode.podcast = podcast
            let isNew = (item.pubDate ?? .distantPast) > (mark ?? .distantPast)
            episode.inboxDismissed = !isNew
            context.insert(episode)
            newest = laterOf(newest, item.pubDate)
            added += 1
        }

        podcast.lastSeenPubDate = newest
        podcast.refreshedAt = .now
        try context.save()
        if added > 0 {
            AppLog.subscriptions.info("Refreshed \(podcast.title, privacy: .public): \(added) new episode(s)")
        }
    }

    /// Refreshes every subscription, logging and continuing past individual
    /// failures so one bad feed doesn't abort the rest.
    func refreshAll() async {
        let all = (try? context.fetch(FetchDescriptor<Podcast>())) ?? []
        for podcast in all {
            do {
                try await refresh(podcast)
            } catch {
                AppLog.subscriptions.error("Refresh failed for \(podcast.title, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: Helpers

    private func podcast(forFeedURL url: String) -> Podcast? {
        var descriptor = FetchDescriptor<Podcast>(predicate: #Predicate { $0.feedURL == url })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    private func makeEpisode(from item: ParsedEpisode) -> Episode {
        Episode(
            guid: item.guid,
            title: item.title,
            audioURL: item.audioURL,
            episodeDescription: item.description,
            durationSeconds: item.durationSeconds,
            pubDate: item.pubDate,
            artworkURL: item.artworkURL,
            episodeNumber: item.episodeNumber,
            seasonNumber: item.seasonNumber,
            chapterURL: item.chapterURL,
            transcriptURL: item.transcriptURL
        )
    }

    private func laterOf(_ a: Date?, _ b: Date?) -> Date? {
        switch (a, b) {
        case let (x?, y?): return max(x, y)
        case let (x?, nil): return x
        case let (nil, y?): return y
        case (nil, nil): return nil
        }
    }
}
