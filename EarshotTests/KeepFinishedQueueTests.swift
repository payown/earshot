import XCTest
import SwiftData
import AVFoundation
@testable import Earshot

@MainActor
final class KeepFinishedQueueTests: XCTestCase {
    func testMarkPlayedQuickActionFollowsRetentionWithoutChangingOtherQueueRows() throws {
        for keep in [false, true] {
            let (context, episodes) = fixture()
            AppSettingsStore(context: context).setBool(keep, for: SettingsKey.keepFinishedEpisodesInQueue)
            let target = episodes[1]
            target.positionSeconds = 47
            try context.save()
            let otherID = episodes[2].queueItem?.persistentModelID
            var focusSawQueuedUnplayedRow = false
            let actions = buildEpisodeActions(
                episode: target, order: [.markPlayed], player: PlayerService(),
                downloads: DownloadManager(), context: context,
                onShowNotes: {}, onShare: {}, onBookmarks: {},
                onMarkPlayed: { nowPlayed in
                    focusSawQueuedUnplayedRow = nowPlayed && !target.isPlayed
                        && QueueRepository(context: context).queue().contains {
                            $0.persistentModelID == target.persistentModelID
                        }
                }
            )
            XCTAssertEqual(actions.map(\.label), ["Mark as played"])
            actions[0].run()
            XCTAssertTrue(focusSawQueuedUnplayedRow)
            XCTAssertTrue(target.isPlayed)
            XCTAssertTrue(target.inboxDismissed)
            XCTAssertEqual(target.positionSeconds, 47)
            XCTAssertEqual(QueueRepository(context: context).queue().map(\.guid),
                           keep ? ["0", "1", "2"] : ["0", "2"])
            XCTAssertEqual(episodes[2].queueItem?.persistentModelID, otherID)
            XCTAssertFalse(episodes[0].isPlayed)
            XCTAssertFalse(context.hasChanges)
            if !keep {
                XCTAssertTrue(try PendingCloudQueueMutation.memberships(in: context)
                    .contains { $0.guid == "1" && !$0.isQueued })
            }
        }
    }

    func testInboxMarkPlayedFollowsRetentionForQueuedEpisode() {
        for keep in [false, true] {
            let (context, episodes) = fixture()
            AppSettingsStore(context: context).setBool(keep, for: SettingsKey.keepFinishedEpisodesInQueue)
            InboxRepository(context: context).markPlayed(episodes[1])
            XCTAssertTrue(episodes[1].isPlayed)
            XCTAssertEqual(QueueRepository(context: context).queue().map(\.guid),
                           keep ? ["0", "1", "2"] : ["0", "2"])
        }
    }

    func testSelectedAndWholePodcastMarkPlayedFollowRetention() async {
        for keep in [false, true] {
            let (context, episodes) = fixture()
            AppSettingsStore(context: context).setBool(keep, for: SettingsKey.keepFinishedEpisodesInQueue)
            guard let podcast = episodes[0].podcast else { XCTFail("missing podcast"); return }
            let repo = EpisodeRepository(context: context)
            let selectedCount = await repo.markSelectedPlayed(
                in: podcast, ids: [episodes[1].persistentModelID]
            )
            XCTAssertEqual(selectedCount, 1)
            XCTAssertEqual(QueueRepository(context: context).queue().map(\.guid),
                           keep ? ["0", "1", "2"] : ["0", "2"])
            let remainingCount = await repo.markAllPlayed(in: podcast)
            XCTAssertEqual(remainingCount, 2)
            XCTAssertTrue(episodes.allSatisfy(\.isPlayed))
            XCTAssertEqual(QueueRepository(context: context).queue().map(\.guid),
                           keep ? ["0", "1", "2"] : [])
            XCTAssertFalse(context.hasChanges)
        }
    }

    func testPreferenceDefaultsOffPersistsAndMirrors() {
        let context = TestStore.freshContext()
        let settings = SettingsStore()
        settings.configure(context: context)
        XCTAssertFalse(settings.keepFinishedEpisodesInQueue)
        settings.keepFinishedEpisodesInQueue = true
        let reopened = SettingsStore()
        reopened.configure(context: context)
        XCTAssertTrue(reopened.keepFinishedEpisodesInQueue)
        XCTAssertFalse(AppSettingScope.isLocal(SettingsKey.keepFinishedEpisodesInQueue))
    }

    func testDefaultCompletionRemovesButOptInKeepsIdentityOrderAndPlayedState() throws {
        let (context, episodes) = fixture()
        let repo = QueueRepository(context: context)
        XCTAssertTrue(repo.finishPlayback(episodes[0]))
        XCTAssertEqual(repo.queue().map(\.guid), ["1", "2"])
        AppSettingsStore(context: context).setBool(true, for: SettingsKey.keepFinishedEpisodesInQueue)
        try LocalAppSettingIdentity.setValue(
            "synthetic-phone", for: SettingsKey.listeningPlacesDeviceID, in: context
        )
        try context.save()
        let itemID = episodes[1].queueItem?.persistentModelID
        episodes[1].positionSeconds = 42
        XCTAssertTrue(repo.finishPlayback(episodes[1]))
        XCTAssertEqual(repo.queue().map(\.guid), ["1", "2"])
        XCTAssertEqual(episodes[1].queueItem?.persistentModelID, itemID)
        XCTAssertTrue(episodes[1].isPlayed)
        XCTAssertNotNil(episodes[1].playedAt)
        XCTAssertTrue(episodes[1].inboxDismissed)
        XCTAssertEqual(episodes[1].positionSeconds, 0,
                       "natural completion saves Played and its reset together")
        XCTAssertFalse(context.hasChanges)
        guard case .event(let completed) = try ListeningPlacesEventJournal.read(
            for: episodes[1], in: context
        ) else { return XCTFail("completion needs one durable event") }
        XCTAssertTrue(completed.played)
        XCTAssertEqual(completed.positionMilliseconds, 0)
        XCTAssertTrue(try PendingCloudQueueMutation.memberships(in: context).allSatisfy { $0.guid != "1" || $0.isQueued })
    }

    func testUnqueuedCompletionNeverAddsMembershipAndManualMarkStillRemoves() {
        let (context, episodes) = fixture()
        let repo = QueueRepository(context: context)
        AppSettingsStore(context: context).setBool(true, for: SettingsKey.keepFinishedEpisodesInQueue)
        XCTAssertTrue(repo.cancelFromQueue(episodes[0]))
        XCTAssertTrue(repo.finishPlayback(episodes[0]))
        XCTAssertNil(episodes[0].queueItem)
        XCTAssertTrue(repo.markPlayedAndRemove(episodes[1]))
        XCTAssertNil(episodes[1].queueItem)
    }

    func testManualRemovalAndClearKeepRetainedCompletionEvenAfterOptOut() {
        let (context, episodes) = fixture()
        let repo = QueueRepository(context: context)
        let settings = AppSettingsStore(context: context)
        settings.setBool(true, for: SettingsKey.keepFinishedEpisodesInQueue)
        XCTAssertTrue(repo.finishPlayback(episodes[0]))
        XCTAssertTrue(repo.finishPlayback(episodes[1]))
        settings.setBool(false, for: SettingsKey.keepFinishedEpisodesInQueue)
        XCTAssertTrue(repo.cancelFromQueue(episodes[0]))
        XCTAssertTrue(episodes[0].isPlayed)
        XCTAssertTrue(repo.clear())
        XCTAssertTrue(episodes[1].isPlayed)
        XCTAssertFalse(episodes[2].isPlayed)
        XCTAssertTrue(repo.queue().isEmpty)
    }

    func testDownloadRetentionIsIndependent() throws {
        for delete in [false, true] {
            let (context, episodes) = fixture()
            let settings = AppSettingsStore(context: context)
            settings.setBool(true, for: SettingsKey.keepFinishedEpisodesInQueue)
            settings.setBool(delete, for: SettingsKey.deleteDownloadAfterPlayed)
            let episode = episodes[0]
            episode.downloadPath = "retention-test.mp3"
            ActiveDownload.setDownloadStatus(.downloaded, on: episode, in: context)
            try context.save()
            XCTAssertTrue(QueueRepository(context: context).finishPlayback(episode))
            XCTAssertNotNil(episode.queueItem)
            XCTAssertEqual(episode.downloadPath == nil, delete)
            XCTAssertEqual(episode.downloadStatus, delete ? .none : .downloaded)
        }
    }

    func testNaturalCompletionSkipsFinishedWithoutWrapAndRetainsPositionInQueue() async {
        let (context, episodes) = fixture()
        AppSettingsStore(context: context).setBool(true, for: SettingsKey.keepFinishedEpisodesInQueue)
        episodes[1].isPlayed = true
        try? context.save()
        let player = PlayerService()
        player.configure(context: context)
        defer { player.stopAndUnload() }
        player.load(episodes[0])
        await finish(player, expecting: episodes[2].persistentModelID)
        XCTAssertEqual(player.nowPlayingEpisodeID, episodes[2].persistentModelID)
        XCTAssertEqual(QueueRepository(context: context).queue().map(\.guid), ["0", "1", "2"])
        XCTAssertTrue(episodes[0].isPlayed)
        XCTAssertEqual(episodes[0].positionSeconds, 0)
    }

    func testNaturalQueueAdvanceStartsAtPrefetchedEligiblePeerPlace() async throws {
        let (context, episodes) = fixture()
        let audioURL = try silentAudioURL()
        defer { try? FileManager.default.removeItem(at: audioURL) }
        episodes[0].audioURL = audioURL.absoluteString
        episodes[1].audioURL = audioURL.absoluteString
        episodes[1].positionSeconds = 12
        try ListeningPlacesPublicFeedApproval.stageSyntheticDirectoryFixture(
            for: try XCTUnwrap(episodes[1].podcast?.feedURL), in: context
        )
        try LocalAppSettingIdentity.setValue(
            "synthetic-phone", for: SettingsKey.listeningPlacesDeviceID, in: context
        )
        try ListeningPlacesEventJournal.stageLocalMutation(
            of: episodes[1], in: context, deviceID: "synthetic-phone",
            now: Date.now.addingTimeInterval(-120)
        )
        try context.save()
        let peerTime = Date.now.addingTimeInterval(-60)
        let peer = try ListeningPlacesFormat.encodedDeviceFile(
            deviceID: "desktop99", appVersion: "quill/test", writtenAt: peerTime,
            records: [.episode(
                guid: episodes[1].guid, enclosureURL: episodes[1].audioURL,
                positionSeconds: 19, durationSeconds: nil, played: false,
                updatedAt: peerTime
            )]
        )
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "next-queue-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let service = ListeningPlacesService(readOtherDeviceFiles: { _, _ in
            ListeningPlacesOtherDeviceRead(
                files: [.init(fileName: "desktop99.json", data: peer)], skipped: []
            )
        })
        service.configure(context: context)
        await service.chooseFolder(folder, enableSharing: false)
        service.setReceivePlaybackEnabled(true)
        let player = PlayerService()
        player.configure(context: context)
        player.configureQueuePlaceService(service)
        defer { player.stopAndUnload(); service.releasePersistence() }
        player.play(episodes[0])
        for _ in 0..<100 where episodes[1].positionSeconds != 19 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(episodes[1].positionSeconds, 19,
                       "the prefetched peer event is durable before advance")
        await finish(player, expecting: episodes[1].persistentModelID)
        XCTAssertEqual(player.nowPlayingEpisodeID, episodes[1].persistentModelID)
        XCTAssertEqual(player.currentPositionSeconds, 19)
    }

    func testTurningRetentionOffStillSkipsPreviouslyRetainedFinishedRows() async {
        let (context, episodes) = fixture()
        let settings = AppSettingsStore(context: context)
        settings.setBool(true, for: SettingsKey.keepFinishedEpisodesInQueue)
        XCTAssertTrue(QueueRepository(context: context).finishPlayback(episodes[1]))
        settings.setBool(false, for: SettingsKey.keepFinishedEpisodesInQueue)
        let player = PlayerService()
        player.configure(context: context)
        defer { player.stopAndUnload() }
        player.load(episodes[0])
        await finish(player, expecting: episodes[2].persistentModelID)
        XCTAssertEqual(player.nowPlayingEpisodeID, episodes[2].persistentModelID)
        XCTAssertEqual(QueueRepository(context: context).queue().map(\.guid), ["1", "2"])
        XCTAssertTrue(episodes[1].isPlayed)
    }

    func testPlayNextOverrideDoesNotAutomaticallyReplayHeardEpisode() async {
        let (context, episodes) = fixture()
        AppSettingsStore(context: context).setBool(true, for: SettingsKey.keepFinishedEpisodesInQueue)
        episodes[1].isPlayed = true
        episodes[1].status = .inQueue // A prior requeue must not erase completion.
        try? context.save()
        let player = PlayerService()
        player.configure(context: context)
        defer { player.stopAndUnload() }
        player.load(episodes[0])
        player.registerPlayNext(episodes[1])
        await finish(player, expecting: episodes[2].persistentModelID)
        XCTAssertEqual(player.nowPlayingEpisodeID, episodes[2].persistentModelID)
    }

    func testSkippingFinishedStillRespectsPodcastBoundary() async {
        let (context, episodes) = fixture()
        let other = Podcast(feedURL: "https://example.com/other", title: "Other")
        context.insert(other)
        episodes[2].podcast = other
        episodes[1].isPlayed = true
        try? context.save()
        let settings = AppSettingsStore(context: context)
        settings.setBool(true, for: SettingsKey.keepFinishedEpisodesInQueue)
        settings.setBool(false, for: SettingsKey.continueAfterGroupEnds)
        settings.setQueueGrouping(.podcast)
        let player = PlayerService()
        player.configure(context: context)
        defer { player.stopAndUnload() }
        player.load(episodes[0])
        await finish(player, expecting: nil)
        XCTAssertNil(player.nowPlayingEpisodeID)
        XCTAssertFalse(episodes[2].isPlayed)
    }

    func testWrapSkipsRetainedHeardRowsAndFindsEarlierUnheard() async {
        let (context, episodes) = fixture()
        let settings = AppSettingsStore(context: context)
        settings.setBool(true, for: SettingsKey.keepFinishedEpisodesInQueue)
        settings.setBool(true, for: SettingsKey.wrapQueue)
        episodes[0].isPlayed = true
        try? context.save()
        let player = PlayerService()
        player.configure(context: context)
        defer { player.stopAndUnload() }
        player.load(episodes[2])
        await finish(player, expecting: episodes[1].persistentModelID)
        XCTAssertEqual(player.nowPlayingEpisodeID, episodes[1].persistentModelID)
        XCTAssertEqual(QueueRepository(context: context).queue().count, 3)
    }

    func testAllFinishedStopsEvenWithWrapAndExplicitReplayRemainsAvailable() async {
        let (context, episodes) = fixture()
        let settings = AppSettingsStore(context: context)
        settings.setBool(true, for: SettingsKey.keepFinishedEpisodesInQueue)
        settings.setBool(true, for: SettingsKey.wrapQueue)
        episodes[0].isPlayed = true
        episodes[1].isPlayed = true
        try? context.save()
        let player = PlayerService()
        player.configure(context: context)
        defer { player.stopAndUnload() }
        player.load(episodes[2])
        await finish(player, expecting: nil)
        XCTAssertNil(player.nowPlayingEpisodeID)
        XCTAssertEqual(QueueRepository(context: context).queue().count, 3)
        XCTAssertTrue(episodes[2].isPlayed)
        player.play(episodes[0])
        XCTAssertEqual(player.nowPlayingEpisodeID, episodes[0].persistentModelID)
    }

    func testStopAfterCurrentAndSleepTimerRetainFinishedEpisode() async {
        for timer in [false, true] {
            let (context, episodes) = fixture()
            AppSettingsStore(context: context).setBool(true, for: SettingsKey.keepFinishedEpisodesInQueue)
            let player = PlayerService()
            player.configure(context: context)
            player.load(episodes[0])
            if timer { player.sleepTimer.set(.endOfEpisode) }
            else { player.toggleStopAfterEpisode() }
            await finish(player, expecting: nil)
            XCTAssertNil(player.nowPlayingEpisodeID)
            XCTAssertTrue(episodes[0].isPlayed)
            XCTAssertEqual(QueueRepository(context: context).queue().count, 3)
            player.stopAndUnload()
        }
    }

    func testFolderCompletionRetainsOnlyExistingMembershipAndManualCompletionRemoves() {
        let (context, episodes) = fixture()
        AppSettingsStore(context: context).setBool(true, for: SettingsKey.keepFinishedEpisodesInQueue)
        let player = PlayerService()
        player.configure(context: context)
        defer { player.stopAndUnload() }
        XCTAssertTrue(player.finishFolderEpisode(episodes[0], naturalCompletion: true))
        XCTAssertNotNil(episodes[0].queueItem)
        XCTAssertTrue(episodes[0].isPlayed)
        XCTAssertTrue(player.finishFolderEpisode(episodes[1]))
        XCTAssertNil(episodes[1].queueItem)
    }

    private func finish(_ player: PlayerService, expecting id: PersistentIdentifier?) async {
        NotificationCenter.default.post(name: AVPlayerItem.didPlayToEndTimeNotification, object: nil)
        for _ in 0..<200 {
            if player.nowPlayingEpisodeID == id { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func fixture() -> (ModelContext, [Episode]) {
        let context = TestStore.freshContext()
        let show = Podcast(feedURL: "https://example.com/feed", title: "Show")
        context.insert(show)
        let episodes = (0..<3).map { index in
            let episode = Episode(guid: String(index), title: "Episode \(index)", audioURL: "https://example.com/\(index).mp3")
            context.insert(episode)
            episode.podcast = show
            QueueRepository(context: context).add(episode)
            return episode
        }
        return (context, episodes)
    }

    private func silentAudioURL() throws -> URL {
        let sampleRate: UInt32 = 8_000
        let bytesPerSecond: UInt32 = 16_000
        let sampleBytes = bytesPerSecond * 30
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8)
        append(UInt32(36) + sampleBytes)
        data.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(sampleRate)
        append(bytesPerSecond)
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: "data".utf8)
        append(sampleBytes)
        data.append(Data(count: Int(sampleBytes)))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("next-queue-\(UUID().uuidString).wav")
        try data.write(to: url, options: .atomic)
        return url
    }
}
