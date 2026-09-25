import AppIntents
import AVFoundation
import SwiftData
import XCTest
@testable import Earshot

@MainActor
final class ShortcutAutomationTests: XCTestCase {
    private func fixture(count: Int = 3) async throws -> (AppRuntime, [Episode], URL) {
        let audio = FileManager.default.temporaryDirectory.appending(path: "Shortcut-\(UUID()).wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000 * 90))
        buffer.frameLength = buffer.frameCapacity
        buffer.floatChannelData?[0].initialize(repeating: 0, count: Int(buffer.frameLength))
        try AVAudioFile(forWriting: audio, settings: format.settings).write(from: buffer)
        let container = try ModelContainerFactory.makeInMemory()
        let context = container.mainContext
        let show = Podcast(feedURL: "https://example.com/feed", title: "Show")
        context.insert(show)
        let episodes = (0..<count).map { n in
            let episode = Episode(guid: "\(n)", title: "Episode \(n)", audioURL: audio.absoluteString)
            context.insert(episode); episode.podcast = show
            context.insert(QueueItem(episode: episode, position: n))
            return episode
        }
        try context.save()
        let runtime = AppRuntime(load: .ready(container), mode: .testHost)
        _ = await runtime.activateRootServices(for: container) {
            runtime.player.configure(context: context)
            runtime.settings.configure(context: context)
            runtime.settings.onboardingComplete = true
        }
        return (runtime, episodes, audio)
    }
    private func clean(_ runtime: AppRuntime, _ audio: URL) {
        runtime.player.stopAndUnload(); runtime.player.releasePersistence()
        try? FileManager.default.removeItem(at: audio)
    }

    func testPauseIsIdempotentAndChapterBoundariesAreHonest() async throws {
        let (runtime, episodes, audio) = try await fixture()
        defer { clean(runtime, audio) }
        runtime.player.load(episodes[0])
        XCTAssertThrowsError(try LibraryPlaybackBridge.control(.nextChapter, runtime: runtime))
        runtime.player.setChapters([Chapter(index: 0, startTime: 0, title: "A"), Chapter(index: 1, startTime: 30, title: "B")])
        try LibraryPlaybackBridge.control(.nextChapter, runtime: runtime)
        XCTAssertEqual(runtime.player.currentPositionSeconds, 30, accuracy: 0.1)
        XCTAssertThrowsError(try LibraryPlaybackBridge.control(.nextChapter, runtime: runtime))
        try LibraryPlaybackBridge.control(.previousChapter, runtime: runtime)
        XCTAssertEqual(runtime.player.currentPositionSeconds, 0, accuracy: 0.1)
        try LibraryPlaybackBridge.control(.pause, runtime: runtime)
        try LibraryPlaybackBridge.control(.pause, runtime: runtime)
        XCTAssertFalse(runtime.player.hasActivePlaybackRequest)
    }

    func testControlsWithNoEpisodeFailWithoutCreatingQueueItems() async throws {
        let (runtime, _, audio) = try await fixture(count: 0)
        defer { clean(runtime, audio) }
        for command in ShortcutPlaybackCommand.allCases {
            XCTAssertThrowsError(try LibraryPlaybackBridge.control(command, runtime: runtime))
        }
        XCTAssertTrue(QueueRepository(context: try XCTUnwrap(runtime.readyContainer).mainContext).queue().isEmpty)
    }

    func testClearAndNextMarksOnlyCurrentAndLastItemStops() async throws {
        let (runtime, episodes, audio) = try await fixture(count: 2)
        defer { clean(runtime, audio) }
        runtime.player.load(episodes[0])
        try LibraryPlaybackBridge.control(.clearAndNext, runtime: runtime)
        XCTAssertTrue(episodes[0].isPlayed)
        XCTAssertNil(episodes[0].queueItem)
        XCTAssertEqual(runtime.player.nowPlayingEpisodeID, episodes[1].persistentModelID)
        XCTAssertFalse(episodes[1].isPlayed)
        try LibraryPlaybackBridge.control(.clearAndNext, runtime: runtime)
        XCTAssertNil(runtime.player.nowPlayingEpisodeID)
        XCTAssertTrue(episodes[1].isPlayed)
    }

    func testDeferFromMiddleUsesNextNeighborInsteadOfReplayingFirst() async throws {
        let (runtime, episodes, audio) = try await fixture()
        defer { clean(runtime, audio) }
        runtime.player.load(episodes[1])
        episodes[1].positionSeconds = 12
        try LibraryPlaybackBridge.control(.deferEpisode, runtime: runtime)
        XCTAssertEqual(runtime.player.nowPlayingEpisodeID, episodes[2].persistentModelID)
        let queue = QueueRepository(context: try XCTUnwrap(runtime.readyContainer).mainContext).queue()
        XCTAssertEqual(queue.map(\.guid), ["0", "2", "1"])
        XCTAssertFalse(episodes[1].isPlayed)
        XCTAssertNotNil(episodes[1].queueItem)
    }

    func testSleepControlsAndInvalidSpeed() async throws {
        let (runtime, episodes, audio) = try await fixture()
        defer { clean(runtime, audio) }
        runtime.player.load(episodes[0])
        XCTAssertThrowsError(try LibraryPlaybackBridge.control(.extendSleepTimer, runtime: runtime, seconds: 60))
        try LibraryPlaybackBridge.control(.sleepTimer, runtime: runtime, timer: .fiveMinutes)
        try LibraryPlaybackBridge.control(.extendSleepTimer, runtime: runtime, seconds: 60)
        XCTAssertGreaterThan(runtime.player.sleepTimer.remainingSeconds ?? 0, 359)
        try LibraryPlaybackBridge.control(.cancelSleepTimer, runtime: runtime)
        XCTAssertFalse(runtime.player.sleepTimer.isActive)
        for speed in [Double.nan, .infinity, -1, 0, 4] {
            XCTAssertThrowsError(try LibraryPlaybackBridge.control(.speed, runtime: runtime, speed: speed))
        }
        try LibraryPlaybackBridge.control(.speed, runtime: runtime, speed: 1.25)
        XCTAssertEqual(episodes[0].podcast?.speedOverride, 1.25)
        try LibraryPlaybackBridge.control(.continuousPlay, runtime: runtime, enabled: false)
        XCTAssertTrue(runtime.player.stopAfterCurrentEpisode)
    }

    func testGetQueueAndSelectBeyondSearchQueueBudget() async throws {
        let wasEnabled = LibrarySearchIndex.isEnabled
        UserDefaults.standard.set(true, forKey: LibrarySearchIndex.enabledKey)
        defer { UserDefaults.standard.set(wasEnabled, forKey: LibrarySearchIndex.enabledKey) }
        let (runtime, episodes, audio) = try await fixture(count: 225)
        defer { clean(runtime, audio) }
        let bridge = LibraryPlaybackBridge()
        bridge.install(runtime: runtime)
        episodes[0].podcast?.subscriptionStateRaw = "catalogOnly"
        try runtime.readyContainer?.mainContext.save()
        LibraryIntentBridge.shared.install(runtime: runtime)
        let indexed = try await SearchContentStore.make(container: try XCTUnwrap(runtime.readyContainer)).snapshot()
        let lastID = SearchContent.identifier(feedURL: "https://example.com/feed", guid: "224")
        XCTAssertFalse(indexed.contains { $0.id == lastID }, "Fixture must actually exceed search index coverage")
        let rehydrated = try await EpisodeEntityQuery().entities(for: [lastID])
        XCTAssertEqual(rehydrated.map(\.id), [lastID])
        let results = try await bridge.listedEpisodes(.queue, query: "")
        XCTAssertEqual(results.count, 225)
        XCTAssertEqual(results.last?.title, "Episode 224")
        let last = try XCTUnwrap(results.last)
        let selected = try await bridge.selectedEpisode(id: last.id, runtime: runtime, container: try XCTUnwrap(runtime.readyContainer))
        XCTAssertEqual(selected.persistentModelID, episodes[224].persistentModelID)
        UserDefaults.standard.set(false, forKey: LibrarySearchIndex.enabledKey)
        do { _ = try await bridge.listedEpisodes(.queue, query: ""); XCTFail("Must respect opt-out") }
        catch { XCTAssertEqual(error as? LibraryPlaybackError, .searchDisabled) }
    }

    func testRemoveCurrentUsesPlayerAndPreservesUnplayedState() async throws {
        let wasEnabled = LibrarySearchIndex.isEnabled
        UserDefaults.standard.set(true, forKey: LibrarySearchIndex.enabledKey)
        defer { UserDefaults.standard.set(wasEnabled, forKey: LibrarySearchIndex.enabledKey) }
        let (runtime, episodes, audio) = try await fixture()
        defer { clean(runtime, audio) }
        runtime.player.load(episodes[0])
        let bridge = LibraryPlaybackBridge(); bridge.install(runtime: runtime)
        let id = SearchContent.identifier(feedURL: "https://example.com/feed", guid: "0")
        try await bridge.queueEpisode(id: id, placement: .remove)
        XCTAssertNil(episodes[0].queueItem)
        XCTAssertFalse(episodes[0].isPlayed)
        XCTAssertEqual(runtime.player.nowPlayingEpisodeID, episodes[1].persistentModelID)
    }

    func testBackgroundReadyStoreInstallsWithoutOpeningScene() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        AppSettingsStore(context: container.mainContext).setBool(true, for: SettingsKey.onboardingComplete)
        let runtime = AppRuntime(mode: .testHost, launchOperation: { _ in .ready(container) })
        runtime.updateLaunchScenePhase(.background)
        runtime.startLaunchIfNeeded()
        for _ in 0..<30 {
            await runtime.completeBackgroundAudioLaunchIfReady()
            if runtime.readyContainer != nil { break }
            await Task.yield()
        }
        XCTAssertTrue(runtime.readyContainer === container)
        XCTAssertEqual(runtime.launchAttemptCount, 1)
        await runtime.completeBackgroundAudioLaunchIfReady()
        XCTAssertEqual(runtime.launchAttemptCount, 1)
    }

    func testBackgroundPreparationAndOnboardingRemainForegroundGated() async throws {
        for preparation in [false, true] {
            let container = try ModelContainerFactory.makeInMemory()
            AppSettingsStore(context: container.mainContext).setBool(preparation, for: SettingsKey.onboardingComplete)
            let runtime = AppRuntime(mode: .testHost, showsLaunchPreparation: preparation, launchOperation: { _ in .ready(container) })
            runtime.updateLaunchScenePhase(.background)
            runtime.startLaunchIfNeeded()
            for _ in 0..<30 { await Task.yield(); await runtime.completeBackgroundAudioLaunchIfReady() }
            XCTAssertNil(runtime.readyContainer)
        }
    }

    func testPlayNextOverridesGroupedContinuation() async throws {
        let wasEnabled = LibrarySearchIndex.isEnabled
        UserDefaults.standard.set(true, forKey: LibrarySearchIndex.enabledKey)
        defer { UserDefaults.standard.set(wasEnabled, forKey: LibrarySearchIndex.enabledKey) }
        let (runtime, episodes, audio) = try await fixture()
        defer { clean(runtime, audio) }
        let context = try XCTUnwrap(runtime.readyContainer).mainContext
        let other = Podcast(feedURL: "https://example.com/other", title: "Other")
        context.insert(other); episodes[2].podcast = other
        try context.save()
        AppSettingsStore(context: context).setQueueGrouping(.podcast)
        AppSettingsStore(context: context).setBool(false, for: SettingsKey.continueAfterGroupEnds)
        runtime.player.load(episodes[0])
        let bridge = LibraryPlaybackBridge(); bridge.install(runtime: runtime)
        try await bridge.queueEpisode(id: SearchContent.identifier(feedURL: other.feedURL, guid: "2"), placement: .next)
        runtime.player.markCurrentPlayedAndAdvance()
        XCTAssertEqual(runtime.player.nowPlayingEpisodeID, episodes[2].persistentModelID)
    }

    func testCancelledControlDoesNotMutateQueue() async throws {
        let (runtime, episodes, audio) = try await fixture()
        defer { clean(runtime, audio) }
        runtime.player.load(episodes[0])
        let bridge = LibraryPlaybackBridge(); bridge.install(runtime: runtime)
        let task = Task { try await bridge.control(.clearAndNext) }
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(episodes[0].isPlayed)
        XCTAssertNotNil(episodes[0].queueItem)
    }

    func testOptOutWhilePreparingQueueFirstPreventsPlayback() async throws {
        let wasEnabled = LibrarySearchIndex.isEnabled
        UserDefaults.standard.set(true, forKey: LibrarySearchIndex.enabledKey)
        defer { UserDefaults.standard.set(wasEnabled, forKey: LibrarySearchIndex.enabledKey) }
        let container = try ModelContainerFactory.makeInMemory()
        let context = container.mainContext
        let show = Podcast(feedURL: "https://example.com/private", title: "Private")
        let episode = Episode(guid: "one", title: "One", audioURL: "https://example.com/one.mp3")
        context.insert(show); context.insert(episode); episode.podcast = show
        context.insert(QueueItem(episode: episode, position: 0)); try context.save()
        let runtime = AppRuntime(load: .ready(container), mode: .testHost)
        let bridge = LibraryPlaybackBridge(start: { _, _ in XCTFail("Playback after opt-out") })
        bridge.install(runtime: runtime)
        let activation = Task { await runtime.activateRootServices(for: container) {
            try await Task.sleep(for: .milliseconds(150))
            runtime.settings.configure(context: context)
            runtime.settings.onboardingComplete = true
            UserDefaults.standard.set(false, forKey: LibrarySearchIndex.enabledKey)
        } }
        while runtime.rootServiceActivationStatus != .inProgress { await Task.yield() }
        do {
            try await bridge.playUnheard(showID: SearchContent.identifier(feedURL: show.feedURL), choice: .queueFirst)
            XCTFail("Expected opt-out")
        } catch { XCTAssertEqual(error as? LibraryPlaybackError, .searchDisabled) }
        _ = await activation.value
    }

    func testReadyToUseShortcutsStayWithinSystemLimit() {
        XCTAssertEqual(EarshotAppShortcuts.appShortcuts.count, 10)
        XCTAssertFalse(ResumeListeningIntent.openAppWhenRun)
        XCTAssertFalse(PlayEpisodeIntent.openAppWhenRun)
    }
}
