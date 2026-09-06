import SwiftData
import XCTest
import AVFoundation
@testable import Earshot

private actor FolderRunTestFeed: FeedFetching {
    let episodes: [ParsedEpisode]
    let failing: Set<String>
    let delay: Duration
    private var calls: [String: Int] = [:]
    init(episodes: [ParsedEpisode] = [], failing: Set<String> = [], delay: Duration = .zero) {
        self.episodes = episodes
        self.failing = failing
        self.delay = delay
    }
    func fetch(_ urlString: String) async throws -> ParsedFeed {
        calls[urlString, default: 0] += 1
        if delay != .zero { try await Task.sleep(for: delay) }
        if failing.contains(urlString) { throw URLError(.cannotConnectToHost) }
        return ParsedFeed(title: "Feed", episodes: episodes)
    }
    func counts() -> [String: Int] { calls }
}

@MainActor
final class FolderRunIntegrationTests: XCTestCase {
    private var audioURL: URL!

    override func setUp() async throws {
        audioURL = try makeAudio(seconds: 120)
    }

    override func tearDown() async throws {
        try FileManager.default.removeItem(at: audioURL)
    }

    private func makeAudio(seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "folder-run-\(UUID().uuidString).wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(8_000 * seconds)))
        buffer.frameLength = buffer.frameCapacity
        buffer.floatChannelData?[0].initialize(repeating: 0, count: Int(buffer.frameLength))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    private func fixture() throws -> (ModelContext, PodcastFolder, Podcast, Podcast) {
        let context = TestStore.freshContext()
        let repo = FolderRepository(context: context)
        let root = repo.createFolder(name: "Root")
        let child = repo.createSubfolder(named: "Child", under: root)
        let nested = repo.createSubfolder(named: "Nested", under: child)
        let a = Podcast(feedURL: "https://a.example/feed", title: "A")
        let b = Podcast(feedURL: "https://b.example/feed", title: "B")
        context.insert(a); context.insert(b)
        repo.add(a, to: root); repo.add(a, to: nested); repo.add(b, to: child)
        try context.save()
        return (context, root, a, b)
    }

    private func episode(_ guid: String, podcast: Podcast, context: ModelContext, age: Double) -> Episode {
        let episode = Episode(guid: guid, title: guid, audioURL: audioURL.absoluteString,
                              pubDate: .now.addingTimeInterval(-age), inboxDismissed: true)
        episode.podcast = podcast
        context.insert(episode)
        return episode
    }

    func testNestedMembershipIsDeduplicatedAndUnfollowedShowsExcluded() async throws {
        let (context, folder, a, b) = try fixture()
        let catalog = FolderRunCatalog(container: context.container)
        let feeds = try await catalog.feeds(in: folder.persistentModelID)
        XCTAssertEqual(feeds, [a.feedURL, b.feedURL])
        b.subscriptionStateRaw = PodcastSubscriptionState.catalogOnly.rawValue
        try context.save()
        let followed = try await catalog.feeds(in: folder.persistentModelID)
        XCTAssertEqual(followed, [a.feedURL])
    }

    func testOneFetchPerShowImportsHistoryWithoutInboxQueueOrDownloadsAndRetainsLocalOnFailure() async throws {
        let (context, folder, a, b) = try fixture()
        let old = episode("old-local", podcast: b, context: context, age: 900)
        old.positionSeconds = 123
        let played = episode("played", podcast: a, context: context, age: 700)
        played.isPlayed = true
        let queued = episode("queued", podcast: b, context: context, age: 500)
        QueueRepository(context: context).add(queued)
        try context.save()
        let before = QueueRepository(context: context).queue().map(\.guid)
        let parsed = (0..<3_005).map { index in
            ParsedEpisode(guid: "rss-\(index)", title: "Older \(index)", audioURL: "https://example.invalid/audio.mp3",
                          pubDate: .now.addingTimeInterval(-Double(index + 1)), episodeNumber: index + 10)
        }
        let feed = FolderRunTestFeed(episodes: parsed, failing: [b.feedURL])
        let catalog = FolderRunCatalog(container: context.container)
        let store = try await FolderRunStore.open()
        let run = try await store.begin(folderIdentity: JSONEncoder().encode(folder.persistentModelID), folderName: "Root", totalPodcasts: 2)
        try await catalog.prepare(feeds: [a.feedURL, b.feedURL], runID: run.id, store: store, feed: feed) { _ in }
        let ready = try await store.seal(id: run.id)
        XCTAssertEqual(ready.discovered, 3_007)
        XCTAssertEqual(ready.unavailablePodcasts, 2, "One failed feed and one possibly truncated numbered archive")
        let calls = await feed.counts()
        XCTAssertEqual(calls, [a.feedURL: 1, b.feedURL: 1])
        let fresh = ModelContext(context.container)
        let imported = try fresh.fetch(FetchDescriptor<Episode>()).filter { $0.guid.hasPrefix("rss-") }
        XCTAssertEqual(imported.count, 3_005)
        XCTAssertTrue(imported.allSatisfy { $0.inboxDismissed && !$0.isPlayed && $0.downloadStatus == .none && $0.queueItem == nil })
        XCTAssertEqual(QueueRepository(context: context).queue().map(\.guid), before)
        XCTAssertEqual(old.positionSeconds, 123)
        let window = try await store.window(id: run.id)
        XCTAssertEqual(window.first?.identity.guid, "rss-3004")
    }

    func testControllerCompletesAcrossShowsAndReturnsToUnrelatedQueueWithoutDuplicates() async throws {
        let (context, folder, a, b) = try fixture()
        let first = episode("first", podcast: a, context: context, age: 900)
        let second = episode("second", podcast: b, context: context, age: 700)
        first.positionSeconds = 42
        let unrelatedPodcast = Podcast(feedURL: "https://other.example/feed", title: "Other")
        context.insert(unrelatedPodcast)
        let other = episode("other", podcast: unrelatedPodcast, context: context, age: 500)
        let queue = QueueRepository(context: context)
        queue.add([other, second])
        try context.save()
        let store = try await FolderRunStore.open()
        let player = PlayerService()
        player.configure(context: context)
        let run = player.folderRuns
        await run.connect(context: context, player: player, testStore: store)
        run.start(folder: folder, replacing: nil, feed: FolderRunTestFeed(), startsPlayback: false)
        await run.waitForOperationForTesting()
        XCTAssertEqual(run.snapshot?.discovered, 2)
        run.resume()
        player.pause()
        await run.waitForOperationForTesting()
        XCTAssertFalse(player.isPlaying, "Pause must cancel an in-flight resume before any actor returns")
        XCTAssertEqual(run.snapshot?.state, .paused)
        run.resume()
        await run.waitForOperationForTesting()
        XCTAssertEqual(player.nowPlayingEpisode?.guid, "first")
        XCTAssertEqual(first.positionSeconds, 42)
        XCTAssertEqual(queue.queue().map(\.guid), ["other", "second"])
        XCTAssertTrue(run.completeCurrent(first, continuePlayback: true))
        await run.waitForOperationForTesting()
        XCTAssertEqual(player.nowPlayingEpisode?.guid, "second")
        XCTAssertTrue(run.completeCurrent(second, continuePlayback: true))
        await run.waitForOperationForTesting()
        XCTAssertEqual(player.nowPlayingEpisode?.guid, "other")
        XCTAssertEqual(queue.queue().map(\.guid), ["other"])
        XCTAssertTrue(first.isPlayed && second.isPlayed)
        XCTAssertEqual(run.snapshot?.remaining, 0)
        player.stopAndUnload()
        await run.release()
    }

    func testPauseDuringCompletionDoesNotStartNextUntilExplicitResume() async throws {
        let (context, folder, a, _) = try fixture()
        let first = episode("first", podcast: a, context: context, age: 900)
        _ = episode("second", podcast: a, context: context, age: 700)
        try context.save()
        let player = PlayerService()
        player.configure(context: context)
        let run = player.folderRuns
        await run.connect(context: context, player: player, testStore: try await FolderRunStore.open())
        run.start(folder: folder, replacing: nil, feed: FolderRunTestFeed(), startsPlayback: false)
        await run.waitForOperationForTesting()
        run.resume()
        await run.waitForOperationForTesting()
        XCTAssertTrue(run.completeCurrent(first, continuePlayback: true))
        player.pause()
        await run.waitForOperationForTesting()
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(run.driving)
        player.resume()
        await run.waitForOperationForTesting()
        XCTAssertEqual(player.nowPlayingEpisode?.guid, "second")
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification,
                                        object: AVAudioSession.sharedInstance(),
                                        userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        for _ in 0..<50 where player.isPlaying { try await Task.sleep(for: .milliseconds(10)) }
        await run.waitForOperationForTesting()
        XCTAssertFalse(run.driving)
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification,
                                        object: AVAudioSession.sharedInstance(),
                                        userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                                                   AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue])
        for _ in 0..<50 where !run.driving { try await Task.sleep(for: .milliseconds(10)) }
        await run.waitForOperationForTesting()
        XCTAssertTrue(run.driving, "System-authorized resumption must restore folder continuation, not only audio")
        player.stopAndUnload()
        await run.release()
    }

    func testReleaseCancelsInFlightPreparationAndLeavesNoPlayablePartialRun() async throws {
        let (context, folder, _, _) = try fixture()
        let player = PlayerService()
        player.configure(context: context)
        let store = try await FolderRunStore.open()
        let run = player.folderRuns
        await run.connect(context: context, player: player, testStore: store)
        let feed = FolderRunTestFeed(delay: .seconds(60))
        run.start(folder: folder, replacing: nil, feed: feed)
        for _ in 0..<100 {
            if !(await feed.counts()).isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await run.release()
        let snapshot = try await store.currentSnapshot()
        XCTAssertEqual(snapshot?.state, .cancelled)
        XCTAssertFalse(run.isConnected)
        player.stopAndUnload()
    }

    func testRecoveryRestoresPausedPositionThenSkipsDeletedAndPlayedEntriesAfterFolderDeletion() async throws {
        let (context, folder, a, _) = try fixture()
        let first = episode("first", podcast: a, context: context, age: 900)
        first.positionSeconds = 45
        let deleted = episode("deleted", podcast: a, context: context, age: 800)
        let played = episode("played", podcast: a, context: context, age: 700)
        let last = episode("last", podcast: a, context: context, age: 600)
        try context.save()
        let store = try await FolderRunStore.open()
        let original = PlayerService()
        original.configure(context: context)
        await original.folderRuns.connect(context: context, player: original, testStore: store)
        original.folderRuns.start(folder: folder, replacing: nil, feed: FolderRunTestFeed(), startsPlayback: false)
        await original.folderRuns.waitForOperationForTesting()
        let id = try XCTUnwrap(original.folderRuns.snapshot?.id)
        // Simulate persisted playing state at process death, not a user pause.
        _ = try await store.resume(id: id)
        await original.folderRuns.release()
        let player = PlayerService()
        player.configure(context: context)
        let run = player.folderRuns
        await run.connect(context: context, player: player, testStore: store)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.nowPlayingEpisode?.guid, "first")
        XCTAssertEqual(first.positionSeconds, 45)
        folder.name = "Renamed"
        try context.save()
        run.refreshFolderName()
        XCTAssertEqual(run.folderName, "Renamed")
        context.delete(deleted)
        context.delete(folder)
        played.isPlayed = true
        try context.save()
        run.resume()
        await run.waitForOperationForTesting()
        XCTAssertTrue(run.completeCurrent(first, continuePlayback: true))
        await run.waitForOperationForTesting()
        XCTAssertEqual(player.nowPlayingEpisode?.guid, last.guid)
        XCTAssertEqual(run.snapshot?.skipped, 1)
        XCTAssertEqual(run.snapshot?.unavailableEpisodes, 1)
        player.stopAndUnload()
        await run.release()
    }

    func testUnrelatedPlaybackPausesRunAndAudioFailureCanBeSkippedWithoutMarkingPlayed() async throws {
        let (context, folder, a, _) = try fixture()
        let first = episode("first", podcast: a, context: context, age: 900)
        let second = episode("second", podcast: a, context: context, age: 800)
        try context.save()
        let player = PlayerService()
        player.configure(context: context)
        let run = player.folderRuns
        await run.connect(context: context, player: player, testStore: try await FolderRunStore.open())
        run.start(folder: folder, replacing: nil, feed: FolderRunTestFeed(), startsPlayback: false)
        await run.waitForOperationForTesting()
        run.resume()
        await run.waitForOperationForTesting()
        player.play(second)
        await run.waitForOperationForTesting()
        XCTAssertEqual(run.snapshot?.state, .paused)
        XCTAssertFalse(run.driving)
        XCTAssertFalse(run.completeCurrent(second, continuePlayback: true))
        run.resume()
        await run.waitForOperationForTesting()
        run.playbackFailed(first)
        await run.waitForOperationForTesting()
        XCTAssertTrue(run.hasPlaybackFailure)
        XCTAssertFalse(first.isPlayed)
        XCTAssertEqual(run.snapshot?.remaining, 2)
        run.skipFailedEpisode()
        await run.waitForOperationForTesting()
        XCTAssertEqual(player.nowPlayingEpisode?.guid, "second")
        XCTAssertFalse(first.isPlayed)
        XCTAssertEqual(run.snapshot?.unavailableEpisodes, 1)
        run.playbackFailed(second, unavailable: true)
        await run.waitForOperationForTesting()
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(second.isPlayed)
        XCTAssertEqual(run.snapshot?.unavailableEpisodes, 2)
        player.stopAndUnload()
        await run.release()
    }

    func testNaturalAudioCompletionHonorsStopAfterCurrentAndResumesRemainingRun() async throws {
        let (context, folder, a, b) = try fixture()
        let short = try makeAudio(seconds: 0.4)
        defer { try? FileManager.default.removeItem(at: short) }
        let first = episode("first", podcast: a, context: context, age: 900)
        let second = episode("second", podcast: b, context: context, age: 800)
        first.audioURL = short.absoluteString
        second.audioURL = short.absoluteString
        try context.save()
        let player = PlayerService()
        player.configure(context: context)
        let run = player.folderRuns
        await run.connect(context: context, player: player, testStore: try await FolderRunStore.open())
        run.start(folder: folder, replacing: nil, feed: FolderRunTestFeed(), startsPlayback: false)
        await run.waitForOperationForTesting()
        run.resume()
        await run.waitForOperationForTesting()
        player.stopAfterCurrentEpisode = true
        for _ in 0..<100 where run.snapshot?.completed == 0 { try await Task.sleep(for: .milliseconds(100)) }
        await run.waitForOperationForTesting()
        XCTAssertTrue(first.isPlayed)
        XCTAssertFalse(second.isPlayed)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(run.snapshot?.state, .paused)
        run.resume()
        await run.waitForOperationForTesting()
        for _ in 0..<100 where run.snapshot?.remaining != 0 { try await Task.sleep(for: .milliseconds(100)) }
        await run.waitForOperationForTesting()
        XCTAssertTrue(second.isPlayed)
        XCTAssertEqual(run.snapshot?.completed, 2)
        player.stopAndUnload()
        await run.release()
    }

    func testFileResetIncludesFolderRunDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appending(path: "support")
        let documents = root.appending(path: "documents")
        let caches = root.appending(path: "caches")
        let runs = support.appending(path: FolderRunController.directoryName)
        for directory in [runs, documents, caches] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("manifest".utf8).write(to: runs.appending(path: "manifest.store"))
        let success = await SettingsReset.performFileReset(applicationSupport: support, documents: documents, caches: caches)
        XCTAssertTrue(success)
        XCTAssertFalse(FileManager.default.fileExists(atPath: runs.path))
    }
}
