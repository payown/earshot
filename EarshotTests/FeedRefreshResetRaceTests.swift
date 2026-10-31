import SwiftData
import XCTest
import Darwin
@testable import Earshot

private actor InFlightFeedFetcher: FeedFetching {
    private let feed: ParsedFeed
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var observedCancellation = false

    init(feed: ParsedFeed) { self.feed = feed }

    func fetch(_ urlString: String) async throws -> ParsedFeed {
        started = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .milliseconds(5))
            } catch {
                observedCancellation = true
                throw error
            }
        }
        observedCancellation = true
        throw CancellationError()
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func wasCancelledByOwner() -> Bool { observedCancellation }
}

private actor LaunchOperationGate {
    private var started = false
    private var released = false
    private var cancellationObserved = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var cancellationTimeoutTasks: [UUID: Task<Void, Never>] = [:]
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func holdOperationUntilReleased() async {
        started = true
        let pending = startWaiters
        startWaiters.removeAll()
        for waiter in pending { waiter.resume() }

        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if released {
                    continuation.resume()
                } else {
                    releaseContinuation = continuation
                }
            }
        } onCancel: {
            Task { await self.markCancellationObserved() }
        }
    }

    private func markCancellationObserved() {
        cancellationObserved = true
        let pending = cancellationWaiters
        cancellationWaiters.removeAll()
        for (id, waiter) in pending {
            cancellationTimeoutTasks.removeValue(forKey: id)?.cancel()
            waiter.resume(returning: true)
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func waitUntilCancelled(timeout: Duration = .seconds(5)) async -> Bool {
        guard !cancellationObserved else { return true }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            cancellationWaiters[id] = continuation
            cancellationTimeoutTasks[id] = Task { [weak self] in
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                await self?.finishCancellationWaiter(id)
            }
        }
    }

    private func finishCancellationWaiter(_ id: UUID) {
        guard let waiter = cancellationWaiters.removeValue(forKey: id) else { return }
        cancellationTimeoutTasks[id] = nil
        waiter.resume(returning: cancellationObserved)
    }

    func release() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor LaunchContainerCapture {
    private var container: ModelContainer?
    func set(_ container: ModelContainer) { self.container = container }
    func get() -> ModelContainer? { container }
}

private enum ResetRaceFixtureError: Error {
    case storeUnavailable
}

private actor OneFailedRefreshFeed: FeedFetching {
    let feed: ParsedFeed

    init(feed: ParsedFeed) { self.feed = feed }

    func fetch(_ urlString: String) async throws -> ParsedFeed {
        if urlString.contains("failed") { throw URLError(.cannotConnectToHost) }
        return feed
    }
}

private actor CountingRefreshFeed: FeedFetching {
    private let feed: ParsedFeed
    private var requests = 0
    init(feed: ParsedFeed) { self.feed = feed }
    func fetch(_ urlString: String) async throws -> ParsedFeed {
        requests += 1
        return feed
    }
    func requestCount() -> Int { requests }
}

@MainActor
final class FeedRefreshResetRaceTests: XCTestCase {
    func testFollowedStoreLoadFailureDoesNotAdvanceRefreshTimestamp() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        container.mainContext.insert(Podcast(feedURL: "https://example.com/feed.xml", title: "Show"))
        let settings = AppSettingsStore(context: container.mainContext)
        let previous = Date(timeIntervalSince1970: 1_700_000_000)
        settings.setDate(previous, for: SettingsKey.lastFeedRefresh)
        try container.mainContext.save()
        let parsed = ParsedFeed(title: "Unexpected", artworkURL: nil, description: nil, author: nil,
                                websiteURL: nil, language: nil, category: nil, episodes: [])
        let fetcher = CountingRefreshFeed(feed: parsed)

        let didComplete = await BackgroundFeedRefresher.runRefresh(
            container: container, trigger: .backgroundTask, force: true, feed: fetcher,
            refreshActorFactory: { container in
                let actor = await FeedRefreshActor.makeBackground(modelContainer: container)
                await actor.forceFollowedFetchFailureForTesting()
                return actor
            }
        )

        XCTAssertFalse(didComplete)
        XCTAssertEqual(settings.date(SettingsKey.lastFeedRefresh), previous)
        let requests = await fetcher.requestCount()
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(FeedRefreshStatusMonitor.shared.snapshot.state, .failed)
    }

    func testEmptyLibraryRemainsSuccessfulAndAdvancesRefreshTimestamp() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let parsed = ParsedFeed(title: "Unexpected", artworkURL: nil, description: nil, author: nil,
                                websiteURL: nil, language: nil, category: nil, episodes: [])
        let fetcher = CountingRefreshFeed(feed: parsed)
        let didComplete = await BackgroundFeedRefresher.runRefresh(
            container: container, trigger: .backgroundTask, force: true, feed: fetcher
        )
        XCTAssertTrue(didComplete)
        XCTAssertNotNil(AppSettingsStore(context: container.mainContext).date(SettingsKey.lastFeedRefresh))
        let requests = await fetcher.requestCount()
        XCTAssertEqual(requests, 0)
    }

    func testCompletedPassWithOneFeedErrorStillStampsThrottle() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        container.mainContext.insert(Podcast(
            feedURL: "https://example.com/good.xml", title: "Good"
        ))
        container.mainContext.insert(Podcast(
            feedURL: "https://example.com/failed.xml", title: "Failed"
        ))
        try container.mainContext.save()
        let parsed = ParsedFeed(
            title: "Example", artworkURL: nil, description: nil, author: nil,
            websiteURL: nil, language: nil, category: nil, episodes: []
        )

        let didComplete = await BackgroundFeedRefresher.runRefresh(
            container: container,
            trigger: .backgroundTask,
            force: true,
            notifier: NotificationService(),
            feed: OneFailedRefreshFeed(feed: parsed)
        )

        XCTAssertTrue(didComplete)
        XCTAssertNotNil(AppSettingsStore(context: container.mainContext).date(
            SettingsKey.lastFeedRefresh
        ))
        XCTAssertEqual(FeedRefreshStatusMonitor.shared.snapshot.state, .completedWithErrors)
        XCTAssertEqual(
            FeedRefreshStatusMonitor.shared.snapshot.failureDetails.map(\.podcastTitle),
            ["Failed"]
        )
    }

    func testManualRefreshCannotOverlapAutomaticRefresh() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        container.mainContext.insert(
            Podcast(feedURL: "https://example.com/feed.xml", title: "Example")
        )
        try container.mainContext.save()
        let feed = ParsedFeed(
            title: "Example", artworkURL: nil, description: nil, author: nil,
            websiteURL: nil, language: nil, category: nil, episodes: []
        )
        let fetcher = InFlightFeedFetcher(feed: feed)
        let automatic = Task { @MainActor in
            await BackgroundFeedRefresher.runRefresh(
                container: container, trigger: .coldLaunch, force: true,
                notifier: NotificationService(), feed: fetcher
            )
        }
        await fetcher.waitUntilStarted()
        XCTAssertTrue(BackgroundFeedRefresher.isRefreshInProgress)

        var manualOperationRan = false
        let manualReport = await BackgroundFeedRefresher.runUserInitiatedRefresh(
            trigger: .manualToolbar,
            total: 1
        ) {
            manualOperationRan = true
            return SubscriptionRefreshReport(
                notifications: [], attempted: 0, total: 0, succeeded: 0,
                failed: 0, cancelled: false, intendedInsertions: 0,
                durableInsertions: 0
            )
        }

        XCTAssertNil(manualReport)
        XCTAssertFalse(manualOperationRan)
        await BackgroundFeedRefresher.cancelAndWait()
        _ = await automatic.value
        XCTAssertFalse(BackgroundFeedRefresher.isRefreshInProgress)
    }

    func testThrottledForegroundWakePreservesCompletedStatus() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        container.mainContext.insert(
            Podcast(feedURL: "https://example.com/feed.xml", title: "Example")
        )
        let settings = AppSettingsStore(context: container.mainContext)
        settings.setDate(Date(), for: SettingsKey.lastFeedRefresh)
        try container.mainContext.save()
        let monitor = FeedRefreshStatusMonitor.shared
        monitor.configure(context: TestStore.freshContext())
        defer { monitor.releasePersistence() }
        monitor.start(trigger: .backgroundTask, total: 1)
        monitor.finish(SubscriptionRefreshReport(
            notifications: [], attempted: 1, total: 1, succeeded: 1,
            failed: 0, cancelled: false, intendedInsertions: 0,
            durableInsertions: 0
        ))

        let didRun = await BackgroundFeedRefresher.runRefresh(
            container: container,
            trigger: .foreground
        )

        XCTAssertFalse(didRun)
        XCTAssertEqual(monitor.snapshot.state, .completed)
        XCTAssertEqual(monitor.snapshot.checked, 1)
        XCTAssertEqual(monitor.snapshot.total, 1)
        XCTAssertEqual(monitor.snapshot.lastSkippedTrigger, .foreground)
    }

    func testCancellationBeforeRefreshStartPreservesCompletedStatus() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        container.mainContext.insert(
            Podcast(feedURL: "https://example.com/feed.xml", title: "Example")
        )
        try container.mainContext.save()
        let monitor = FeedRefreshStatusMonitor.shared
        monitor.configure(context: TestStore.freshContext())
        defer { monitor.releasePersistence() }
        monitor.start(trigger: .backgroundTask, total: 1)
        monitor.finish(SubscriptionRefreshReport(
            notifications: [], attempted: 1, total: 1, succeeded: 1,
            failed: 0, cancelled: false, intendedInsertions: 0,
            durableInsertions: 0
        ))

        let didRun = await BackgroundFeedRefresher.runRefresh(
            container: container,
            trigger: .foreground,
            force: true,
            isCancelled: { true }
        )

        XCTAssertFalse(didRun)
        XCTAssertEqual(monitor.snapshot.state, .completed)
        XCTAssertEqual(monitor.snapshot.checked, 1)
        XCTAssertEqual(monitor.snapshot.total, 1)
    }

    func testManualRefreshPublishesKnownTotalBeforeOperationAndFinishes() async {
        let monitor = FeedRefreshStatusMonitor.shared
        monitor.configure(context: TestStore.freshContext())
        defer { monitor.releasePersistence() }
        var observedRunningSnapshot: FeedRefreshStatusSnapshot?

        let report = await BackgroundFeedRefresher.runUserInitiatedRefresh(
            trigger: .manualPullToRefresh,
            total: 64
        ) {
            observedRunningSnapshot = monitor.snapshot
            return SubscriptionRefreshReport(
                notifications: [], attempted: 64, total: 64, succeeded: 64,
                failed: 0, cancelled: false, intendedInsertions: 0,
                durableInsertions: 0
            )
        }

        XCTAssertNotNil(report)
        XCTAssertEqual(observedRunningSnapshot?.state, .running)
        XCTAssertEqual(observedRunningSnapshot?.checked, 0)
        XCTAssertEqual(observedRunningSnapshot?.total, 64)
        XCTAssertEqual(monitor.snapshot.state, .completed)
        XCTAssertEqual(monitor.snapshot.checked, 64)
        XCTAssertEqual(monitor.snapshot.total, 64)
    }

    func testSceneBackgroundCancellationStopsInFlightForegroundRefresh() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        container.mainContext.insert(
            Podcast(feedURL: "https://example.com/feed.xml", title: "Example")
        )
        try container.mainContext.save()
        let feed = ParsedFeed(
            title: "Example", artworkURL: nil, description: nil, author: nil,
            websiteURL: nil, language: nil, category: nil, episodes: []
        )
        let fetcher = InFlightFeedFetcher(feed: feed)
        let refresh = Task { @MainActor in
            await BackgroundFeedRefresher.runRefresh(
                container: container, trigger: .foreground, force: true,
                notifier: NotificationService(), feed: fetcher
            )
        }
        await fetcher.waitUntilStarted()

        BackgroundFeedRefresher.cancelForSceneBackground()

        let result = await refresh.value
        XCTAssertFalse(result)
    }

    func testCancellingAutomaticRefreshCallerStopsItsOwnedWorkAndReleasesGate() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        container.mainContext.insert(Podcast(feedURL: "https://example.com/feed.xml", title: "Example"))
        try container.mainContext.save()
        let feed = ParsedFeed(
            title: "Example", artworkURL: nil, description: nil, author: nil,
            websiteURL: nil, language: nil, category: nil, episodes: []
        )
        let fetcher = InFlightFeedFetcher(feed: feed)
        let refresh = Task { @MainActor in
            await BackgroundFeedRefresher.runRefresh(
                container: container, trigger: .backgroundTask, force: true,
                isCancelled: { false }, notifier: NotificationService(), feed: fetcher
            )
        }
        await fetcher.waitUntilStarted()

        refresh.cancel()
        let result = await refresh.value
        let cancelled = await fetcher.wasCancelledByOwner()
        XCTAssertFalse(result)
        XCTAssertTrue(cancelled)
        XCTAssertFalse(BackgroundFeedRefresher.isRefreshInProgress)

        let subsequent = await BackgroundFeedRefresher.runUserInitiatedRefresh(
            trigger: .manualToolbar, total: 0
        ) {
            SubscriptionRefreshReport(
                notifications: [], attempted: 0, total: 0, succeeded: 0,
                failed: 0, cancelled: false, intendedInsertions: 0, durableInsertions: 0
            )
        }
        XCTAssertNotNil(subsequent)
    }

    func testCancellingOverlappingCallerDoesNotCancelActiveRefresh() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        container.mainContext.insert(Podcast(feedURL: "https://example.com/feed.xml", title: "Example"))
        try container.mainContext.save()
        let feed = ParsedFeed(
            title: "Example", artworkURL: nil, description: nil, author: nil,
            websiteURL: nil, language: nil, category: nil, episodes: []
        )
        let fetcher = InFlightFeedFetcher(feed: feed)
        let owner = Task { @MainActor in
            await BackgroundFeedRefresher.runRefresh(
                container: container, trigger: .backgroundTask, force: true,
                isCancelled: { false }, notifier: NotificationService(), feed: fetcher
            )
        }
        await fetcher.waitUntilStarted()
        let overlap = Task { @MainActor in
            await BackgroundFeedRefresher.runRefresh(container: container, force: true)
        }
        overlap.cancel()
        let overlapResult = await overlap.value
        let cancelled = await fetcher.wasCancelledByOwner()
        XCTAssertFalse(overlapResult)
        XCTAssertFalse(cancelled)
        XCTAssertTrue(BackgroundFeedRefresher.isRefreshInProgress)
        await BackgroundFeedRefresher.cancelAndWait()
        _ = await owner.value
    }

    func testSceneBackgroundCancellationPreservesOSBackgroundRefresh() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        container.mainContext.insert(
            Podcast(feedURL: "https://example.com/feed.xml", title: "Example")
        )
        try container.mainContext.save()
        let feed = ParsedFeed(
            title: "Example", artworkURL: nil, description: nil, author: nil,
            websiteURL: nil, language: nil, category: nil, episodes: []
        )
        let fetcher = InFlightFeedFetcher(feed: feed)
        let refresh = Task { @MainActor in
            await BackgroundFeedRefresher.runRefresh(
                container: container, trigger: .backgroundTask, force: true,
                isCancelled: { false }, notifier: NotificationService(), feed: fetcher
            )
        }
        await fetcher.waitUntilStarted()

        BackgroundFeedRefresher.cancelForSceneBackground()
        await Task.yield()
        let cancelledByScene = await fetcher.wasCancelledByOwner()
        XCTAssertFalse(cancelledByScene)
        await BackgroundFeedRefresher.cancelAndWait()

        _ = await refresh.value
        // If scene cancellation incorrectly owned the BGTask, Task cancellation
        // above is redundant but still lets this bounded fake return. The actor
        // must have remained active until its true owner cancelled it.
        let cancelledByOwner = await fetcher.wasCancelledByOwner()
        XCTAssertTrue(cancelledByOwner)
    }

    func testLaunchCannotRaceResetAgainstSameDisposableStore() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "EarshotLaunchResetRace-\(UUID().uuidString)", directoryHint: .isDirectory)
        let applicationSupport = root.appending(path: "Application Support", directoryHint: .isDirectory)
        let documents = root.appending(path: "Documents", directoryHint: .isDirectory)
        let caches = root.appending(path: "Caches", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let primary = applicationSupport.appending(path: "default.store")
        let sentinelFeedURL = "https://reset-fixture.example/podcast.xml"
        let sentinelSettingKey = "reset.fixture.sentinel"
        try await seedDisposableStore(
            at: primary,
            feedURL: sentinelFeedURL,
            settingKey: sentinelSettingKey
        )

        let launchGate = LaunchOperationGate()
        let launchContainerCapture = LaunchContainerCapture()
        let launchOperation: StoreLaunchOperation = { _ in
            await launchGate.holdOperationUntilReleased()
            let load = await ModelContainerFactory.makeShared(
                using: StoreMigrationEngine(), at: primary
            )
            if case .ready(let container) = load {
                await launchContainerCapture.set(container)
            }
            return load
        }
        let runtime = AppRuntime(
            mode: .testHost,
            launchOperation: launchOperation,
            replacementLoadOperation: {
                await ModelContainerFactory.makeShared(
                    using: StoreMigrationEngine(), at: primary
                )
            },
            fileResetOperation: {
                await SettingsReset.performFileReset(
                    applicationSupport: applicationSupport,
                    documents: documents,
                    caches: caches
                )
            }
        )

        runtime.startLaunchIfNeeded()
        await launchGate.waitUntilStarted()
        let resetTask = Task { await runtime.resetLocalData() }
        let cancellationObserved = await launchGate.waitUntilCancelled()
        XCTAssertTrue(cancellationObserved, "Reset must cancel the in-flight launch before awaiting it")
        XCTAssertTrue(runtime.isResettingLocalData,
                      "Reset should remain in progress while the launch operation is held")
        // Always unblock the deliberately non-cooperative launch operation,
        // even when reset stops cancelling it. That keeps a regression a bounded
        // assertion failure instead of leaving reset or the test hung.
        await launchGate.release()
        let reset = await resetTask.value

        XCTAssertTrue(reset)
        XCTAssertTrue(ModelContainerFactory.hasStoreFiles(at: primary))
        let replacement = try XCTUnwrap(runtime.readyContainer)
        let capturedLaunchContainer = await launchContainerCapture.get()
        let cancelledLaunchContainer = try XCTUnwrap(capturedLaunchContainer)
        XCTAssertFalse(replacement === cancelledLaunchContainer,
                       "The replacement container must supersede the cancelled launch result")
        let replacementSettings = AppSettingsStore(context: replacement.mainContext)
        XCTAssertTrue(replacementSettings.podcastCapGatingIntroduced())
        XCTAssertEqual(replacementSettings.grandfatheredPodcastCount(), 0)
        try assertResetSentinelsAbsent(
            from: replacement,
            feedURL: sentinelFeedURL,
            settingKey: sentinelSettingKey
        )
    }

    func testResetCancelsInFlightRefreshBeforeDisposableFileReset() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let context = container.mainContext
        context.insert(Podcast(feedURL: "https://example.com/feed.xml", title: "Example"))
        try context.save()

        let feed = ParsedFeed(
            title: "Example", artworkURL: nil, description: nil, author: nil,
            websiteURL: nil, language: nil, category: nil, episodes: []
        )
        let fetcher = InFlightFeedFetcher(feed: feed)
        let refresh = Task { @MainActor in
            await BackgroundFeedRefresher.runRefresh(
                container: container, force: true, notifier: NotificationService(), feed: fetcher
            )
        }
        await fetcher.waitUntilStarted()

        let root = FileManager.default.temporaryDirectory
            .appending(path: "EarshotFeedResetRace-\(UUID().uuidString)", directoryHint: .isDirectory)
        let applicationSupport = root.appending(path: "Application Support", directoryHint: .isDirectory)
        let documents = root.appending(path: "Documents", directoryHint: .isDirectory)
        let caches = root.appending(path: "Caches", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let primary = applicationSupport.appending(path: "default.store")
        let sentinelFeedURL = "https://reset-refresh-fixture.example/podcast.xml"
        let sentinelSettingKey = "reset.refresh.fixture.sentinel"
        try await seedDisposableStore(
            at: primary,
            feedURL: sentinelFeedURL,
            settingKey: sentinelSettingKey
        )

        let runtime = AppRuntime(
            mode: .testHost,
            replacementLoadOperation: {
                await ModelContainerFactory.makeShared(
                    using: StoreMigrationEngine(), at: primary
                )
            },
            fileResetOperation: {
                await SettingsReset.performFileReset(
                    applicationSupport: applicationSupport,
                    documents: documents,
                    caches: caches
                )
            }
        )

        let reset = await runtime.resetLocalData()
        let refreshResult = await refresh.value

        XCTAssertTrue(reset)
        XCTAssertFalse(refreshResult)
        XCTAssertTrue(ModelContainerFactory.hasStoreFiles(at: primary))
        let replacement = try XCTUnwrap(runtime.readyContainer)
        try assertResetSentinelsAbsent(
            from: replacement,
            feedURL: sentinelFeedURL,
            settingKey: sentinelSettingKey
        )
    }

    private func seedDisposableStore(
        at url: URL,
        feedURL: String,
        settingKey: String
    ) async throws {
        let load = await ModelContainerFactory.makeShared(
            using: StoreMigrationEngine(), at: url
        )
        guard case .ready(let container) = load else {
            throw ResetRaceFixtureError.storeUnavailable
        }
        container.mainContext.insert(Podcast(feedURL: feedURL, title: "Reset sentinel"))
        container.mainContext.insert(AppSetting(key: settingKey, value: "must be deleted"))
        try container.mainContext.save()
    }

    private func assertResetSentinelsAbsent(
        from container: ModelContainer,
        feedURL: String,
        settingKey: String
    ) throws {
        let podcasts = try container.mainContext.fetch(FetchDescriptor<Podcast>())
        XCTAssertFalse(podcasts.contains { $0.feedURL == feedURL },
                       "The replacement store must not retain the pre-reset podcast")
        XCTAssertNil(AppSettingsStore(context: container.mainContext).rawValue(settingKey),
                     "The replacement store must not retain the pre-reset setting")
    }

    func testFiveRunShippingResetTimingWithRefreshCancellationPath() async throws {
        var samples: [Double] = []
        var peaks: [Double] = []
        for run in 1...5 {
            let root = FileManager.default.temporaryDirectory
                .appending(path: "EarshotShippingReset-\(UUID().uuidString)", directoryHint: .isDirectory)
            let applicationSupport = root.appending(path: "Application Support", directoryHint: .isDirectory)
            let documents = root.appending(path: "Documents", directoryHint: .isDirectory)
            let caches = root.appending(path: "Caches", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let primary = applicationSupport.appending(path: "default.store")
            guard case .ready = await ModelContainerFactory.makeShared(
                using: StoreMigrationEngine(), at: primary
            ) else { return XCTFail("disposable store did not open") }
            let start = DispatchTime.now().uptimeNanoseconds
            let ok = await SettingsReset.performFileReset(
                applicationSupport: applicationSupport, documents: documents, caches: caches
            )
            guard ok else { return XCTFail("reset failed on run \(run)") }
            guard case .ready = await ModelContainerFactory.makeShared(
                using: StoreMigrationEngine(), at: primary
            ) else { return XCTFail("fresh store did not reopen on run \(run)") }
            let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            let peak = Double(usage.ru_maxrss) / 1_048_576
            samples.append(seconds)
            peaks.append(peak)
            print(String(format: "FEEDRESETTIMING|run|%d|seconds|%.9f|peakRSSMB|%.3f", run, seconds, peak))
        }
        let mean = samples.reduce(0, +) / Double(samples.count)
        let variance = samples.map { pow($0 - mean, 2) }.reduce(0, +) / Double(samples.count)
        let sd = sqrt(variance)
        print(String(format: "FEEDRESETSTATS|samples|%@|mean|%.9f|populationSD|%.9f|min|%.9f|max|%.9f|peakRSSMaxMB|%.3f", samples.map { String(format: "%.9f", $0) }.joined(separator: ","), mean, sd, samples.min()!, samples.max()!, peaks.max()!))
    }
}
