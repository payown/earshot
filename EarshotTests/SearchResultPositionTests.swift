import XCTest
@testable import Earshot

/// Tests for the once-per-search directory count announcement. Individual rows
/// deliberately omit repeated "result N of M" speech to stay concise.
final class SearchResultPositionTests: XCTestCase {

    @MainActor
    func testDirectoryLibraryIndexPreservesCanonicalFirstMatchAndMetadata() {
        let first = Podcast(feedURL: "HTTPS://Example.COM:443/feed#fragment", title: "First")
        let duplicate = Podcast(feedURL: "https://example.com/feed", title: "Duplicate", podcastDescription: "Later description")
        let index = DirectoryPodcastLibraryIndex(podcasts: [first, duplicate])
        XCTAssertTrue(index.podcast(forFeedURL: "https://example.com/feed") === first)
        XCTAssertNil(index.podcast(forFeedURL: "https://example.com/other"))
        XCTAssertNil(index.podcast(forFeedURL: first.feedURL)?.podcastDescription)
        first.podcastDescription = "Updated metadata"
        XCTAssertEqual(index.podcast(forFeedURL: first.feedURL)?.podcastDescription, "Updated metadata")
        let afterUnfollow = DirectoryPodcastLibraryIndex(podcasts: [duplicate])
        XCTAssertTrue(afterUnfollow.podcast(forFeedURL: first.feedURL) === duplicate)
        XCTAssertNil(DirectoryPodcastLibraryIndex(podcasts: []).podcast(forFeedURL: first.feedURL))
    }

    @MainActor
    func testDirectoryLibraryIndexMatchesLegacyLookupForExpandedSearch() {
        let podcasts = (0..<1000).map { Podcast(feedURL: "https://library.example/\($0).xml", title: "Library \($0)") }
        let results = (0..<200).map { index in
            index.isMultiple(of: 2)
                ? "HTTPS://Library.EXAMPLE:443/\(index).xml#directory"
                : "https://other.example/\(index).xml"
        }
        let start = Date()
        let legacy = results.map { url in podcasts.first { FeedURLIdentity.matches($0.feedURL, url) } }
        let legacySeconds = Date().timeIntervalSince(start)
        let indexStart = Date()
        let index = DirectoryPodcastLibraryIndex(podcasts: podcasts)
        let actual = results.map { index.podcast(forFeedURL: $0) }
        let indexedSeconds = Date().timeIntervalSince(indexStart)
        for (expected, actual) in zip(legacy, actual) {
            XCTAssertTrue(expected === actual)
        }
        XCTAssertEqual(actual.compactMap { $0 }.count, 100)
        print("Directory lookup simulator diagnostic: legacy=\(legacySeconds)s indexed=\(indexedSeconds)s, 1000 library / 200 results")
    }

    /// A multi-result count is pluralised: "50 directory results".
    func testCountAnnouncementPlural() {
        XCTAssertEqual(SearchResultPosition.countAnnouncement(50), "50 directory results")
        XCTAssertEqual(SearchResultPosition.countAnnouncement(2), "2 directory results")
    }

    /// Exactly one result reads in the singular: "1 directory result".
    func testCountAnnouncementSingular() {
        XCTAssertEqual(SearchResultPosition.countAnnouncement(1), "1 directory result")
    }

    /// Zero (the empty case is announced separately, but the helper must still be
    /// well-formed) reads as the plural "0 directory results".
    func testCountAnnouncementZeroIsPlural() {
        XCTAssertEqual(SearchResultPosition.countAnnouncement(0), "0 directory results")
    }
}
