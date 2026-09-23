import XCTest
import SwiftData
@testable import Earshot

@MainActor
final class DownloadEpisodeSnapshotTests: XCTestCase {
    func testUnchangedKeysDoNotResolveAgainButSameCountReplacementDoes() throws {
        let context = TestStore.freshContext()
        let snapshot = DownloadEpisodeSnapshot()
        let first = EpisodeLocalKey(feedURL: "https://example.com/feed", guid: "one")
        let second = EpisodeLocalKey(feedURL: "https://example.com/feed", guid: "two")
        var resolutions = 0
        let resolve: ([EpisodeLocalKey], ModelContext) throws -> [EpisodeLocalKey: Episode] = { _, _ in
            resolutions += 1
            return [:]
        }
        snapshot.reload(keys: [first], context: context, resolve: resolve)
        for _ in 0..<100 {
            snapshot.reload(keys: [first], context: context, resolve: resolve)
            XCTAssertTrue(snapshot.episodes.isEmpty)
        }
        XCTAssertEqual(resolutions, 1)
        snapshot.reload(keys: [second], context: context, resolve: resolve)
        XCTAssertEqual(resolutions, 2)
        snapshot.reload(keys: [second], context: context, force: true, resolve: resolve)
        XCTAssertEqual(resolutions, 3)
    }

    func testResolvesCompositeKeysAndRefreshesAfterDeletion() throws {
        let context = TestStore.freshContext()
        let snapshot = DownloadEpisodeSnapshot()
        var keys: [EpisodeLocalKey] = []
        var episodes: [Episode] = []
        for name in ["one", "two"] {
            let podcast = Podcast(feedURL: "https://example.com/\(name)", title: name)
            context.insert(podcast)
            let episode = Episode(guid: "same-guid", title: name, audioURL: "https://example.com/audio")
            context.insert(episode)
            episode.podcast = podcast
            keys.append(EpisodeLocalKey(feedURL: podcast.feedURL, guid: episode.guid))
            episodes.append(episode)
        }
        try context.save()
        snapshot.reload(keys: keys, context: context)
        XCTAssertEqual(snapshot.episodes.map(\.persistentModelID), episodes.map(\.persistentModelID))
        context.delete(episodes[0])
        try context.save()
        snapshot.reload(keys: keys, context: context, force: true)
        XCTAssertEqual(snapshot.episodes.map(\.persistentModelID), [episodes[1].persistentModelID])
        snapshot.reload(keys: [], context: context)
        XCTAssertTrue(snapshot.episodes.isEmpty)
    }

    func testFailedRefreshCannotRetainRemovedDownloadMembership() throws {
        enum Failure: Error { case store }
        let context = TestStore.freshContext()
        let podcast = Podcast(feedURL: "https://example.com/feed", title: "Show")
        context.insert(podcast)
        let episode = Episode(guid: "one", title: "One", audioURL: "https://example.com/audio")
        context.insert(episode)
        episode.podcast = podcast
        try context.save()
        let key = EpisodeLocalKey(feedURL: podcast.feedURL, guid: episode.guid)
        let snapshot = DownloadEpisodeSnapshot()
        snapshot.reload(keys: [key], context: context)
        XCTAssertEqual(snapshot.episodes.count, 1)
        snapshot.reload(keys: [], context: context, resolve: { _, _ in throw Failure.store })
        XCTAssertTrue(snapshot.episodes.isEmpty)
        // Restoring membership after failure resolves the episode again.
        snapshot.reload(keys: [key], context: context)
        XCTAssertEqual(snapshot.episodes.count, 1)
    }

    func testFailedResolutionCanRetryIdenticalKeys() {
        enum Failure: Error { case store }
        let context = TestStore.freshContext()
        let snapshot = DownloadEpisodeSnapshot()
        let keys = [EpisodeLocalKey(feedURL: "https://example.com/feed", guid: "one")]
        var attempts = 0
        let resolve: ([EpisodeLocalKey], ModelContext) throws -> [EpisodeLocalKey: Episode] = { _, _ in
            attempts += 1
            if attempts == 1 { throw Failure.store }
            return [:]
        }
        snapshot.reload(keys: keys, context: context, resolve: resolve)
        snapshot.reload(keys: keys, context: context, resolve: resolve)
        snapshot.reload(keys: keys, context: context, resolve: resolve)
        XCTAssertEqual(attempts, 2)
    }
}
