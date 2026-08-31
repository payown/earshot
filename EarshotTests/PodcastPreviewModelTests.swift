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

    // MARK: availableEpisodes (pure)

    func testAvailableEpisodesAreNewestFirstAndNotCapped() {
        // Deliberately out of order. Every publisher-feed episode is retained.
        let feed = parsedFeed([
            parsedEpisode("a", d1),
            parsedEpisode("c", d3),
            parsedEpisode("b", d2),
        ])

        let available = PodcastPreviewModel.availableEpisodes(from: feed)

        XCTAssertEqual(available.map(\.id), ["c", "b", "a"])
    }

    func testAvailableEpisodesUndatedSortLast() {
        let feed = parsedFeed([
            parsedEpisode("dated", d2),
            parsedEpisode("undated", nil),
        ])

        let available = PodcastPreviewModel.availableEpisodes(from: feed)

        XCTAssertEqual(available.first?.id, "dated", "A dated episode outranks an undated one")
        XCTAssertEqual(available.count, 2)
    }

    func testAvailableEpisodesCarryDurationAndDate() {
        let feed = parsedFeed([parsedEpisode("a", d1, duration: 3600)])
        let available = PodcastPreviewModel.availableEpisodes(from: feed)
        XCTAssertEqual(available.first?.durationSeconds, 3600)
        XCTAssertEqual(available.first?.pubDate, d1)
    }

    func testAvailableEpisodesCarryAudioURLAndStreamFields() {
        // #517: the enclosure URL (plus description, artwork, chapters) must reach
        // the PreviewEpisode so the preview row can stream without subscribing.
        let parsed = ParsedEpisode(
            guid: "g", title: "Ep g", audioURL: "https://x/g.mp3",
            description: "Show notes", pubDate: d1, durationSeconds: 1200,
            artworkURL: "https://x/art.jpg", episodeNumber: nil, seasonNumber: nil,
            chapterURL: "https://x/chapters.json", transcriptURL: nil
        )
        let available = PodcastPreviewModel.availableEpisodes(from: parsedFeed([parsed]))

        let first = available.first
        XCTAssertEqual(first?.audioURL, "https://x/g.mp3")
        XCTAssertEqual(first?.episodeDescription, "Show notes")
        XCTAssertEqual(first?.artworkURL, "https://x/art.jpg")
        XCTAssertEqual(first?.chapterURL, "https://x/chapters.json")
        XCTAssertEqual(first?.searchableDescription, "Show notes")
    }

    func testAvailableEpisodesUseDeterministicTieBreaks() {
        let feed = parsedFeed([
            parsedEpisode("z-guid", d1),
            ParsedEpisode(
                guid: "a-guid", title: "Alpha", audioURL: "https://x/a.mp3",
                description: nil, pubDate: d1, durationSeconds: nil, artworkURL: nil,
                episodeNumber: nil, seasonNumber: nil, chapterURL: nil, transcriptURL: nil
            ),
            ParsedEpisode(
                guid: "b-guid", title: "Alpha", audioURL: "https://x/b.mp3",
                description: nil, pubDate: d1, durationSeconds: nil, artworkURL: nil,
                episodeNumber: nil, seasonNumber: nil, chapterURL: nil, transcriptURL: nil
            ),
        ])

        XCTAssertEqual(
            PodcastPreviewModel.availableEpisodes(from: feed).map(\.id),
            ["a-guid", "b-guid", "z-guid"]
        )
    }

    func testAvailableEpisodesDeduplicateGUIDForStableRowIdentity() {
        let older = ParsedEpisode(
            guid: "duplicate", title: "Older copy", audioURL: "https://x/old.mp3",
            description: nil, pubDate: d1, durationSeconds: nil, artworkURL: nil,
            episodeNumber: nil, seasonNumber: nil, chapterURL: nil, transcriptURL: nil
        )
        let newer = ParsedEpisode(
            guid: "duplicate", title: "Newer copy", audioURL: "https://x/new.mp3",
            description: nil, pubDate: d2, durationSeconds: nil, artworkURL: nil,
            episodeNumber: nil, seasonNumber: nil, chapterURL: nil, transcriptURL: nil
        )

        let available = PodcastPreviewModel.availableEpisodes(from: parsedFeed([older, newer]))

        XCTAssertEqual(available.count, 1)
        XCTAssertEqual(available.first?.id, "duplicate")
        XCTAssertEqual(available.first?.title, "Newer copy")
    }

    func testAvailableEpisodeDeduplicationIsStableWhenFeedOrderReverses() {
        let first = ParsedEpisode(
            guid: "duplicate", title: "Zulu", audioURL: "https://x/z.mp3",
            description: nil, pubDate: d1, durationSeconds: nil, artworkURL: nil,
            episodeNumber: nil, seasonNumber: nil, chapterURL: nil, transcriptURL: nil
        )
        let second = ParsedEpisode(
            guid: "duplicate", title: "Alpha", audioURL: "https://x/a.mp3",
            description: nil, pubDate: d1, durationSeconds: nil, artworkURL: nil,
            episodeNumber: nil, seasonNumber: nil, chapterURL: nil, transcriptURL: nil
        )

        let forward = PodcastPreviewModel.availableEpisodes(from: parsedFeed([first, second]))
        let reversed = PodcastPreviewModel.availableEpisodes(from: parsedFeed([second, first]))

        XCTAssertEqual(forward, reversed)
        XCTAssertEqual(forward.first?.title, "Alpha")
    }

    // MARK: Preview sort and search (pure)

    func testOldestFirstSortKeepsUndatedEpisodesLast() {
        let episodes = PodcastPreviewModel.availableEpisodes(from: parsedFeed([
            parsedEpisode("new", d3), parsedEpisode("undated", nil), parsedEpisode("old", d1),
        ]))

        XCTAssertEqual(
            PreviewEpisodeSortOrder.oldestFirst.sorted(episodes).map(\.id),
            ["old", "new", "undated"]
        )
    }

    func testPreviewSearchMatchesTitleCaseAndDiacriticInsensitively() {
        let episodes = PodcastPreviewModel.availableEpisodes(from: parsedFeed([
            ParsedEpisode(
                guid: "one", title: "Café stories", audioURL: "https://x/one.mp3",
                description: nil, pubDate: d1, durationSeconds: nil, artworkURL: nil,
                episodeNumber: nil, seasonNumber: nil, chapterURL: nil, transcriptURL: nil
            ),
        ]))

        XCTAssertEqual(PreviewEpisodeSearchFilter.filter(episodes, query: "  CAFE ").map(\.id), ["one"])
    }

    func testPreviewSearchMatchesPlainTextDescription() {
        let parsed = ParsedEpisode(
            guid: "one", title: "Different title", audioURL: "https://x/one.mp3",
            description: "<p>Investigating <strong>oceanography</strong>.</p>", pubDate: d1,
            durationSeconds: nil, artworkURL: nil, episodeNumber: nil, seasonNumber: nil,
            chapterURL: nil, transcriptURL: nil
        )
        let episodes = PodcastPreviewModel.availableEpisodes(from: parsedFeed([parsed]))

        XCTAssertEqual(PreviewEpisodeSearchFilter.filter(episodes, query: "OCEANOGRAPHY").map(\.id), ["one"])
    }

    func testInactivePreviewSearchPreservesAllEpisodesAndOrder() {
        let episodes = PodcastPreviewModel.availableEpisodes(from: parsedFeed([
            parsedEpisode("new", d3), parsedEpisode("old", d1),
        ]))

        XCTAssertEqual(PreviewEpisodeSearchFilter.filter(episodes, query: "  \n"), episodes)
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

    func testLoadPublishesDescriptionAndAvailableEpisodes() async {
        let feed = parsedFeed(
            [parsedEpisode("a", d1), parsedEpisode("b", d2)],
            description: "A great show"
        )
        let model = PodcastPreviewModel(feed: StubFeedFetcher(.success(feed)))

        await model.load(feedURL: "https://x/feed.xml")

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
