import XCTest
@testable import Earshot

/// Covers the pure follow/unfollow toggle text and the podcast-preview view-model
/// logic introduced for #499 (Activate opens a preview; Follow is a real toggle).
@MainActor
final class PodcastPreviewModelTests: XCTestCase {

    private let d1 = Date(timeIntervalSince1970: 1_700_000_000)
    private let d2 = Date(timeIntervalSince1970: 1_700_100_000)
    private let d3 = Date(timeIntervalSince1970: 1_700_200_000)

    private func parsedEpisode(_ guid: String, _ date: Date?, duration: Int? = nil) -> ParsedEpisode {
        ParsedEpisode(
            guid: guid, title: "Ep \(guid)", audioURL: "https://x/\(guid).mp3",
            description: nil, pubDate: date, durationSeconds: duration, artworkURL: nil,
            episodeNumber: nil, seasonNumber: nil, chapterURL: nil, transcriptURL: nil
        )
    }

    private func parsedFeed(_ episodes: [ParsedEpisode], description: String? = nil) -> ParsedFeed {
        ParsedFeed(
            title: "Show", artworkURL: nil, description: description, author: "Host",
            websiteURL: nil, language: nil, category: nil, episodes: episodes
        )
    }

    // MARK: FollowToggle (pure)

    func testActionLabelFollowsCurrentState() {
        XCTAssertEqual(FollowToggle.actionLabel(subscribed: false), "Follow")
        XCTAssertEqual(FollowToggle.actionLabel(subscribed: true), "Unfollow")
    }

    func testAnnouncementDescribesNewState() {
        XCTAssertEqual(
            FollowToggle.announcement(nowFollowing: true, title: "Reply All"),
            "Now following Reply All"
        )
        XCTAssertEqual(
            FollowToggle.announcement(nowFollowing: false, title: "Reply All"),
            "Unfollowed Reply All"
        )
    }

    // MARK: recentEpisodes (pure)

    func testRecentEpisodesAreNewestFirstAndCapped() {
        // Deliberately out of order; expect d3, d2, d1 after sort, capped at 2.
        let feed = parsedFeed([
            parsedEpisode("a", d1),
            parsedEpisode("c", d3),
            parsedEpisode("b", d2),
        ])

        let recent = PodcastPreviewModel.recentEpisodes(from: feed, limit: 2)

        XCTAssertEqual(recent.map(\.id), ["c", "b"], "Newest first, limited to 2")
    }

    func testRecentEpisodesUndatedSortLast() {
        let feed = parsedFeed([
            parsedEpisode("dated", d2),
            parsedEpisode("undated", nil),
        ])

        let recent = PodcastPreviewModel.recentEpisodes(from: feed, limit: 5)

        XCTAssertEqual(recent.first?.id, "dated", "A dated episode outranks an undated one")
        XCTAssertEqual(recent.count, 2)
    }

    func testRecentEpisodesLimitZeroReturnsNone() {
        let feed = parsedFeed([parsedEpisode("a", d1)])
        XCTAssertTrue(PodcastPreviewModel.recentEpisodes(from: feed, limit: 0).isEmpty)
    }

    func testRecentEpisodesCarryDurationAndDate() {
        let feed = parsedFeed([parsedEpisode("a", d1, duration: 3600)])
        let recent = PodcastPreviewModel.recentEpisodes(from: feed, limit: 5)
        XCTAssertEqual(recent.first?.durationSeconds, 3600)
        XCTAssertEqual(recent.first?.pubDate, d1)
    }

    // MARK: cleanedDescription (pure)

    func testCleanedDescriptionTrimsAndNilsEmpty() {
        XCTAssertEqual(PodcastPreviewModel.cleanedDescription("  Hello  "), "Hello")
        XCTAssertNil(PodcastPreviewModel.cleanedDescription("   \n  "))
        XCTAssertNil(PodcastPreviewModel.cleanedDescription(nil))
    }

    func testCleanedDescriptionStripsTagsAndEntities() {
        // Raw markup plus a numeric entity (#518): tags removed, entity decoded.
        XCTAssertEqual(
            PodcastPreviewModel.cleanedDescription("<p>Not That &amp; That&#8217;s it</p>"),
            "Not That & That\u{2019}s it"
        )
    }

    func testCleanedDescriptionTagsOnlyYieldsNil() {
        // A description that is only markup/whitespace collapses to nil so the
        // preview "About" section hides cleanly.
        XCTAssertNil(PodcastPreviewModel.cleanedDescription("<p></p>"))
        XCTAssertNil(PodcastPreviewModel.cleanedDescription("<br/> \n <span></span>"))
    }

    // MARK: load() state transitions

    func testLoadPublishesDescriptionAndRecentEpisodes() async {
        let feed = parsedFeed(
            [parsedEpisode("a", d1), parsedEpisode("b", d2)],
            description: "A great show"
        )
        let model = PodcastPreviewModel(feed: StubFeedFetcher(.success(feed)))

        await model.load(feedURL: "https://x/feed.xml", recentLimit: 5)

        guard case let .loaded(description, episodes) = model.state else {
            return XCTFail("Expected loaded state, got \(model.state)")
        }
        XCTAssertEqual(description, "A great show")
        XCTAssertEqual(episodes.map(\.id), ["b", "a"])
    }

    func testLoadFailureSetsFailedState() async {
        let model = PodcastPreviewModel(feed: StubFeedFetcher(.failure(FeedError.parse)))

        await model.load(feedURL: "https://x/feed.xml")

        XCTAssertEqual(model.state, .failed)
    }
}

/// Returns a fixed feed or throws a fixed error, without any network. `@unchecked
/// Sendable` to satisfy `FeedFetching`'s `Sendable` refinement; it is only read.
private struct StubFeedFetcher: FeedFetching, @unchecked Sendable {
    enum Outcome {
        case success(ParsedFeed)
        case failure(Error)
    }
    let outcome: Outcome
    init(_ outcome: Outcome) { self.outcome = outcome }

    func fetch(_ urlString: String) async throws -> ParsedFeed {
        switch outcome {
        case let .success(feed): return feed
        case let .failure(error): throw error
        }
    }
}
