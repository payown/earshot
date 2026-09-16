import AVFoundation
import SwiftData
import XCTest
@testable import Earshot

@MainActor
final class LibraryPlaybackIntentTests: XCTestCase {
    private func readyRuntime(_ container: ModelContainer, onboarding: Bool = true) async -> AppRuntime {
        let runtime = AppRuntime(load: .ready(container), mode: .testHost)
        _ = await runtime.activateRootServices(for: container) {
            runtime.player.configure(context: container.mainContext)
            runtime.settings.configure(context: container.mainContext)
            runtime.settings.onboardingComplete = onboarding
        }
        return runtime
    }

    func testResumeWithNoEpisodeIsHonestAndDoesNotInvokePlayer() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let runtime = await readyRuntime(container)
        var calls = 0
        let bridge = LibraryPlaybackBridge(continuePlayback: { _ in calls += 1 })
        bridge.install(runtime: runtime)
        do { try await bridge.resume(); XCTFail("Expected no episode") }
        catch { XCTAssertEqual(error as? LibraryPlaybackError, .noEpisode) }
        XCTAssertEqual(calls, 0)
    }

    func testPlayDisambiguatesDuplicateTitlesAndPreservesQueueAndProgress() async throws {
        let enabled = LibrarySearchIndex.isEnabled
        defer { UserDefaults.standard.set(enabled, forKey: LibrarySearchIndex.enabledKey) }
        UserDefaults.standard.set(true, forKey: LibrarySearchIndex.enabledKey)
        let container = try ModelContainerFactory.makeInMemory()
        let context = container.mainContext
        var episodes: [Episode] = []
        for name in ["a", "b"] {
            let show = Podcast(feedURL: "https://\(name).example/feed", title: "Same show title")
            let episode = Episode(guid: "shared-guid", title: "Same episode title", audioURL: "https://example.com/audio")
            context.insert(show); context.insert(episode)
            episode.podcast = show
            episode.positionSeconds = 90
            episodes.append(episode)
        }
        context.insert(QueueItem(episode: episodes[0], position: 0))
        try context.save()
        let runtime = await readyRuntime(container)
        var played: Episode?
        let bridge = LibraryPlaybackBridge(start: { _, episode in played = episode })
        bridge.install(runtime: runtime)
        try await bridge.play(id: SearchContent.identifier(feedURL: "https://b.example/feed", guid: "shared-guid"))
        XCTAssertEqual(played?.persistentModelID, episodes[1].persistentModelID)
        XCTAssertEqual(episodes[1].positionSeconds, 90)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<QueueItem>()), 1)
        XCTAssertNil(episodes[1].queueItem)
        XCTAssertEqual(runtime.player.nowPlayingEpisode, nil)
    }

    func testResumeWorksWithContentSearchOffAndDoesNotToggleActivePlayback() async throws {
        let enabled = LibrarySearchIndex.isEnabled
        defer { UserDefaults.standard.set(enabled, forKey: LibrarySearchIndex.enabledKey) }
        UserDefaults.standard.set(false, forKey: LibrarySearchIndex.enabledKey)
        let container = try ModelContainerFactory.makeInMemory()
        let audio = try makeAudio()
        defer { try? FileManager.default.removeItem(at: audio) }
        let episode = Episode(guid: "one", title: "Paused", audioURL: audio.absoluteString)
        container.mainContext.insert(episode)
        try container.mainContext.save()
        let runtime = await readyRuntime(container)
        runtime.player.load(episode)
        var calls = 0
        let bridge = LibraryPlaybackBridge(continuePlayback: { player in
            calls += 1
            player.resume()
        })
        bridge.install(runtime: runtime)
        try await bridge.resume()
        try await bridge.resume()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(runtime.player.nowPlayingEpisodeID, episode.persistentModelID)
        runtime.player.releasePersistence()
    }

    func testPlayRejectsDisabledSearchBeforeStartingRuntime() async throws {
        let enabled = LibrarySearchIndex.isEnabled
        defer { UserDefaults.standard.set(enabled, forKey: LibrarySearchIndex.enabledKey) }
        UserDefaults.standard.set(false, forKey: LibrarySearchIndex.enabledKey)
        let runtime = AppRuntime(mode: .testHost)
        let bridge = LibraryPlaybackBridge(start: { _, _ in XCTFail("Should not play") })
        bridge.install(runtime: runtime)
        do { try await bridge.play(id: "missing"); XCTFail("Expected opt-out") }
        catch { XCTAssertEqual(error as? LibraryPlaybackError, .searchDisabled) }
        XCTAssertEqual(runtime.launchAttemptCount, 0)
    }

    func testSetupMustBeCompleteBeforeResuming() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let runtime = await readyRuntime(container, onboarding: false)
        let bridge = LibraryPlaybackBridge(continuePlayback: { _ in XCTFail("Should not resume") })
        bridge.install(runtime: runtime)
        do { try await bridge.resume(); XCTFail("Expected setup error") }
        catch { XCTAssertEqual(error as? LibraryPlaybackError, .finishSetup) }
    }

    func testCancelledResumeDoesNotStartPlayback() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let runtime = AppRuntime(load: .ready(container), mode: .testHost)
        let bridge = LibraryPlaybackBridge(continuePlayback: { _ in XCTFail("Should not resume") })
        bridge.install(runtime: runtime)
        let task = Task { try await bridge.resume() }
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testRealPlaybackPreservesSavedPositionAndQueue() async throws {
        let enabled = LibrarySearchIndex.isEnabled
        defer { UserDefaults.standard.set(enabled, forKey: LibrarySearchIndex.enabledKey) }
        UserDefaults.standard.set(true, forKey: LibrarySearchIndex.enabledKey)
        let audio = try makeAudio()
        defer { try? FileManager.default.removeItem(at: audio) }
        let container = try ModelContainerFactory.makeInMemory()
        let show = Podcast(feedURL: "https://example.com/feed", title: "Show")
        let episode = Episode(guid: "saved", title: "Saved episode", audioURL: audio.absoluteString)
        container.mainContext.insert(show)
        container.mainContext.insert(episode)
        episode.podcast = show
        episode.positionSeconds = 30
        let queued = Episode(guid: "queued", title: "Queued", audioURL: audio.absoluteString)
        container.mainContext.insert(queued)
        container.mainContext.insert(QueueItem(episode: queued, position: 0))
        try container.mainContext.save()
        let runtime = await readyRuntime(container)
        defer { runtime.player.releasePersistence() }
        let bridge = LibraryPlaybackBridge()
        bridge.install(runtime: runtime)
        try await bridge.play(id: SearchContent.identifier(feedURL: show.feedURL, guid: episode.guid))
        XCTAssertEqual(runtime.player.nowPlayingEpisodeID, episode.persistentModelID)
        XCTAssertEqual(runtime.player.currentPositionSeconds, 30, accuracy: 1)
        XCTAssertTrue(runtime.player.hasActivePlaybackRequest)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<QueueItem>()), 1)
        XCTAssertNotNil(queued.queueItem)
        XCTAssertNil(episode.queueItem)
    }

    func testResumeWaitsUntilRootServicesFinish() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let audio = try makeAudio()
        defer { try? FileManager.default.removeItem(at: audio) }
        let episode = Episode(guid: "waiting", title: "Waiting", audioURL: audio.absoluteString)
        container.mainContext.insert(episode)
        let runtime = AppRuntime(load: .ready(container), mode: .testHost)
        var calls = 0
        let bridge = LibraryPlaybackBridge(continuePlayback: { _ in calls += 1 })
        bridge.install(runtime: runtime)
        let request = Task { try await bridge.resume() }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(calls, 0)
        _ = await runtime.activateRootServices(for: container) {
            runtime.player.configure(context: container.mainContext)
            runtime.settings.configure(context: container.mainContext)
            runtime.settings.onboardingComplete = true
            runtime.player.load(episode)
        }
        defer { runtime.player.releasePersistence() }
        try await request.value
        XCTAssertEqual(calls, 1)
    }

    func testPlaybackRejectedWhileResetWaitsForRefreshCancellation() async throws {
        let enabled = LibrarySearchIndex.isEnabled
        defer { UserDefaults.standard.set(enabled, forKey: LibrarySearchIndex.enabledKey) }
        UserDefaults.standard.set(true, forKey: LibrarySearchIndex.enabledKey)
        let container = try ModelContainerFactory.makeInMemory()
        let runtime = AppRuntime(load: .ready(container), mode: .testHost, fileResetOperation: { false })
        _ = await runtime.activateRootServices(for: container) {
            runtime.player.configure(context: container.mainContext)
            runtime.settings.configure(context: container.mainContext)
            runtime.settings.onboardingComplete = true
        }
        var releaseRefresh: CheckedContinuation<Void, Never>?
        let refresh = Task {
            await BackgroundFeedRefresher.runUserInitiatedRefresh(trigger: .manualToolbar, total: 0) {
                await withCheckedContinuation { releaseRefresh = $0 }
                return SubscriptionRefreshReport(notifications: [], attempted: 0, total: 0,
                    succeeded: 0, failed: 0, cancelled: true, intendedInsertions: 0, durableInsertions: 0)
            }
        }
        while releaseRefresh == nil { await Task.yield() }
        let reset = Task { await runtime.resetLocalData() }
        while !runtime.isResettingLocalData { await Task.yield() }
        XCTAssertTrue(runtime.readyContainer === container)
        XCTAssertEqual(runtime.rootServiceActivationStatus, .completed)
        let bridge = LibraryPlaybackBridge(start: { _, _ in XCTFail("Playback during reset") })
        bridge.install(runtime: runtime)
        do { try await bridge.play(id: "anything"); XCTFail("Expected reset rejection") }
        catch { XCTAssertEqual(error as? LibraryIntentError, .notReady) }
        do { try await bridge.resume(); XCTFail("Expected reset rejection") }
        catch { XCTAssertEqual(error as? LibraryIntentError, .notReady) }
        releaseRefresh?.resume()
        _ = await refresh.value
        _ = await reset.value
    }

    func testExplicitPauseAndUnloadCancelPendingListeningDonation() async throws {
        let contentEnabled = LibrarySearchIndex.isEnabled
        let listeningEnabled = UserDefaults.standard.bool(forKey: ListeningDonations.enabledKey)
        defer {
            UserDefaults.standard.set(contentEnabled, forKey: LibrarySearchIndex.enabledKey)
            UserDefaults.standard.set(listeningEnabled, forKey: ListeningDonations.enabledKey)
        }
        UserDefaults.standard.set(true, forKey: LibrarySearchIndex.enabledKey)
        UserDefaults.standard.set(true, forKey: ListeningDonations.enabledKey)
        let audio = try makeAudio()
        defer { try? FileManager.default.removeItem(at: audio) }
        let container = try ModelContainerFactory.makeInMemory()
        let show = Podcast(feedURL: "https://example.com/feed", title: "Show")
        let episode = Episode(guid: "selected", title: "Selected", audioURL: audio.absoluteString)
        container.mainContext.insert(show)
        container.mainContext.insert(episode)
        episode.podcast = show
        try container.mainContext.save()
        let runtime = await readyRuntime(container)
        defer { runtime.player.stopAndUnload(); runtime.player.releasePersistence() }
        runtime.player.playFromEpisodeList(episode)
        XCTAssertNotNil(runtime.player.pendingListeningDonationID)
        runtime.player.pause()
        XCTAssertNil(runtime.player.pendingListeningDonationID)
        runtime.player.resume()
        XCTAssertNil(runtime.player.pendingListeningDonationID)
        runtime.player.playFromEpisodeList(episode)
        XCTAssertNotNil(runtime.player.pendingListeningDonationID)
        runtime.player.stopAndUnload()
        XCTAssertNil(runtime.player.pendingListeningDonationID)
        runtime.player.playFromEpisodeList(episode)
        XCTAssertNotNil(runtime.player.pendingListeningDonationID)
        runtime.player.cancelPendingCleartextPlayback()
        XCTAssertNil(runtime.player.pendingListeningDonationID)
        runtime.player.playWithHandoff(episode)
        XCTAssertNil(runtime.player.pendingListeningDonationID, "Siri's entry point must not create a manual donation")
    }

    private func makeAudio() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "EarshotIntent-\(UUID().uuidString).wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000 * 120))
        buffer.frameLength = buffer.frameCapacity
        buffer.floatChannelData?[0].initialize(repeating: 0, count: Int(buffer.frameLength))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

}
