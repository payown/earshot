import XCTest
import SwiftData
@testable import EarshotWatch

@MainActor
final class WatchCloudSyncTests: XCTestCase {
    private let queueSettingDefaults = [
        "watchKeepFinishedEpisodesInQueue",
        "watchKeepFinishedQueueSettingDate",
        "watchKeepFinishedQueueSettingSource"
    ]

    private func withCleanQueueSetting(_ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let previous = queueSettingDefaults.map { defaults.object(forKey: $0) }
        queueSettingDefaults.forEach(defaults.removeObject(forKey:))
        defer {
            for (key, value) in zip(queueSettingDefaults, previous) {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        try body()
    }

    func testKeepFinishedQueueBooleanImportsAndKeepsNewestOfflineValue() throws {
        try withCleanQueueSetting {
            let library = try WatchLibrary(inMemory: true)
            XCTAssertFalse(library.keepFinishedEpisodesInQueue)
            let cloud = try WatchCloudSync(library: library, inMemory: true)
            let enabled = CloudSettingProjection()
            enabled.key = "keep_finished_episodes_in_queue"
            enabled.value = "true"
            enabled.sourceDeviceID = "phone-A"
            enabled.modifiedAt = Date(timeIntervalSince1970: 200)
            try cloud.insertForTesting(enabled)
            cloud.reconcile()
            XCTAssertTrue(library.keepFinishedEpisodesInQueue)
            XCTAssertTrue(try WatchLibrary(inMemory: true).keepFinishedEpisodesInQueue,
                          "The last synced phone value must survive offline relaunch")

            let delayed = CloudSettingProjection()
            delayed.key = enabled.key
            delayed.value = "false"
            delayed.sourceDeviceID = "phone-B"
            delayed.modifiedAt = Date(timeIntervalSince1970: 100)
            try cloud.insertForTesting(delayed)
            cloud.reconcile()
            XCTAssertTrue(library.keepFinishedEpisodesInQueue)

            enabled.value = "false"
            enabled.modifiedAt = Date(timeIntervalSince1970: 300)
            cloud.reconcile()
            XCTAssertFalse(library.keepFinishedEpisodesInQueue)
            XCTAssertFalse(try WatchLibrary(inMemory: true).keepFinishedEpisodesInQueue)
        }
    }

    func testBooleanParserRejectsUnknownSettingsWithoutChangingOtherPreferences() {
        XCTAssertEqual(WatchSettingResolution.boolean("true"), true)
        XCTAssertEqual(WatchSettingResolution.boolean("false"), false)
        XCTAssertEqual(WatchSettingResolution.boolean("1"), true)
        XCTAssertEqual(WatchSettingResolution.boolean("0"), false)
        XCTAssertNil(WatchSettingResolution.boolean("maybe"))
    }

    func testManualPlayedQueueRetentionStagesPlayedAndMembershipTogether() throws {
        try withCleanQueueSetting {
            let library = try WatchLibrary(inMemory: true)
            let episode = makeEpisode()
            library.context.insert(episode)
            library.persist()
            library.enqueue(episode, next: false)
            library.markPlayed(episode, played: true)
            XCTAssertTrue(episode.isPlayed)
            XCTAssertNil(episode.queuePosition)
            let events = try library.context.fetch(FetchDescriptor<WatchPendingSyncEvent>())
            XCTAssertTrue(events.contains { $0.kind == "episode" })
            let removal = try XCTUnwrap(events.first { $0.kind == "queue" })
            XCTAssertFalse(try JSONDecoder().decode(WatchSyncPayload.self, from: removal.payload).isQueued)

            library.markPlayed(episode, played: false)
            XCTAssertFalse(episode.isPlayed)
            XCTAssertNil(episode.queuePosition, "Mark Unplayed must not silently requeue")

            library.applyKeepFinishedQueueSetting(true, modifiedAt: .now, sourceDeviceID: "phone")
            library.enqueue(episode, next: false)
            library.markPlayed(episode, played: true)
            XCTAssertTrue(episode.isPlayed)
            XCTAssertEqual(episode.queuePosition, 0)
            let retained = try library.context.fetch(FetchDescriptor<WatchPendingSyncEvent>())
            XCTAssertTrue(try JSONDecoder().decode(WatchSyncPayload.self,
                from: XCTUnwrap(retained.first { $0.kind == "queue" }).payload).isQueued)
        }
    }

    func testNaturalCompletionUsesLastKnownPreferenceAndKeepsFinalPosition() throws {
        try withCleanQueueSetting {
            let library = try WatchLibrary(inMemory: true)
            let episode = makeEpisode()
            library.context.insert(episode)
            library.persist()
            library.enqueue(episode, next: false)
            library.finishPlayback(episode, at: 125)
            XCTAssertTrue(episode.isPlayed)
            XCTAssertEqual(episode.positionSeconds, 125)
            XCTAssertNil(episode.queuePosition)

            library.markPlayed(episode, played: false)
            library.applyKeepFinishedQueueSetting(true, modifiedAt: .now, sourceDeviceID: "phone")
            library.enqueue(episode, next: false)
            library.finishPlayback(episode, at: 180)
            XCTAssertTrue(episode.isPlayed)
            XCTAssertEqual(episode.positionSeconds, 180)
            XCTAssertEqual(episode.queuePosition, 0)
        }
    }

    func testOfflinePlayedRemovalCannotOutvoteLaterPhoneRequeueOrRemoval() throws {
        try withCleanQueueSetting {
            let library = try WatchLibrary(inMemory: true)
            let episode = makeEpisode()
            library.context.insert(episode)
            library.persist()
            library.enqueue(episode, next: false)
            library.markPlayed(episode, played: true)
            XCTAssertNil(episode.queuePosition)

            let cloud = try WatchCloudSync(library: library, inMemory: true)
            cloud.reconcile() // flush the durable offline removal first
            XCTAssertNil(episode.queuePosition)

            let newerPhone = CloudQueueItemProjection()
            newerPhone.feedURL = episode.feedURL
            newerPhone.episodeGUID = episode.guid
            newerPhone.sourceDeviceID = "phone"
            newerPhone.isQueued = true
            newerPhone.position = 0
            newerPhone.membershipUpdatedAt = Date.now.addingTimeInterval(60)
            newerPhone.modifiedAt = newerPhone.membershipUpdatedAt
            try cloud.insertForTesting(newerPhone)
            cloud.reconcile()
            XCTAssertEqual(library.queue.map(\.identity), [episode.identity],
                           "A later explicit phone requeue must win without clearing Played")
            XCTAssertTrue(episode.isPlayed)
            cloud.reconcile()
            XCTAssertEqual(library.queue.count, 1, "Repeated import must not duplicate the entry")

            newerPhone.isQueued = false
            newerPhone.membershipUpdatedAt = newerPhone.membershipUpdatedAt.addingTimeInterval(60)
            newerPhone.modifiedAt = newerPhone.membershipUpdatedAt
            cloud.reconcile()
            XCTAssertTrue(library.queue.isEmpty, "A still newer phone removal must win")
            XCTAssertTrue(episode.isPlayed)
        }
    }

    func testOfflinePlayedRemovalAndOutboxSurviveWatchRelaunch() throws {
        try withCleanQueueSetting {
            let directory = FileManager.default.temporaryDirectory
                .appending(path: "watch-played-queue-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = directory.appending(path: "WatchLocal.store")
            do {
                let library = try WatchLibrary(storeURL: store)
                let episode = makeEpisode()
                library.context.insert(episode)
                library.persist()
                library.enqueue(episode, next: false)
                library.markPlayed(episode, played: true)
                XCTAssertTrue(library.queue.isEmpty)
            }
            let reopened = try WatchLibrary(storeURL: store)
            let episode = try XCTUnwrap(reopened.episodes.first)
            XCTAssertTrue(episode.isPlayed)
            XCTAssertNil(episode.queuePosition)
            let events = try reopened.context.fetch(FetchDescriptor<WatchPendingSyncEvent>())
            XCTAssertEqual(Set(events.map(\.kind)), ["episode", "queue"])
        }
    }

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
