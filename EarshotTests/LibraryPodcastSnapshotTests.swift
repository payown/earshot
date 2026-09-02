import XCTest
@testable import Earshot

@MainActor
final class LibraryPodcastSnapshotTests: XCTestCase {
    func testProjectionIncludesEveryScalarReadByLibraryRows() {
        let properties = LibraryPodcastSnapshot.properties

        XCTAssertTrue(properties.contains(\Podcast.feedURL))
        XCTAssertTrue(properties.contains(\Podcast.title))
        XCTAssertTrue(properties.contains(\Podcast.author))
        XCTAssertTrue(properties.contains(\Podcast.podcastDescription))
        XCTAssertTrue(properties.contains(\Podcast.artworkURL))
        XCTAssertTrue(properties.contains(\Podcast.subscriptionStateRaw))
        XCTAssertTrue(properties.contains(\Podcast.autoQueue))
        XCTAssertTrue(properties.contains(\Podcast.notificationEnabled))
        XCTAssertTrue(properties.contains(\Podcast.inboxExcluded))
        XCTAssertTrue(properties.contains(\Podcast.inboxIncluded))
        XCTAssertTrue(properties.contains(\Podcast.createdAt))
        XCTAssertTrue(properties.contains(\Podcast.lastSeenPubDate))
        XCTAssertEqual(properties.count, 12, "The Library projection must remain scalar-only and exact")
    }

    func testProjectionDoesNotFetchEpisodeRelationship() {
        XCTAssertFalse(LibraryPodcastSnapshot.properties.contains(\Podcast.episodes))
    }
}
