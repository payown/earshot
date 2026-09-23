import XCTest
import SwiftData
@testable import Earshot

@MainActor
final class AppIconBadgeTests: XCTestCase {
    func testPreferenceIsOffByDefaultDeviceLocalAndPersists() {
        let context = TestStore.freshContext()
        let settings = SettingsStore()
        settings.configure(context: context)
        XCTAssertFalse(settings.badgeDownloadedUnheardEpisodes)
        XCTAssertTrue(AppSettingScope.isLocal(SettingsKey.badgeDownloadedUnheardEpisodes))
        settings.badgeDownloadedUnheardEpisodes = true
        let reopened = SettingsStore()
        reopened.configure(context: context)
        XCTAssertTrue(reopened.badgeDownloadedUnheardEpisodes)
    }

    func testCountUsesCompletedCompositeKeysAndPlayedStateOffMain() async throws {
        let context = TestStore.freshContext()
        var episodes: [Episode] = []
        var rows: [LocalEpisodeState] = []
        for index in 0..<5 {
            let show = Podcast(feedURL: "https://example.com/\(index)", title: "Show")
            context.insert(show)
            let episode = Episode(guid: "shared", title: "Episode", audioURL: "https://example.com/audio")
            context.insert(episode)
            episode.podcast = show
            episode.isPlayed = index == 1
            let row = LocalEpisodeState(podcastFeedURL: show.feedURL, episodeGUID: episode.guid,
                downloadStatus: index == 2 ? .downloading : .downloaded,
                downloadPath: index == 3 ? nil : "audio.mp3")
            context.insert(row)
            episodes.append(episode)
            rows.append(row)
        }
        context.insert(LocalEpisodeState(podcastFeedURL: "https://example.com/0", episodeGUID: "shared", downloadStatus: .downloaded, downloadPath: "duplicate.mp3"))
        context.insert(LocalEpisodeState(podcastFeedURL: "https://example.com/orphan", episodeGUID: "shared", downloadStatus: .downloaded, downloadPath: "orphan.mp3"))
        // Requeue preserves playedAt but changes status; this is still heard.
        episodes[1].status = .inQueue
        try context.save()
        let first = try await AppIconBadgeCount.load(container: context.container)
        XCTAssertEqual(first.count, 2)
        XCTAssertFalse(first.executedStoreWorkOnMainThread)
        episodes[0].isPlayed = true
        rows[4].downloadPath = nil
        rows[4].downloadStatus = .none
        try context.save()
        let completed = try await AppIconBadgeCount.load(container: context.container)
        XCTAssertEqual(completed.count, 0)
        episodes[0].isPlayed = false
        try context.save()
        let replayable = try await AppIconBadgeCount.load(container: context.container)
        XCTAssertEqual(replayable.count, 1)
    }

    func testSaveMetadataIgnoresPlaybackButIncludesDownloadInsertUpdateDelete() throws {
        let context = TestStore.freshContext()
        let row = LocalEpisodeState(podcastFeedURL: "https://example.com/feed", episodeGUID: "one")
        let episode = Episode(guid: "one", title: "One", audioURL: "https://example.com/audio")
        context.insert(row)
        context.insert(episode)
        try context.save()
        for key in [ModelContext.NotificationKey.insertedIdentifiers, .updatedIdentifiers, .deletedIdentifiers] {
            let local = Notification(name: ModelContext.didSave, userInfo: [key.rawValue: [row.persistentModelID]])
            XCTAssertTrue(AppIconBadgeCount.downloadsChanged(local))
            let playback = Notification(name: ModelContext.didSave, userInfo: [key.rawValue: [episode.persistentModelID]])
            XCTAssertFalse(AppIconBadgeCount.downloadsChanged(playback))
        }
    }

    func testRealSaveNotificationsDetectLocalChangesOnly() throws {
        let context = TestStore.freshContext()
        let observed = BadgeSaveObservations()
        let token = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: context, queue: nil) {
            observed.append(AppIconBadgeCount.downloadsChanged($0))
        }
        defer { NotificationCenter.default.removeObserver(token) }
        let episode = Episode(guid: "one", title: "One", audioURL: "https://example.com/audio")
        context.insert(episode)
        try context.save()
        let row = LocalEpisodeState(podcastFeedURL: "https://example.com/feed", episodeGUID: "one")
        context.insert(row)
        try context.save()
        row.downloadPath = "file.mp3"
        try context.save()
        episode.positionSeconds = 15
        try context.save()
        context.delete(row)
        try context.save()
        XCTAssertEqual(observed.values, [false, true, true, false, true])
    }

    func testDisabledDoesNoCountWorkOrPermissionRequest() async {
        let badge = BadgeSpy()
        let counter = CountSpy()
        let controller = AppIconBadgeController(badge: badge) { await counter.load() }
        controller.refresh(enabled: false)
        await controller.waitUntilIdle()
        let calls = await counter.calls
        let counts = await badge.counts
        let permissions = await badge.permissions
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(counts, [0])
        XCTAssertEqual(permissions, 0)
    }

    func testOptOutDuringLoadDiscardsStaleCount() async {
        let badge = BadgeSpy()
        let gate = CountGate()
        let controller = AppIconBadgeController(badge: badge) { await gate.load() }
        controller.refresh(enabled: true)
        await gate.waitForLoad()
        controller.refresh(enabled: false)
        await gate.finish()
        await controller.waitUntilIdle()
        let counts = await badge.counts
        XCTAssertEqual(counts, [0])
    }

    func testOptOutDuringWriteClearsAfterInFlightWrite() async {
        let badge = BadgeSpy(blockFirstWrite: true)
        let controller = AppIconBadgeController(badge: badge) { 7 }
        controller.refresh(enabled: true)
        await badge.waitForWrite()
        controller.refresh(enabled: false)
        await badge.finishWrite()
        await controller.waitUntilIdle()
        let counts = await badge.counts
        XCTAssertEqual(counts, [7, 0])
    }

    func testFailedCountRetainsBadgeAndLaterEventRetries() async {
        let badge = BadgeSpy()
        let loader = FailingCount()
        let controller = AppIconBadgeController(badge: badge) { try await loader.load() }
        controller.refresh(enabled: true)
        await controller.waitUntilIdle()
        var counts = await badge.counts
        XCTAssertEqual(counts, [])
        controller.refresh(enabled: true)
        await controller.waitUntilIdle()
        counts = await badge.counts
        XCTAssertEqual(counts, [3])
    }
}

private actor CountSpy {
    var calls = 0
    func load() -> Int { calls += 1; return 5 }
}
private actor FailingCount {
    enum Failure: Error { case store }
    var failed = false
    func load() throws -> Int {
        if !failed { failed = true; throw Failure.store }
        return 3
    }
}
private actor CountGate {
    var continuation: CheckedContinuation<Int, Never>?
    func load() async -> Int { await withCheckedContinuation { continuation = $0 } }
    func waitForLoad() async { while continuation == nil { await Task.yield() } }
    func finish() { continuation?.resume(returning: 9); continuation = nil }
}
private actor BadgeSpy: AppIconBadging {
    var counts: [Int] = []
    var permissions = 0
    var blockFirstWrite: Bool
    var continuation: CheckedContinuation<Void, Never>?
    init(blockFirstWrite: Bool = false) { self.blockFirstWrite = blockFirstWrite }
    func requestPermission() -> Bool { permissions += 1; return true }
    func setCount(_ count: Int) async {
        counts.append(count)
        if blockFirstWrite {
            blockFirstWrite = false
            await withCheckedContinuation { continuation = $0 }
        }
    }
    func waitForWrite() async { while continuation == nil { await Task.yield() } }
    func finishWrite() { continuation?.resume(); continuation = nil }
}

private final class BadgeSaveObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Bool] = []
    var values: [Bool] { lock.withLock { stored } }
    func append(_ value: Bool) { lock.withLock { stored.append(value) } }
}
