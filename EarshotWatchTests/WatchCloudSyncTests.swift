import XCTest
import SwiftData
@testable import EarshotWatch

@MainActor
final class WatchCloudSyncTests: XCTestCase {
    func testDelayedResetDiscardsCachedPreResetMaximum() {
        let old = CloudEpisodeStateProjection()
        old.positionSeconds = 100
        old.positionUpdatedAt = Date(timeIntervalSince1970: 10)
        let newer = CloudEpisodeStateProjection()
        newer.positionSeconds = 10
        newer.positionUpdatedAt = Date(timeIntervalSince1970: 30)
        let cached = WatchProgressResolution.resolve([old, newer], localPosition: 100,
                                                      localUpdatedAt: newer.positionUpdatedAt)
        XCTAssertEqual(cached.position, 100)
        newer.positionResetAt = Date(timeIntervalSince1970: 20)
        let repaired = WatchProgressResolution.resolve([old, newer], localPosition: cached.position,
                                                        localUpdatedAt: cached.updatedAt)
        XCTAssertEqual(repaired.position, 10)
    }

    func testMarkPlayedThenUnplayedRetainsExplicitResetInOutbox() throws {
        let library = try WatchLibrary(inMemory: true)
        let episode = makeEpisode()
        library.context.insert(episode)
        library.persist()
        library.markPlayed(episode, played: true)
        library.markPlayed(episode, played: false)
        let events = try library.context.fetch(FetchDescriptor<WatchPendingSyncEvent>())
        let event = try XCTUnwrap(events.first { $0.kind == "episode" })
        let payload = try JSONDecoder().decode(WatchSyncPayload.self, from: event.payload)
        XCTAssertEqual(payload.position, 0)
        XCTAssertNotNil(payload.positionResetAt)
    }

    func testBackwardPositionStagePublishesResetClock() throws {
        let library = try WatchLibrary(inMemory: true)
        let episode = makeEpisode()
        episode.positionSeconds = 40
        library.context.insert(episode)
        library.persist()
        episode.positionSeconds = 5
        library.stageListeningPosition(episode, previousPosition: 40)
        library.persist()
        let events = try library.context.fetch(FetchDescriptor<WatchPendingSyncEvent>())
        let payload = try JSONDecoder().decode(WatchSyncPayload.self,
                                                from: XCTUnwrap(events.first { $0.kind == "episode" }).payload)
        XCTAssertEqual(payload.position, 5)
        XCTAssertNotNil(payload.positionResetAt)
    }

    func testLegacyEpisodeRepairPreservesDownloadProgressAndBookmarks() throws {
        let library = try WatchLibrary(inMemory: true)
        let podcast = WatchPodcast(feedURL: "https://EXAMPLE.com/Feed", title: "Show")
        let legacy = WatchEpisode(feedURL: podcast.feedURL, guid: "one", title: "One",
                                  podcastTitle: "Show", audioURL: "https://example.com/one.mp3")
        legacy.identity = "https://example.com/feed\u{001f}one"
        legacy.positionSeconds = 123
        legacy.downloadFilename = "saved.mp3"
        let canonical = WatchEpisode(feedURL: podcast.feedURL, guid: "one", title: "One",
                                     podcastTitle: "Show", audioURL: "https://example.com/one.mp3")
        let bookmark = WatchBookmark(episode: legacy)
        library.context.insert(podcast)
        library.context.insert(legacy)
        library.context.insert(canonical)
        library.context.insert(bookmark)
        try library.context.save()

        try library.repairLegacyIdentities()
        library.reload()
        XCTAssertEqual(library.episodes.count, 1)
        XCTAssertEqual(library.episodes.first?.identity, "https://example.com/Feed\u{001f}one")
        XCTAssertEqual(library.episodes.first?.positionSeconds, 123)
        XCTAssertEqual(library.episodes.first?.downloadFilename, "saved.mp3")
        XCTAssertEqual(library.bookmarks.first?.episodeIdentity, library.episodes.first?.identity)
        XCTAssertEqual(library.podcasts.first?.feedURL, "https://example.com/Feed")
    }

    func testLegacyQueueBootstrapDoesNotOutvoteNewerRemoteRemoval() throws {
        let library = try WatchLibrary(inMemory: true)
        let episode = makeEpisode()
        episode.queuePosition = 0
        library.context.insert(episode)
        try library.context.save()
        try library.repairLegacyIdentities()
        let events = try library.context.fetch(FetchDescriptor<WatchPendingSyncEvent>())
        let event = try XCTUnwrap(events.first { $0.kind == "queue" })
        let payload = try JSONDecoder().decode(WatchSyncPayload.self, from: event.payload)
        XCTAssertTrue(payload.isQueued)
        XCTAssertEqual(payload.membershipUpdatedAt, WatchQueueResolution.legacyMembershipDate)
        let local = CloudQueueItemProjection()
        local.isQueued = true
        local.membershipUpdatedAt = payload.membershipUpdatedAt
        let remote = CloudQueueItemProjection()
        remote.isQueued = false
        remote.membershipUpdatedAt = Date(timeIntervalSince1970: 1000)
        XCTAssertFalse(try XCTUnwrap(WatchQueueResolution.membership([local, remote])).isQueued)
    }

    func testQueueShellReceivesSyncedPositionOnFirstReconcile() throws {
        let library = try WatchLibrary(inMemory: true)
        let cloud = try WatchCloudSync(library: library, inMemory: true)
        let queue = CloudQueueItemProjection()
        queue.feedURL = "https://example.com/feed"
        queue.episodeGUID = "one"
        queue.episodeTitle = "One"
        queue.episodeAudioURL = "https://example.com/one.mp3"
        queue.isQueued = true
        queue.membershipUpdatedAt = Date(timeIntervalSince1970: 100)
        let progress = CloudEpisodeStateProjection()
        progress.feedURL = queue.feedURL
        progress.episodeGUID = queue.episodeGUID
        progress.positionSeconds = 75
        progress.positionUpdatedAt = Date(timeIntervalSince1970: 110)
        try cloud.insertForTesting(queue)
        try cloud.insertForTesting(progress)
        cloud.reconcile()
        XCTAssertEqual(library.episodes.first?.positionSeconds, 75)
    }

    func testFolderTombstoneSuppressesOlderLiveRecord() {
        let live = CloudFolderProjection()
        live.folderID = "folder"
        live.modifiedAt = Date(timeIntervalSince1970: 10)
        let deleted = CloudFolderProjection()
        deleted.folderID = "folder"
        deleted.modifiedAt = Date(timeIntervalSince1970: 20)
        deleted.deletedAt = deleted.modifiedAt
        XCTAssertTrue(WatchFolderResolution.liveLatest([live, deleted]).isEmpty)
    }

    private func makeEpisode() -> WatchEpisode {
        WatchEpisode(feedURL: "https://example.com/feed", guid: "one", title: "One",
                     podcastTitle: "Show", audioURL: "https://example.com/one.mp3")
    }
}
