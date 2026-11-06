import XCTest
import SwiftData
@testable import EarshotWatch

final class EarshotWatchTests: XCTestCase {
    func testSharedRSSParserProvidesWatchPlaybackIdentity() {
        let xml = """
        <rss><channel><title>Sample</title><item><guid>episode-1</guid><title>First</title>
        <enclosure url="https://example.com/one.mp3" type="audio/mpeg" /></item></channel></rss>
        """
        let feed = RSSParser().parse(Data(xml.utf8))
        XCTAssertEqual(feed?.title, "Sample")
        XCTAssertEqual(feed?.episodes.first?.audioURL, "https://example.com/one.mp3")
        XCTAssertEqual(WatchEpisode.key(feedURL: "https://example.com/feed", guid: "episode-1"), "https://example.com/feed\u{001f}episode-1")
        XCTAssertEqual(WatchEpisode.key(feedURL: "HTTPS://EXAMPLE.COM:443/Feed?ID=One#section", guid: "episode-1"),
                       "https://example.com/Feed?ID=One\u{001f}episode-1")
    }

    func testDownloadRejectsPublisherErrorPageEvenWithHTTP200() throws {
        let response = try XCTUnwrap(HTTPURLResponse(url: URL(string: "https://example.com/audio.mp3")!, statusCode: 200,
                                                 httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/html"]))
        XCTAssertFalse(WatchDownloadValidation.accepts(response: response, byteCount: 200))
    }

    func testDownloadKeepsMediaExtensionForOfflinePlayback() {
        let filename = WatchDownloadValidation.filename(for: URL(string: "https://example.com/episode.m4a")!,
                                                         id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        XCTAssertEqual(filename, "00000000-0000-0000-0000-000000000001.m4a")
    }

    func testDownloadReserveUsesFreeSpaceAfterTemporaryTransfer() {
        XCTAssertFalse(WatchStoragePolicy.hasReserve(availableBytes: 10 * 1_024 * 1_024))
        XCTAssertTrue(WatchStoragePolicy.hasReserve(availableBytes: 100 * 1_024 * 1_024))
    }

    func testCloudProgressKeepsNewerOfflineProgress() {
        let older = CloudEpisodeStateProjection()
        older.positionSeconds = 120
        older.positionUpdatedAt = Date(timeIntervalSince1970: 100)
        let newer = CloudEpisodeStateProjection()
        newer.positionSeconds = 360
        newer.positionUpdatedAt = Date(timeIntervalSince1970: 200)
        let result = WatchProgressResolution.resolve([older, newer], localPosition: 240,
                                                     localUpdatedAt: Date(timeIntervalSince1970: 150))
        XCTAssertEqual(result.position, 360)
    }

    func testCloudProgressRespectsExplicitBackwardSeek() {
        let old = CloudEpisodeStateProjection()
        old.positionSeconds = 600
        old.positionUpdatedAt = Date(timeIntervalSince1970: 100)
        let reset = CloudEpisodeStateProjection()
        reset.positionSeconds = 30
        reset.positionUpdatedAt = Date(timeIntervalSince1970: 300)
        reset.positionResetAt = Date(timeIntervalSince1970: 300)
        let result = WatchProgressResolution.resolve([old, reset], localPosition: 600,
                                                     localUpdatedAt: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(result.position, 30)
    }

    func testQueueRemovalWinsOverStaleOfflineReorder() {
        let staleReorder = CloudQueueItemProjection()
        staleReorder.sourceDeviceID = "watch"
        staleReorder.isQueued = true
        staleReorder.membershipUpdatedAt = Date(timeIntervalSince1970: 100)
        staleReorder.modifiedAt = Date(timeIntervalSince1970: 300)
        let removal = CloudQueueItemProjection()
        removal.sourceDeviceID = "phone"
        removal.isQueued = false
        removal.membershipUpdatedAt = Date(timeIntervalSince1970: 200)
        removal.modifiedAt = Date(timeIntervalSince1970: 200)
        XCTAssertEqual(WatchQueueResolution.membership([staleReorder, removal])?.isQueued, false)
    }

    func testLegacyQueueMembershipUsesModifiedTimestamp() {
        let legacy = CloudQueueItemProjection()
        legacy.isQueued = true
        legacy.modifiedAt = Date(timeIntervalSince1970: 200)
        let older = CloudQueueItemProjection()
        older.isQueued = false
        older.membershipUpdatedAt = Date(timeIntervalSince1970: 100)
        older.modifiedAt = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(WatchQueueResolution.membership([legacy, older])?.isQueued, true)
    }

    func testOfflineFileIsChosenEvenWhenFeedAudioAddressExpired() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".mp3")
        try Data([0x49, 0x44, 0x33]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(WatchPlaybackSource.choose(local: file, remoteAddress: "expired"), file)
    }

    func testPlayerReplacesStreamWithNewlyDownloadedFileForOfflineResume() {
        let remote = URL(string: "https://example.com/episode.mp3")!
        let local = URL(fileURLWithPath: "/tmp/episode.mp3")
        XCTAssertTrue(WatchPlaybackSource.needsReplacement(currentURL: remote, chosenURL: local,
                                                          currentIdentity: "episode", chosenIdentity: "episode"))
        XCTAssertFalse(WatchPlaybackSource.needsReplacement(currentURL: local, chosenURL: local,
                                                           currentIdentity: "episode", chosenIdentity: "episode"))
    }

    @MainActor
    func testOfflineOutboxPublishesWithoutUsingProductionCloud() throws {
        let library = try WatchLibrary(inMemory: true)
        let payload = WatchSyncPayload(feedURL: "https://example.com/feed", guid: "offline-1",
                                       position: 42, positionUpdatedAt: Date(timeIntervalSince1970: 200))
        let event = WatchPendingSyncEvent(key: "episode:offline-1", kind: "episode",
                                          payload: try JSONEncoder().encode(payload))
        library.context.insert(event)
        try library.context.save()
        let sync = try WatchCloudSync(library: library, inMemory: true)
        sync.reconcile()
        XCTAssertNil(sync.lastError)
        XCTAssertEqual(try sync.episodeContributionCountForTesting(), 1)
        XCTAssertEqual(try library.context.fetchCount(FetchDescriptor<WatchPendingSyncEvent>()), 0)
    }

    func testHandoffRejectsStaleOrUnacknowledgedPhoneState() {
        let good: [String: Any] = ["owner": "phone", "accepted": true, "playing": true,
                                   "feedURL": "https://example.com/feed", "guid": "one"]
        XCTAssertTrue(WatchHandoffDecision.phoneConfirmed(good, feedURL: "https://example.com/feed", guid: "one"))
        var stale = good
        stale["guid"] = "two"
        XCTAssertFalse(WatchHandoffDecision.phoneConfirmed(stale, feedURL: "https://example.com/feed", guid: "one"))
        var rejected = good
        rejected["accepted"] = false
        XCTAssertFalse(WatchHandoffDecision.phoneConfirmed(rejected, feedURL: "https://example.com/feed", guid: "one"))
    }

    @MainActor
    func testOfflineQueueEditsAndBookmarksRemainInOutbox() throws {
        let library = try WatchLibrary(inMemory: true)
        let first = try XCTUnwrap(library.playablePhoneEpisode(feedURL: "https://example.com/feed", guid: "one",
                                                               title: "One", podcastTitle: "Show", audioURL: "https://example.com/one.mp3"))
        let second = try XCTUnwrap(library.playablePhoneEpisode(feedURL: "https://example.com/feed", guid: "two",
                                                                title: "Two", podcastTitle: "Show", audioURL: "https://example.com/two.mp3"))
        library.enqueue(first, next: false)
        library.enqueue(second, next: true)
        XCTAssertEqual(library.queue.map(\.guid), ["two", "one"])
        library.moveQueue(first, offset: -1)
        XCTAssertEqual(library.queue.map(\.guid), ["one", "two"])
        library.removeFromQueue(first, announce: false)
        XCTAssertEqual(library.queue.map(\.guid), ["two"])
        second.positionSeconds = 75
        library.addBookmark(second)
        XCTAssertEqual(library.bookmarks.first?.positionSeconds, 75)
        let pending = try library.context.fetch(FetchDescriptor<WatchPendingSyncEvent>())
        XCTAssertTrue(pending.contains { $0.kind == "queue" })
        XCTAssertTrue(pending.contains { $0.kind == "bookmark" })
    }

    @MainActor
    func testLocalPlayedAndInboxEditsAreDurableUntilSync() throws {
        let library = try WatchLibrary(inMemory: true)
        let episode = try XCTUnwrap(library.playablePhoneEpisode(feedURL: "https://example.com/feed", guid: "one",
                                                                 title: "One", podcastTitle: "Show", audioURL: "https://example.com/one.mp3"))
        library.markPlayed(episode, played: true)
        XCTAssertTrue(episode.isPlayed)
        library.markPlayed(episode, played: false)
        XCTAssertFalse(episode.isPlayed)
        library.dismissFromInbox(episode)
        XCTAssertTrue(episode.inboxDismissed)
        let pending = try library.context.fetch(FetchDescriptor<WatchPendingSyncEvent>())
        let state = try XCTUnwrap(pending.first { $0.kind == "episode" })
        let payload = try JSONDecoder().decode(WatchSyncPayload.self, from: state.payload)
        XCTAssertFalse(payload.isPlayed)
        XCTAssertTrue(payload.inboxDismissed)
    }
}
