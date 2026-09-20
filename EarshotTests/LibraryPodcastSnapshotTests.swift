import SwiftData
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

@MainActor
final class LibraryUnplayedCountsTests: XCTestCase {
    func testCountsMatchEpisodeScreenAndRefreshAfterPlayedChanges() async throws {
        let context = TestStore.freshContext()
        let show = Podcast(feedURL: "https://example.com/counts", title: "Counts")
        let empty = Podcast(feedURL: "https://example.com/empty", title: "Empty")
        context.insert(show)
        context.insert(empty)
        var episodes: [Episode] = []
        for index in 0..<8 {
            let episode = Episode(guid: "count-\(index)", title: "Episode", audioURL: "https://example.com/audio.mp3")
            episode.podcast = show
            if index < 3 { episode.isPlayed = true }
            context.insert(episode)
            episodes.append(episode)
        }
        let other = Episode(guid: "other", title: "Unrelated", audioURL: "https://example.com/other.mp3")
        context.insert(other)
        try context.save()
        let ids = [show.persistentModelID, empty.persistentModelID]
        var counts = try await LibraryUnplayedCounts.load(container: context.container, podcastIDs: ids)
        let source = EpisodeListDataSource(context: context, podcastID: show.persistentModelID, podcastTitle: show.title)
        source.resetAndLoad(filter: .unheard, sort: .latestFirst, searchText: "")
        XCTAssertEqual(counts[show.persistentModelID], 5)
        XCTAssertEqual(counts[show.persistentModelID], source.unplayedCount)
        XCTAssertEqual(counts[empty.persistentModelID], 0)
        XCTAssertEqual(counts.count, 2)

        episodes[3].isPlayed = true
        try context.save()
        counts = try await LibraryUnplayedCounts.load(container: context.container, podcastIDs: ids)
        XCTAssertEqual(counts[show.persistentModelID], 4)
        episodes[0].isPlayed = false
        try context.save()
        counts = try await LibraryUnplayedCounts.load(container: context.container, podcastIDs: ids)
        XCTAssertEqual(counts[show.persistentModelID], 5)
    }

    func testCountWordingAndExistingRowDetails() {
        XCTAssertEqual(PodcastRowSpeech.label(title: "Sawbones", author: nil, isReadOnly: false, unplayedCount: 12), "Sawbones, 12 unplayed episodes")
        XCTAssertEqual(PodcastRowSpeech.label(title: "Show", author: "Author", isReadOnly: true, unplayedCount: 1), "Show, 1 unplayed episode, Author, Read-only, upgrade to Earshot Plus to make changes")
        XCTAssertEqual(PodcastRowSpeech.label(title: "Show", author: nil, isReadOnly: false, unplayedCount: 0), "Show, 0 unplayed episodes")
        XCTAssertEqual(PodcastRowSpeech.label(title: "Show", author: "Author", isReadOnly: false), "Show, Author")
    }

    func testCancelledRequestDoesNotPublishAResult() async throws {
        let context = TestStore.freshContext()
        let task = Task { try await LibraryUnplayedCounts.load(container: context.container, podcastIDs: []) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled snapshot must be discarded")
        } catch is CancellationError { }
    }
}
