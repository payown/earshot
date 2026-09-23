import XCTest
import SwiftData
import AVFoundation
@testable import Earshot

@MainActor
final class KeepFinishedQueueTests: XCTestCase {
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
        let itemID = episodes[1].queueItem?.persistentModelID
        episodes[1].positionSeconds = 42
        XCTAssertTrue(repo.finishPlayback(episodes[1]))
        XCTAssertEqual(repo.queue().map(\.guid), ["1", "2"])
        XCTAssertEqual(episodes[1].queueItem?.persistentModelID, itemID)
        XCTAssertTrue(episodes[1].isPlayed)
        XCTAssertNotNil(episodes[1].playedAt)
        XCTAssertTrue(episodes[1].inboxDismissed)
        XCTAssertEqual(episodes[1].positionSeconds, 42)
        XCTAssertFalse(context.hasChanges)
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
}
