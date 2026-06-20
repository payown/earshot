import XCTest
import SwiftData
@testable import Earshot

private final class FakeFeedFetcher: FeedFetching {
    var feed: ParsedFeed
    init(_ feed: ParsedFeed) { self.feed = feed }
    func fetch(_ urlString: String) async throws -> ParsedFeed { feed }
}

@MainActor
final class SubscriptionRepositoryTests: XCTestCase {

    private let d1 = Date(timeIntervalSince1970: 1_700_000_000)
    private let d2 = Date(timeIntervalSince1970: 1_700_100_000)
    private let d3 = Date(timeIntervalSince1970: 1_700_200_000)

    private func episode(_ guid: String, _ date: Date) -> ParsedEpisode {
        ParsedEpisode(
            guid: guid, title: "Ep \(guid)", audioURL: "https://x/\(guid).mp3",
            description: nil, pubDate: date, durationSeconds: nil, artworkURL: nil,
            episodeNumber: nil, seasonNumber: nil, chapterURL: nil, transcriptURL: nil
        )
    }

    private func feed(_ episodes: [ParsedEpisode]) -> ParsedFeed {
        ParsedFeed(
            title: "Show", artworkURL: nil, description: nil, author: "Host",
            websiteURL: nil, language: nil, category: nil, episodes: episodes
        )
    }

    func testSubscribeCreatesPodcastAndPreDismissesBacklog() async throws {
        let ctx = TestStore.freshContext()
        let fetcher = FakeFeedFetcher(feed([episode("a", d1), episode("b", d2)]))
        let repo = SubscriptionRepository(context: ctx, feed: fetcher)

        let podcast = try await repo.subscribe(feedURL: "https://x/feed.xml")

        XCTAssertEqual(podcast.episodes.count, 2)
        XCTAssertTrue(podcast.episodes.allSatisfy { $0.inboxDismissed })
        XCTAssertEqual(podcast.lastSeenPubDate, d2)
        XCTAssertEqual(podcast.author, "Host")
    }

    func testSubscribeTwiceReturnsExistingWithoutDuplicates() async throws {
        let ctx = TestStore.freshContext()
        let fetcher = FakeFeedFetcher(feed([episode("a", d1)]))
        let repo = SubscriptionRepository(context: ctx, feed: fetcher)

        let first = try await repo.subscribe(feedURL: "https://x/feed.xml")
        let second = try await repo.subscribe(feedURL: "https://x/feed.xml")

        XCTAssertEqual(first.persistentModelID, second.persistentModelID)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Podcast>()).count, 1)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Episode>()).count, 1)
    }

    func testRefreshAddsOnlyNewEpisodesAndSurfacesThemInInbox() async throws {
        let ctx = TestStore.freshContext()
        let fetcher = FakeFeedFetcher(feed([episode("a", d1), episode("b", d2)]))
        let repo = SubscriptionRepository(context: ctx, feed: fetcher)
        let podcast = try await repo.subscribe(feedURL: "https://x/feed.xml")

        // Feed gains a newer episode "c" at d3.
        fetcher.feed = feed([episode("a", d1), episode("b", d2), episode("c", d3)])
        try await repo.refresh(podcast)

        XCTAssertEqual(podcast.episodes.count, 3)
        let c = try XCTUnwrap(podcast.episodes.first { $0.guid == "c" })
        XCTAssertFalse(c.inboxDismissed) // newer than the mark -> inbox
        XCTAssertEqual(podcast.lastSeenPubDate, d3)
    }

    func testRefreshIsIdempotentWhenNoNewEpisodes() async throws {
        let ctx = TestStore.freshContext()
        let fetcher = FakeFeedFetcher(feed([episode("a", d1)]))
        let repo = SubscriptionRepository(context: ctx, feed: fetcher)
        let podcast = try await repo.subscribe(feedURL: "https://x/feed.xml")

        try await repo.refresh(podcast)
        XCTAssertEqual(podcast.episodes.count, 1)
    }
}
