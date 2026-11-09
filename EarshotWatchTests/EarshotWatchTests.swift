import XCTest
import SwiftData
import WatchConnectivity
@testable import EarshotWatch

final class EarshotWatchTests: XCTestCase {
    func testMagicTapRetainsWatchOwnershipAndUsesLatestPausedContinuation() {
        func choose(watchPlaying: Bool = false, watchEpisode: Bool = true,
                    watchOwns: Bool = false, watchAt: Double? = 100,
                    phoneLive: Bool = true, phonePlaying: Bool = false,
                    phoneEpisode: Bool = true, phoneAt: Double? = 110,
                    phoneScreen: Bool = false, watchScreen: Bool = false) -> WatchMagicTapTarget {
            WatchMagicTapTarget.choose(watchIsPlaying: watchPlaying, watchHasEpisode: watchEpisode,
                                       watchOwnsPlayback: watchOwns, watchCheckpoint: watchAt,
                                       phoneIsLive: phoneLive, phoneIsPlaying: phonePlaying,
                                       phoneHasEpisode: phoneEpisode,
                                       phoneContinuationCheckpoint: phoneAt,
                                       phoneControlScreen: phoneScreen,
                                       watchControlScreen: watchScreen)
        }
        XCTAssertEqual(choose(watchPlaying: true, phonePlaying: true), .watch)
        XCTAssertEqual(choose(watchOwns: true, phonePlaying: true), .none)
        XCTAssertEqual(choose(watchOwns: true, watchAt: 120), .watch)
        XCTAssertEqual(choose(watchOwns: true, watchAt: 100), .continuePhoneOnWatch)
        XCTAssertEqual(choose(phonePlaying: true), .phone)
        XCTAssertEqual(choose(), .continuePhoneOnWatch)
        XCTAssertEqual(choose(phoneLive: false), .continuePhoneOnWatch)
        XCTAssertEqual(choose(watchAt: 120), .watch)
        XCTAssertEqual(choose(watchEpisode: false, phoneLive: false), .continuePhoneOnWatch)
        XCTAssertEqual(choose(watchEpisode: false, phoneLive: false, phonePlaying: true),
                       .continuePhoneOnWatch)
        XCTAssertEqual(choose(watchEpisode: false, phoneEpisode: false, phoneAt: nil), .none)
        XCTAssertEqual(choose(watchPlaying: true, phonePlaying: true, phoneScreen: true), .phone)
        XCTAssertEqual(choose(phoneLive: false, phoneScreen: true), .none)
        XCTAssertEqual(choose(phonePlaying: true, watchScreen: true), .none)
        XCTAssertEqual(choose(watchEpisode: false, phonePlaying: true, watchScreen: true), .none)
        XCTAssertEqual(choose(watchEpisode: false, phoneLive: false,
                              phonePlaying: true, watchScreen: true), .continuePhoneOnWatch)
    }

    func testReachableStalePhoneStateAndOppositeDeviceRequireTransferConfirmation() {
        XCTAssertTrue(WatchPlaybackCompetitionPolicy.watchNeedsPhoneConfirmation(
            phoneReachable: true, phoneReportedPlaying: true, watchPlaying: false))
        XCTAssertFalse(WatchPlaybackCompetitionPolicy.watchNeedsPhoneConfirmation(
            phoneReachable: false, phoneReportedPlaying: true, watchPlaying: false))
        XCTAssertFalse(WatchPlaybackCompetitionPolicy.watchNeedsPhoneConfirmation(
            phoneReachable: true, phoneReportedPlaying: true, watchPlaying: true))
        XCTAssertTrue(WatchPlaybackCompetitionPolicy.phonePlayNeedsTransfer(
            watchPlaying: true, phonePlaying: false))
        XCTAssertFalse(WatchPlaybackCompetitionPolicy.phonePlayNeedsTransfer(
            watchPlaying: true, phonePlaying: true))
    }

    func testLateSeekCannotClearOrPublishOverNewerSeek() {
        var gate = WatchSeekGate()
        let first = gate.begin()
        XCTAssertTrue(gate.isPending)
        let second = gate.begin()
        XCTAssertFalse(gate.finish(first))
        XCTAssertTrue(gate.isPending)
        XCTAssertTrue(gate.finish(second))
        XCTAssertFalse(gate.isPending)
        let canceled = gate.begin()
        gate.invalidate()
        XCTAssertFalse(gate.finish(canceled))
    }

    @MainActor
    func testPhoneContinuationPersistsZeroSeekAndRejectsStaleDuplicateAndInvalidMedia() throws {
        let suite = "WatchContinuationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WatchContinuationStore(defaults: defaults)
        func state(position: Double, changedAt: Double, observedAt: Double,
                   audioURL: String = "https://example.com/one.mp3") -> PairedPlaybackState {
            PairedPlaybackState(owner: .phone, feedURL: "https://example.com/feed", guid: "one",
                                title: "One", podcastTitle: "Show", audioURL: audioURL,
                                position: position, playing: false, observedAt: observedAt,
                                playbackChangedAt: changedAt)
        }
        XCTAssertTrue(store.accept(state(position: 125, changedAt: 100, observedAt: 101)))
        XCTAssertFalse(store.accept(state(position: 130, changedAt: 99, observedAt: 110)))
        XCTAssertFalse(store.accept(state(position: 125, changedAt: 100, observedAt: 120)))
        XCTAssertTrue(store.accept(state(position: 0, changedAt: 121, observedAt: 122)))
        XCTAssertEqual(WatchContinuationStore(defaults: defaults).latest?.state.position, 0)
        XCTAssertFalse(store.accept(state(position: 99, changedAt: 123, observedAt: 124,
                                      audioURL: "file:///tmp/untrusted.mp3")))
        XCTAssertEqual(store.latest?.state.position, 0)
        XCTAssertTrue(store.latest?.isNewerThanWatch(Date(timeIntervalSince1970: 100)) == true)
        XCTAssertFalse(store.latest?.isNewerThanWatch(Date(timeIntervalSince1970: 130)) == true)
    }

    func testPlaybackChangeCheckpointDoesNotAdvanceForTransportRefresh() {
        let first = PairedPlaybackState(owner: .phone, feedURL: "https://example.com/feed",
                                         guid: "one", title: "One", audioURL: "https://example.com/one.mp3",
                                         position: 50, observedAt: 100, playbackChangedAt: 100)
        let duplicate = PairedPlaybackState(owner: .phone, feedURL: first.feedURL,
                                             guid: first.guid, title: first.title,
                                             audioURL: first.audioURL, position: 50,
                                             observedAt: 120, playbackChangedAt: 100)
        XCTAssertFalse(duplicate.hasPlaybackChange(comparedWith: first))
        let rewind = PairedPlaybackState(owner: .phone, feedURL: first.feedURL,
                                          guid: first.guid, title: first.title,
                                          audioURL: first.audioURL, position: 0,
                                          observedAt: 121, playbackChangedAt: 121)
        XCTAssertTrue(rewind.hasPlaybackChange(comparedWith: duplicate))
    }

    func testContinuationPrefersCompletedDownloadAndRejectsUnusableMediaAddress() throws {
        let local = FileManager.default.temporaryDirectory.appending(path: "watch-audio-\(UUID().uuidString).mp3")
        try Data([0, 1, 2]).write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }
        let expiredRemote = "https://example.com/expired.mp3?expires=1"
        XCTAssertEqual(WatchPlaybackSource.choose(local: local, remoteAddress: expiredRemote), local)
        XCTAssertEqual(WatchPlaybackSource.choose(local: nil, remoteAddress: expiredRemote)?.scheme, "https")
        XCTAssertNil(WatchPlaybackSource.choose(local: nil, remoteAddress: "file:///tmp/invalid.mp3"))
        XCTAssertNil(WatchPlaybackSource.choose(local: nil, remoteAddress: ""))
    }

    func testPausedPhoneReplyAcceptsZeroAndRejectsLateOrChangedPlayback() throws {
        let saved = try XCTUnwrap(WatchContinuation(PairedPlaybackState(
            owner: .phone, feedURL: "https://example.com/feed", guid: "one", title: "One",
            audioURL: "https://example.com/one.mp3", position: 60, playing: false,
            observedAt: 100, playbackChangedAt: 100)))
        var reply: [String: Any] = ["accepted": true, "owner": "phone", "playing": false,
                                     "feedURL": saved.state.feedURL, "guid": saved.state.guid,
                                     "title": saved.state.title, "audioURL": saved.state.audioURL,
                                     "position": 0.0, "rate": 1.0,
                                     "observedAt": 120.0, "playbackChangedAt": 120.0]
        XCTAssertEqual(WatchContinuationReply.pausedCandidate(reply, matching: saved,
                                                                 latest: saved, now: 121)?.state.position, 0)
        reply["playbackChangedAt"] = 90.0
        XCTAssertNil(WatchContinuationReply.pausedCandidate(reply, matching: saved,
                                                               latest: saved, now: 121))
        reply["playbackChangedAt"] = 120.0
        reply["guid"] = "other"
        XCTAssertNil(WatchContinuationReply.pausedCandidate(reply, matching: saved,
                                                               latest: saved, now: 121))
        reply["guid"] = "one"
        reply["playing"] = true
        XCTAssertNil(WatchContinuationReply.pausedCandidate(reply, matching: saved,
                                                               latest: saved, now: 121))
        reply["playing"] = false
        XCTAssertNil(WatchContinuationReply.pausedCandidate(reply, matching: saved,
                                                               latest: saved, now: 170))
    }

    @MainActor
    func testOlderPhoneSnapshotRequestIsRejectedBeforeOpeningWatchLibrary() async {
        let answered = expectation(description: "Older phone receives a queue snapshot rejection")
        let control = WatchPhoneControl()
        control.session(
            WCSession.default,
            didReceiveMessage: ["version": 1, "id": UUID().uuidString,
                                "command": "queueSnapshot", "offset": 0]
        ) { response in
            XCTAssertEqual(response["accepted"] as? Bool, false)
            XCTAssertEqual(response["reason"] as? String, "Paired Queue refresh is unavailable")
            answered.fulfill()
        }
        await fulfillment(of: [answered], timeout: 2)
    }

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
                                   "audioReady": true,
                                   "feedURL": "https://example.com/feed", "guid": "one"]
        XCTAssertTrue(WatchHandoffDecision.phoneConfirmed(good, feedURL: "https://example.com/feed", guid: "one"))
        var stale = good
        stale["guid"] = "two"
        XCTAssertFalse(WatchHandoffDecision.phoneConfirmed(stale, feedURL: "https://example.com/feed", guid: "one"))
        var rejected = good
        rejected["accepted"] = false
        XCTAssertFalse(WatchHandoffDecision.phoneConfirmed(rejected, feedURL: "https://example.com/feed", guid: "one"))
        var buffering = good
        buffering["audioReady"] = false
        XCTAssertFalse(WatchHandoffDecision.phoneConfirmed(buffering, feedURL: "https://example.com/feed", guid: "one"))
    }

    func testHandoffConfirmationCannotPauseNewerWatchRequest() {
        var gate = WatchPlaybackRequestGate()
        let source = gate.begin()
        XCTAssertTrue(WatchHandoffDecision.mayPauseWatch(
            requestOwned: gate.owns(source), identity: "one", expectedIdentity: "one"))
        gate.begin()
        XCTAssertFalse(WatchHandoffDecision.mayPauseWatch(
            requestOwned: gate.owns(source), identity: "one", expectedIdentity: "one"))
        XCTAssertFalse(WatchHandoffDecision.mayPauseWatch(
            requestOwned: true, identity: "two", expectedIdentity: "one"))
    }

    func testRestoredPlaybackUsesReconciledPositionUntilItemLoads() {
        XCTAssertEqual(WatchResumePosition.select(hasLoadedItem: false, cached: 120, persisted: 600), 600)
        XCTAssertEqual(WatchResumePosition.select(hasLoadedItem: true, cached: 120, persisted: 600), 120)
    }

    func testCompletedEpisodeCannotAutoAdvanceAfterNewRequestOrPause() {
        var gate = WatchPlaybackRequestGate()
        gate.invalidate()
        let completion = gate.current
        gate.invalidate()
        XCTAssertFalse(gate.owns(completion))
        let nextCompletion = gate.current
        gate.begin()
        XCTAssertFalse(gate.owns(nextCompletion))
    }

    @MainActor
    func testLifecycleWithoutPlaybackPreservesReconciledPosition() throws {
        let library = try WatchLibrary(inMemory: true)
        let episode = try XCTUnwrap(library.playablePhoneEpisode(feedURL: "https://example.com/feed", guid: "one",
            title: "One", podcastTitle: "Show", audioURL: "https://example.com/one.mp3"))
        episode.positionSeconds = 120
        library.persist()
        let player = WatchPlayer(library: library)
        episode.positionSeconds = 600
        player.saveForLifecycle()
        XCTAssertEqual(episode.positionSeconds, 600)
    }

    @MainActor
    func testPhoneDownloadRequestRefreshesExistingSignedAudioAddress() throws {
        let library = try WatchLibrary(inMemory: true)
        let old = try XCTUnwrap(library.playablePhoneEpisode(feedURL: "https://example.com/feed", guid: "one",
            title: "One", podcastTitle: "Show", audioURL: "https://example.com/one.mp3?token=old"))
        let refreshed = try XCTUnwrap(library.playablePhoneEpisode(feedURL: old.feedURL, guid: old.guid,
            title: old.title, podcastTitle: old.podcastTitle,
            audioURL: "https://example.com/one.mp3?token=new"))
        XCTAssertTrue(old === refreshed)
        XCTAssertEqual(refreshed.audioURL, "https://example.com/one.mp3?token=new")
    }

    func testExpiredWidgetSnapshotReloadsWithSameContent() {
        let now = Date(timeIntervalSince1970: 100_000)
        XCTAssertFalse(WatchWidgetSnapshot.shouldReload(changed: false,
            previousUpdate: now.addingTimeInterval(-60), now: now))
        XCTAssertTrue(WatchWidgetSnapshot.shouldReload(changed: false,
            previousUpdate: now.addingTimeInterval(-25 * 60 * 60), now: now))
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
    func testPairedQueueExchangeAddsReordersAndRemovesBothWays() throws {
        let phone = try WatchLibrary(inMemory: true)
        let watch = try WatchLibrary(inMemory: true)
        let phoneSync = try WatchCloudSync(library: phone, inMemory: true, deviceID: "phone")
        let watchSync = try WatchCloudSync(library: watch, inMemory: true, deviceID: "watch")
        let one = try XCTUnwrap(phone.playablePhoneEpisode(feedURL: "https://example.com/feed", guid: "one",
                                                             title: "One", podcastTitle: "Example Show",
                                                             audioURL: "https://example.com/one.mp3"))
        let two = try XCTUnwrap(phone.playablePhoneEpisode(feedURL: "https://example.com/feed", guid: "two",
                                                             title: "Two", podcastTitle: "Example Show",
                                                             audioURL: "https://example.com/two.mp3"))
        phone.enqueue(one, next: false)
        phone.enqueue(two, next: false)
        let original = try phoneSync.queueContributions()
        try watchSync.acceptQueueContributions(original)
        XCTAssertEqual(watch.queue.map(\.guid), ["one", "two"])
        XCTAssertEqual(watch.queue.map(\.podcastTitle), ["Example Show", "Example Show"])

        let watchTwo = try XCTUnwrap(watch.queue.first { $0.guid == "two" })
        let watchOne = try XCTUnwrap(watch.queue.first { $0.guid == "one" })
        watch.moveQueue(watchTwo, offset: -1)
        watch.removeFromQueue(watchOne, announce: false)
        let changed = try watchSync.queueContributions()
        try phoneSync.acceptQueueContributions(changed)
        XCTAssertEqual(phone.queue.map(\.guid), ["two"])
        try watchSync.acceptQueueContributions(original) // Delayed duplicate cannot revive One.
        XCTAssertEqual(watch.queue.map(\.guid), ["two"])
    }

    @MainActor
    func testPairedQueueExchangeMergesSimultaneousOfflineAddsDeterministically() throws {
        let first = try WatchLibrary(inMemory: true)
        let second = try WatchLibrary(inMemory: true)
        let firstSync = try WatchCloudSync(library: first, inMemory: true, deviceID: "first")
        let secondSync = try WatchCloudSync(library: second, inMemory: true, deviceID: "second")
        let a = try XCTUnwrap(first.playablePhoneEpisode(feedURL: "https://example.com/feed", guid: "a",
                                                          title: "A", podcastTitle: "Show",
                                                          audioURL: "https://example.com/a.mp3"))
        let b = try XCTUnwrap(second.playablePhoneEpisode(feedURL: "https://example.com/feed", guid: "b",
                                                           title: "B", podcastTitle: "Show",
                                                           audioURL: "https://example.com/b.mp3"))
        first.enqueue(a, next: false)
        second.enqueue(b, next: false)
        let firstRows = try firstSync.queueContributions()
        let secondRows = try secondSync.queueContributions()
        try firstSync.acceptQueueContributions(secondRows)
        try secondSync.acceptQueueContributions(firstRows)
        XCTAssertEqual(first.queue.map(\.guid), ["a", "b"])
        XCTAssertEqual(second.queue.map(\.guid), ["a", "b"])
        try firstSync.acceptQueueContributions(secondRows)
        XCTAssertEqual(first.queue.map(\.guid), ["a", "b"])
    }

    @MainActor
    func testOfflineQueueAndOutboxSurviveWatchLibraryReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "watch-queue-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appending(path: "WatchLocal.sqlite")
        do {
            let library = try WatchLibrary(storeURL: store)
            let episode = try XCTUnwrap(library.playablePhoneEpisode(feedURL: "https://example.com/feed",
                                                                      guid: "offline", title: "Offline",
                                                                      podcastTitle: "Show",
                                                                      audioURL: "https://example.com/offline.mp3"))
            library.enqueue(episode, next: false)
            XCTAssertEqual(library.queue.map(\.guid), ["offline"])
        }
        let reopened = try WatchLibrary(storeURL: store)
        XCTAssertEqual(reopened.queue.map(\.guid), ["offline"])
        XCTAssertEqual(try reopened.context.fetch(FetchDescriptor<WatchPendingSyncEvent>())
            .filter { $0.kind == "queue" }.count, 1)
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
    func testStorageReserveDoesNotRequireDownloadSizeTwice() {
        XCTAssertTrue(WatchStoragePolicy.hasReserve(availableBytes: 100 * 1_024 * 1_024))
        XCTAssertFalse(WatchStoragePolicy.hasReserve(availableBytes: 40 * 1_024 * 1_024))
        XCTAssertTrue(WatchStoragePolicy.hasReserve(availableBytes: 0))
    }

    func testNewPlaybackRequestInvalidatesEarlierStartup() {
        var requests = WatchPlaybackRequestGate()
        let first = requests.begin()
        let second = requests.begin()
        XCTAssertFalse(requests.owns(first))
        XCTAssertTrue(requests.owns(second))
        requests.invalidate()
        XCTAssertFalse(requests.owns(second))
    }

    func testShortcutDestinationCanBeConsumedAfterHomeIsAlreadyMounted() {
        let suite = "WatchNavigationRequestTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        WatchNavigationRequest.openNowPlaying(defaults: defaults)
        XCTAssertTrue(WatchNavigationRequest.consumeNowPlaying(defaults: defaults))
        XCTAssertFalse(WatchNavigationRequest.consumeNowPlaying(defaults: defaults))
    }

    func testSpokenPlaybackDeviceReflectsPausedAndTransferredStates() {
        XCTAssertEqual(WatchPlaybackDeviceStatus.spokenText(watchPlaying: true, phonePlaying: false),
                       "Audio is playing on Apple Watch")
        XCTAssertEqual(WatchPlaybackDeviceStatus.spokenText(watchPlaying: false, phonePlaying: false),
                       "Audio is paused on Apple Watch")
        XCTAssertEqual(WatchPlaybackDeviceStatus.spokenText(watchPlaying: false, phonePlaying: true,
                                                              selectedDevice: .phone),
                       "Audio is playing on iPhone")
        XCTAssertEqual(WatchPlaybackDeviceStatus.spokenText(watchPlaying: false, phonePlaying: true,
                                                              selectedDevice: .watch),
                       "Audio is paused on Apple Watch")
        XCTAssertEqual(WatchPlaybackDeviceStatus.spokenText(watchPlaying: false, phonePlaying: true,
                                                              phoneIsLive: false, selectedDevice: .phone),
                       "Last reported iPhone playback. Current state unavailable.")
    }

    func testHandoffUsesFreshMatchingPhoneStateAndFinalPausedPosition() throws {
        let snapshot: [String: Any] = ["accepted": true, "owner": "phone", "playing": true,
                                       "feedURL": "https://example.com/feed", "guid": "one",
                                       "audioURL": "https://example.com/one.mp3",
                                       "position": 120.0, "rate": 1.5, "observedAt": 1_000.0]
        let state = try XCTUnwrap(WatchHandoffSourceState(snapshot, now: 1_002))
        XCTAssertEqual(state.anticipatedPosition(now: 1_002), 123, accuracy: 0.001)
        XCTAssertNil(WatchHandoffSourceState(snapshot, now: 1_020))
        XCTAssertNil(state.pausedPosition(["accepted": true, "owner": "phone", "playing": false,
                                           "feedURL": state.feedURL, "guid": "another", "position": 154.75]))
        XCTAssertEqual(state.pausedPosition(["accepted": true, "owner": "phone", "playing": false,
                                             "feedURL": state.feedURL, "guid": state.guid,
                                             "position": 154.75]), 154.75)
    }

    @MainActor
    func testHandoffReplyFromConnectivityQueueReturnsToMainActor() async {
        let delivered = expectation(description: "Connectivity reply reaches the main actor")
        let handler = WatchPhoneHandoffReply.stateHandler { state in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(state?.guid, "one")
            delivered.fulfill()
        }
        DispatchQueue.global(qos: .utility).async {
            handler(["accepted": true, "owner": "phone", "playing": true,
                     "feedURL": "https://example.com/feed", "guid": "one",
                     "audioURL": "https://example.com/one.mp3", "position": 120.0,
                     "rate": 1.0, "observedAt": Date.now.timeIntervalSince1970])
        }
        await fulfillment(of: [delivered], timeout: 5)
    }
    @MainActor
    func testUnfollowStagesDurablePayloadBeforeDeletingPodcast() throws {
        let library = try WatchLibrary(inMemory: true)
        let podcast = WatchPodcast(feedURL: "https://example.com/feed", title: "Show")
        library.context.insert(podcast)
        library.persist()
        library.unsubscribe(podcast)

        let events = try library.context.fetch(FetchDescriptor<WatchPendingSyncEvent>())
        let event = try XCTUnwrap(events.first { $0.kind == "unfollow" })
        let payload = try JSONDecoder().decode(WatchSyncPayload.self, from: event.payload)
        XCTAssertEqual(payload.feedURL, "https://example.com/feed")
        XCTAssertEqual(payload.title, "Show")
        XCTAssertTrue(library.podcasts.isEmpty)
    }

    @MainActor
    func testBookmarkRemovalStagesPayloadBeforeDeletingModel() throws {
        let library = try WatchLibrary(inMemory: true)
        let episode = WatchEpisode(feedURL: "https://example.com/feed", guid: "one", title: "One",
                                   podcastTitle: "Show", audioURL: "https://example.com/one.mp3")
        library.context.insert(episode)
        library.persist()
        library.addBookmark(episode)
        let bookmark = try XCTUnwrap(library.bookmarks.first)
        let expectedID = bookmark.id
        library.removeBookmark(bookmark)

        let events = try library.context.fetch(FetchDescriptor<WatchPendingSyncEvent>())
        let event = try XCTUnwrap(events.first { $0.kind == "removeBookmark" })
        let payload = try JSONDecoder().decode(WatchSyncPayload.self, from: event.payload)
        XCTAssertEqual(payload.bookmarkID, expectedID)
        XCTAssertTrue(library.bookmarks.isEmpty)
    }


    @MainActor
    func testOfflineUnfollowRetainsHistoryAndStagesTombstone() throws {
        let library = try WatchLibrary(inMemory: true)
        let podcast = WatchPodcast(feedURL: "https://example.com/feed", title: "Show")
        library.context.insert(podcast)
        let episode = try XCTUnwrap(library.playablePhoneEpisode(feedURL: podcast.feedURL, guid: "one",
                                                                 title: "One", podcastTitle: "Show", audioURL: "https://example.com/one.mp3"))
        library.unsubscribe(podcast)
        XCTAssertTrue(library.podcasts.isEmpty)
        XCTAssertTrue(library.episodes.contains { $0.identity == episode.identity })
        let pending = try library.context.fetch(FetchDescriptor<WatchPendingSyncEvent>())
        XCTAssertTrue(pending.contains { $0.kind == "unfollow" })
    }
}
