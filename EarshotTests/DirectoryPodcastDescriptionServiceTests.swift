import XCTest
@testable import Earshot

final class DirectoryPodcastDescriptionServiceTests: XCTestCase {
    func testPolicyRequiresVoiceOverAndAnEnabledDescriptionMode() {
        XCTAssertFalse(DirectoryPodcastDescriptionPolicy.shouldLoad(
            voiceOverEnabled: false, mode: .brief
        ))
        XCTAssertFalse(DirectoryPodcastDescriptionPolicy.shouldLoad(
            voiceOverEnabled: true, mode: .off
        ))
        XCTAssertTrue(DirectoryPodcastDescriptionPolicy.shouldLoad(
            voiceOverEnabled: true, mode: .brief
        ))
        XCTAssertTrue(DirectoryPodcastDescriptionPolicy.shouldLoad(
            voiceOverEnabled: true, mode: .full
        ))
    }

    func testLoadsDescriptionsAndCachesMissingValues() async {
        let feed = DirectoryDescriptionFeedStub(descriptions: [
            "https://one.example/feed": "First description",
        ])
        let service = DirectoryPodcastDescriptionService(feed: feed)

        let first = await service.descriptions(for: [
            "https://one.example/feed", "https://two.example/feed",
        ])
        let second = await service.descriptions(for: [
            "https://one.example/feed", "https://two.example/feed",
        ])

        XCTAssertEqual(first, ["https://one.example/feed": "First description"])
        XCTAssertEqual(second, first)
        let counts = await feed.requestCounts
        XCTAssertEqual(counts["https://one.example/feed"], 1)
        XCTAssertEqual(counts["https://two.example/feed"], 1)
    }

    func testDeduplicatesCanonicalFeedURLs() async {
        let feed = DirectoryDescriptionFeedStub(descriptions: [
            "https://example.com/feed": "Description",
        ])
        let service = DirectoryPodcastDescriptionService(feed: feed)

        let descriptions = await service.descriptions(for: [
            "HTTPS://Example.COM:443/feed#top",
            "https://example.com/feed",
        ])

        XCTAssertEqual(descriptions, ["https://example.com/feed": "Description"])
        let counts = await feed.requestCounts
        XCTAssertEqual(counts["https://example.com/feed"], 1)
    }

    func testTransientFailuresAreRetriedInsteadOfCachedAsMissing() async {
        let feed = DirectoryDescriptionFeedStub(
            descriptions: [:],
            failingURLs: ["https://offline.example/feed"]
        )
        let service = DirectoryPodcastDescriptionService(feed: feed)

        _ = await service.descriptions(for: ["https://offline.example/feed"])
        _ = await service.descriptions(for: ["https://offline.example/feed"])

        let counts = await feed.requestCounts
        XCTAssertEqual(counts["https://offline.example/feed"], 2)
    }

    func testFeedDownloadsRespectConcurrencyLimit() async {
        let urls = (1...8).map { "https://\($0).example/feed" }
        let feed = DirectoryDescriptionFeedStub(
            descriptions: Dictionary(uniqueKeysWithValues: urls.map { ($0, "Description") }),
            delayNanoseconds: 20_000_000
        )
        let service = DirectoryPodcastDescriptionService(feed: feed)

        _ = await service.descriptions(for: urls, maximumConcurrent: 3)

        let maximum = await feed.maximumActiveRequests
        XCTAssertEqual(maximum, 3)
    }
}

private actor DirectoryDescriptionFeedStub: FeedFetching {
    let descriptions: [String: String]
    let failingURLs: Set<String>
    let delayNanoseconds: UInt64
    private(set) var requestCounts: [String: Int] = [:]
    private(set) var maximumActiveRequests = 0
    private var activeRequests = 0

    init(
        descriptions: [String: String],
        failingURLs: Set<String> = [],
        delayNanoseconds: UInt64 = 0
    ) {
        self.descriptions = descriptions
        self.failingURLs = failingURLs
        self.delayNanoseconds = delayNanoseconds
    }

    func fetch(_ urlString: String) async throws -> ParsedFeed {
        requestCounts[urlString, default: 0] += 1
        activeRequests += 1
        maximumActiveRequests = max(maximumActiveRequests, activeRequests)
        defer { activeRequests -= 1 }
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        if failingURLs.contains(urlString) { throw URLError(.notConnectedToInternet) }
        return ParsedFeed(
            title: "Show",
            artworkURL: nil,
            description: descriptions[urlString],
            author: nil,
            websiteURL: nil,
            language: nil,
            category: nil,
            episodes: []
        )
    }
}
