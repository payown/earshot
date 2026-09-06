import SQLite3
import SwiftData
import Synchronization
import XCTest
@testable import Earshot

private actor QueueApplicationRaceGate {
    private var isPaused = false
    private var isFinished = false
    private var pauseWaiters: [CheckedContinuation<Bool, Never>] = []
    private var resumeWaiter: CheckedContinuation<Void, Never>?

    func pause() async {
        guard !isFinished else { return }
        isPaused = true
        let waiters = pauseWaiters
        pauseWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: true) }
        await withCheckedContinuation { resumeWaiter = $0 }
    }

    func waitUntilPaused() async -> Bool {
        if isPaused { return true }
        if isFinished { return false }
        return await withCheckedContinuation { pauseWaiters.append($0) }
    }

    func resume() {
        isPaused = false
        resumeWaiter?.resume()
        resumeWaiter = nil
    }

    func finish() {
        isFinished = true
        isPaused = false
        let waiters = pauseWaiters
        pauseWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: false) }
        resumeWaiter?.resume()
        resumeWaiter = nil
    }
}

@MainActor
final class CloudProjectionCoordinatorTests: XCTestCase {
    func testProjectionOriginMarkerDistinguishesSelfGeneratedUIEvents() {
        let external = Notification(name: .earshotInboxDidChange)
        XCTAssertFalse(CloudProjectionCoordinator.isProjectionOriginated(external))

        let projected = Notification(
            name: .earshotInboxDidChange,
            userInfo: [CloudProjectionCoordinator.notificationOriginKey: true]
        )
        XCTAssertTrue(CloudProjectionCoordinator.isProjectionOriginated(projected))
    }

    func testBackgroundConstructionKeepsProjectionWorkFromBlockingMainActor() async throws {
        let app = try makeApplicationContainer()
        for index in 0..<2_000 {
            app.mainContext.insert(Podcast(
                feedURL: "https://background.example/\(index)",
                title: "Podcast \(index)"
            ))
        }
        try app.mainContext.save()
        let projection = try makeProjectionContainer()
        let coordinator = await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: app,
            projectionContainer: projection
        )
        let executorRunsOnMainThread = await coordinator.executorRunsOnMainThreadForTesting()
        XCTAssertFalse(
            executorRunsOnMainThread,
            "Cloud projection store work must never borrow VoiceOver's main thread"
        )

        let heartbeatState = Mutex((isFinished: false, count: 0))
        let heartbeat = Task { @MainActor in
            while heartbeatState.withLock({ state in
                guard !state.isFinished else { return false }
                state.count += 1
                return true
            }) {
                await Task.yield()
            }
        }
        await Task.yield()
        let countBeforeReconciliation = heartbeatState.withLock { $0.count }
        try await coordinator.reconcile()
        let countAfterReconciliation = heartbeatState.withLock { $0.count }
        heartbeatState.withLock { $0.isFinished = true }
        await heartbeat.value

        XCTAssertGreaterThan(countAfterReconciliation, countBeforeReconciliation)
    }

    /// Reproduces the build-204 failure shape: a cold catalog with 99 current
    /// subscriptions, 948 remote deletion tombstones left by Delete Everywhere,
    /// and one unusually large Podcast-to-Episodes relationship.
    /// This is opt-in because constructing 54,000 persisted Episodes is too
    /// expensive for every unit-test run; it is mandatory for release candidates.
    func testLargeMigratedLibraryFirstProjectionAndFolderReadStayBelowWatchdog() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUN_CLOUD_PROJECTION_SCALE"] != nil,
            "Set TEST_RUNNER_RUN_CLOUD_PROJECTION_SCALE=1 for the build-202 watchdog regression."
        )
        let root = FileManager.default.temporaryDirectory
            .appending(path: "cloud-watchdog-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let applicationURL = root.appending(path: "application.store")
        let localURL = root.appending(path: "local.store")
        let projectionURL = root.appending(path: "projection.store")
        let feedCount = 99
        let tombstoneCount = 948
        let largeFeedEpisodeCount = 12_000
        let ordinaryFeedEpisodeCount = 428

        do {
            let app = try makeOnDiskApplicationContainer(
                applicationURL: applicationURL,
                localURL: localURL
            )
            let context = app.mainContext
            let parent = PodcastFolder(name: "Imported", createdAt: Date(timeIntervalSince1970: 1))
            let child = PodcastFolder(name: "Large OPML", createdAt: Date(timeIntervalSince1970: 2))
            child.parent = parent
            context.insert(parent)
            context.insert(child)
            for feedIndex in 0..<feedCount {
                let podcast = Podcast(
                    feedURL: "https://scale.example/\(feedIndex)/feed",
                    title: String(format: "Show %03d", feedIndex)
                )
                context.insert(podcast)
                context.insert(FolderMembership(
                    folder: child,
                    podcast: podcast,
                    sortOrder: feedIndex
                ))
                let episodeCount = feedIndex == 0
                    ? largeFeedEpisodeCount : ordinaryFeedEpisodeCount
                for episodeIndex in 0..<episodeCount {
                    let episode = Episode(
                        guid: "\(feedIndex)-\(episodeIndex)",
                        title: "Episode \(episodeIndex)",
                        audioURL: "https://scale.example/\(feedIndex)/\(episodeIndex).mp3"
                    )
                    if feedIndex == 0, episodeIndex == 0 {
                        episode.positionSeconds = 120
                    }
                    episode.podcast = podcast
                    context.insert(episode)
                }
                if feedIndex.isMultiple(of: 5) { try context.save() }
            }
            try context.save()
        }

        let app = try makeOnDiskApplicationContainer(
            applicationURL: applicationURL,
            localURL: localURL
        )
        let projection = try makeOnDiskProjectionContainer(at: projectionURL)
        for feedIndex in 0..<feedCount {
            let row = CloudPodcastProjection()
            row.feedURL = "https://scale.example/\(feedIndex)/feed"
            row.title = String(format: "Show %03d", feedIndex)
            projection.mainContext.insert(row)
        }
        for index in 0..<tombstoneCount {
            let row = CloudPodcastProjection()
            row.feedURL = "https://deleted.example/\(index)/feed"
            row.title = "Deleted Show \(index)"
            row.deletedAt = Date(timeIntervalSince1970: 10)
            projection.mainContext.insert(row)
        }
        try projection.mainContext.save()

        let coordinator = await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: app,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "scale-phone"
        )
        let firstStarted = ContinuousClock.now
        try await coordinator.reconcile()
        let firstSeconds = secondsSince(firstStarted)
        let secondStarted = ContinuousClock.now
        try await coordinator.reconcile()
        let secondSeconds = secondsSince(secondStarted)
        let folders = try app.mainContext.fetch(FetchDescriptor<PodcastFolder>())
        let parent = try XCTUnwrap(folders.first { $0.name == "Imported" })
        let subscriptions = FolderRepository(context: app.mainContext)
            .subtreeSubscriptions(of: parent)
        let expectedEpisodeCount = largeFeedEpisodeCount
            + (feedCount - 1) * ordinaryFeedEpisodeCount

        XCTAssertEqual(subscriptions.count, feedCount)
        XCTAssertEqual(
            try app.mainContext.fetchCount(FetchDescriptor<Episode>()),
            expectedEpisodeCount
        )
        XCTAssertEqual(
            try projection.mainContext.fetchCount(FetchDescriptor<CloudPodcastProjection>()),
            feedCount + tombstoneCount
        )
        XCTAssertLessThan(
            firstSeconds,
            5,
            "First tombstone reconciliation consumed half the iOS scene watchdog budget"
        )
        XCTAssertLessThan(
            secondSeconds,
            5,
            "Repeated tombstone reconciliation consumed half the iOS scene watchdog budget"
        )
        print(String(format:
            "CLOUDWATCHDOG|feeds|%d|tombstones|%d|episodes|%d|firstSeconds|%.3f|secondSeconds|%.3f",
            feedCount, tombstoneCount, expectedEpisodeCount, firstSeconds, secondSeconds
        ))
    }

    private func secondsSince(_ start: ContinuousClock.Instant) -> Double {
        let components = (ContinuousClock.now - start).components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    func testDevelopmentSeedMarkersBracketDurableProjectionWithAllEntityCounts() async throws {
        let app = try makeApplicationContainer()
        app.mainContext.insert(Podcast(feedURL: "https://example.com/feed", title: "Show"))
        try app.mainContext.save()
        let projection = try makeProjectionContainer()
        let markers = Mutex<[CompactProjectionSeedMarker]>([])
        let coordinator = await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: app,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "phone",
            seedInstrumentationEnabled: { true },
            seedMarkerRecorder: { marker in markers.withLock { $0.append(marker) } }
        )

        try await coordinator.start()

        let recordedMarkers = markers.withLock { $0 }
        XCTAssertEqual(recordedMarkers.count, 2)
        guard case .start(let startRunID) = recordedMarkers[0],
              case .complete(let completeRunID, let duration, let counts) = recordedMarkers[1]
        else {
            return XCTFail("Expected one start marker followed by one completion marker")
        }
        XCTAssertEqual(startRunID, completeRunID)
        XCTAssertGreaterThanOrEqual(duration, 0)
        XCTAssertEqual(
            counts,
            CompactProjectionSeedCounts(
                podcasts: 1,
                episodeStates: 0,
                queueItems: 0,
                settings: 0,
                bookmarks: 0,
                listeningSessions: 0,
                folders: 0
            )
        )
        XCTAssertEqual(
            try projection.mainContext.fetchCount(FetchDescriptor<CloudPodcastProjection>()),
            counts.podcasts
        )
    }

    func testSyncDisabledStartCreatesNoSeedMarker() async throws {
        let app = try makeApplicationContainer()
        let projection = try makeProjectionContainer()
        let markers = Mutex<[CompactProjectionSeedMarker]>([])
        let coordinator = await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: app,
            projectionContainer: projection,
            center: NotificationCenter(),
            seedInstrumentationEnabled: { false },
            seedMarkerRecorder: { marker in markers.withLock { $0.append(marker) } }
        )

        try await coordinator.start()

        XCTAssertTrue(markers.withLock { $0.isEmpty })
    }

    func testStartObservesLocalChangesAndStopFullyDetaches() async throws {
        let app = try makeApplicationContainer()
        let projection = try makeProjectionContainer()
        let center = NotificationCenter()
        let coordinator = await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: app,
            projectionContainer: projection,
            center: center,
            deviceID: "phone"
        )
        try await coordinator.start()
        app.mainContext.insert(Podcast(
            feedURL: "https://example.com/first",
            title: "First"
        ))
        try app.mainContext.save()
        center.post(name: .earshotSubscriptionsDidChange, object: nil)
        try await waitForProjectionPodcastCount(1, in: projection)
        projection.mainContext.rollback()
        XCTAssertEqual(
            try projection.mainContext.fetchCount(FetchDescriptor<CloudPodcastProjection>()),
            1
        )

        await coordinator.stop()
        app.mainContext.insert(Podcast(
            feedURL: "https://example.com/second",
            title: "Second"
        ))
        try app.mainContext.save()
        center.post(name: .earshotSubscriptionsDidChange, object: nil)
        XCTAssertEqual(
            try projection.mainContext.fetchCount(FetchDescriptor<CloudPodcastProjection>()),
            1,
            "a stopped coordinator must not retain a persistence observer"
        )
    }

    func testTargetedSubscriptionNotificationUpdatesOnlyNamedPodcast() async throws {
        let app = try makeApplicationContainer()
        let projection = try makeProjectionContainer()
        let center = NotificationCenter()
        let coordinator = await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: app,
            projectionContainer: projection,
            center: center,
            deviceID: "phone"
        )
        try await coordinator.start(performInitialReconciliation: false)
        let first = Podcast(feedURL: "https://example.com/first", title: "First")
        let second = Podcast(feedURL: "https://example.com/second", title: "Second")
        app.mainContext.insert(first)
        app.mainContext.insert(second)
        try app.mainContext.save()
        // Seed synchronously so no earlier graph reconciliation is still in flight.
        try await coordinator.publishLocalSubscriptionGraphChange(feedURL: nil)

        first.speedOverride = 1.5
        second.speedOverride = 1.75
        try app.mainContext.save()
        try PodcastSettingsPersistence.save(first, in: app.mainContext, center: center)
        try await waitForProjectedSpeed(1.5, feedURL: first.feedURL, in: projection)
        projection.mainContext.rollback()

        let rows = try projection.mainContext.fetch(
            FetchDescriptor<CloudPodcastProjection>()
        )
        let values = Dictionary(uniqueKeysWithValues: rows.map { ($0.feedURL, $0.speedOverride) })
        XCTAssertEqual(values[first.feedURL]!, 1.5)
        XCTAssertNil(values[second.feedURL]!)
        await coordinator.stop()
    }

    func testBurstOfRemoteImportNotificationsCoalescesAndStopsCleanly() async throws {
        let app = try makeApplicationContainer()
        let projection = try makeProjectionContainer()
        let center = NotificationCenter()
        let coordinator = await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: app,
            projectionContainer: projection,
            center: center,
            deviceID: "phone"
        )
        try await coordinator.start()
        let remote = CloudPodcastProjection()
        remote.feedURL = "https://example.com/remote"
        remote.title = "Remote"
        projection.mainContext.insert(remote)
        try projection.mainContext.save()
        var applyCount = 0
        let token = center.addObserver(
            forName: .earshotCloudProjectionDidApply,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { applyCount += 1 }
        }
        defer { center.removeObserver(token) }

        for _ in 0..<100 {
            center.post(name: .earshotCloudKitImportDidFinish, object: nil)
        }
        for _ in 0..<100 {
            if try ModelContext(app).fetchCount(FetchDescriptor<Podcast>()) == 1,
               applyCount == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(
            try app.mainContext.fetchCount(FetchDescriptor<Podcast>()),
            1
        )
        XCTAssertEqual(applyCount, 1)

        await coordinator.stop()
        let afterStop = CloudPodcastProjection()
        afterStop.feedURL = "https://example.com/after-stop"
        afterStop.title = "After stop"
        projection.mainContext.insert(afterStop)
        try projection.mainContext.save()
        center.post(name: .earshotCloudKitImportDidFinish, object: nil)
        for _ in 0..<3 { await Task.yield() }
        XCTAssertEqual(
            try app.mainContext.fetchCount(FetchDescriptor<Podcast>()),
            1
        )
        XCTAssertEqual(applyCount, 1)
    }

    func testExistingSubscriptionsSeedOnlyCompactProjectionRows() async throws {
        let app = try makeApplicationContainer()
        for index in 0..<662 {
            app.mainContext.insert(Podcast(
                feedURL: "https://example.com/\(index).xml",
                title: "Podcast \(index)"
            ))
        }
        try app.mainContext.save()
        let projection = try makeProjectionContainer()
        let coordinator = await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: app,
            projectionContainer: projection
        )

        try await coordinator.reconcile()

        XCTAssertEqual(
            try projection.mainContext.fetchCount(
                FetchDescriptor<CloudPodcastProjection>()
            ),
            662
        )
        XCTAssertEqual(
            Set(projection.schema.entities.map(\.name)),
            [
                "CloudEpisodeStateProjection",
                "CloudPodcastProjection",
                "CloudQueueItemProjection",
                "CloudSettingProjection",
                "CloudBookmarkProjection",
                "CloudListeningSessionProjection",
                "CloudFolderProjection",
            ]
        )
    }

    func testCompletedSubscriptionBackfillIsRestartableOnDiskWithoutDuplicates() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let applicationURL = directory.appending(path: "application.store")
        let localURL = directory.appending(path: "local.store")
        let projectionURL = directory.appending(path: "projection.store")

        do {
            let app = try makeOnDiskApplicationContainer(
                applicationURL: applicationURL,
                localURL: localURL
            )
            for index in 0..<662 {
                app.mainContext.insert(Podcast(
                    feedURL: "https://example.com/\(index).xml",
                    title: "Podcast \(index)"
                ))
            }
            try app.mainContext.save()
            let projection = try makeOnDiskProjectionContainer(at: projectionURL)
            let coordinator = await CloudProjectionCoordinator.makeForTesting(
                applicationContainer: app,
                projectionContainer: projection,
                center: NotificationCenter(),
                deviceID: "phone"
            )
            try await coordinator.reconcile()
            XCTAssertEqual(
                try projection.mainContext.fetchCount(
                    FetchDescriptor<CloudPodcastProjection>()
                ),
                662
            )
        }

        do {
            let app = try makeOnDiskApplicationContainer(
                applicationURL: applicationURL,
                localURL: localURL
            )
            let projection = try makeOnDiskProjectionContainer(at: projectionURL)
            let restarted = await CloudProjectionCoordinator.makeForTesting(
                applicationContainer: app,
                projectionContainer: projection,
                center: NotificationCenter(),
                deviceID: "phone"
            )
            try await restarted.reconcile()
            XCTAssertEqual(
                try projection.mainContext.fetchCount(
                    FetchDescriptor<CloudPodcastProjection>()
                ),
                662
            )
            XCTAssertEqual(
                try app.mainContext.fetchCount(FetchDescriptor<Podcast>()),
                662
            )
        }
    }

    func testPartialSubscriptionBackfillResumesOnDiskWithoutDuplicates() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let applicationURL = directory.appending(path: "application.store")
        let localURL = directory.appending(path: "local.store")
        let projectionURL = directory.appending(path: "projection.store")

        try autoreleasepool {
            let app = try makeOnDiskApplicationContainer(
                applicationURL: applicationURL,
                localURL: localURL
            )
            for index in 0..<662 {
                app.mainContext.insert(Podcast(
                    feedURL: "https://example.com/\(index).xml",
                    title: "Podcast \(index)"
                ))
            }
            try app.mainContext.save()
            let projection = try makeOnDiskProjectionContainer(at: projectionURL)
            // A process death after two complete 50-row checkpoints plus a
            // partially committed server import can leave any natural-key
            // prefix. Reopen from 137 durable rows to exercise that state.
            for index in 0..<137 {
                let row = CloudPodcastProjection()
                row.feedURL = "https://example.com/\(index).xml"
                row.title = "Podcast \(index)"
                projection.mainContext.insert(row)
            }
            try projection.mainContext.save()
        }

        do {
            let app = try makeOnDiskApplicationContainer(
                applicationURL: applicationURL,
                localURL: localURL
            )
            let projection = try makeOnDiskProjectionContainer(at: projectionURL)
            try await CloudProjectionCoordinator.makeForTesting(
                applicationContainer: app,
                projectionContainer: projection,
                center: NotificationCenter(),
                deviceID: "phone"
            ).reconcile()

            let rows = try projection.mainContext.fetch(
                FetchDescriptor<CloudPodcastProjection>()
            )
            XCTAssertEqual(rows.count, 662)
            XCTAssertEqual(Set(rows.map { FeedURLIdentity.canonical($0.feedURL) }).count, 662)
            XCTAssertEqual(try app.mainContext.fetchCount(FetchDescriptor<Podcast>()), 662)
        }
    }

    func testImportedProjectionCreatesApplicationSubscription() async throws {
        let app = try makeApplicationContainer()
        let projection = try makeProjectionContainer()
        let remote = CloudPodcastProjection()
        remote.feedURL = "HTTPS://EXAMPLE.COM:443/feed.xml#fragment"
        remote.title = "Remote podcast"
        remote.autoQueue = true
        projection.mainContext.insert(remote)
        try projection.mainContext.save()
        let coordinator = await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: app,
            projectionContainer: projection
        )

        try await coordinator.reconcile()

        let podcasts = try app.mainContext.fetch(FetchDescriptor<Podcast>())
        XCTAssertEqual(podcasts.count, 1)
        XCTAssertEqual(podcasts[0].feedURL, "https://example.com/feed.xml")
        XCTAssertEqual(podcasts[0].title, "Remote podcast")
        XCTAssertTrue(podcasts[0].autoQueue)
    }

    func testLocalDeletionPersistsTombstoneAndSurvivesCoordinatorRestart() async throws {
        let source = try makeApplicationContainer()
        let podcast = Podcast(feedURL: "https://example.com/feed.xml", title: "Podcast")
        source.mainContext.insert(podcast)
        try source.mainContext.save()
        let projection = try makeProjectionContainer()
        let first = await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: source,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "phone"
        )
        try await first.reconcile()
        source.mainContext.delete(podcast)
        try source.mainContext.save()
        let deletedAt = Date(timeIntervalSince1970: 1_800_000_000)

        try await first.publishLocalSubscriptionChanges(now: deletedAt)

        let rows = try projection.mainContext.fetch(
            FetchDescriptor<CloudPodcastProjection>()
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].deletedAt, deletedAt)

        let secondDevice = try makeApplicationContainer()
        secondDevice.mainContext.insert(
            Podcast(feedURL: "https://example.com/feed.xml", title: "Stale copy")
        )
        try secondDevice.mainContext.save()
        let restarted = await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: secondDevice,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "mac"
        )
        try await restarted.reconcile()

        XCTAssertEqual(
            try secondDevice.mainContext.fetchCount(FetchDescriptor<Podcast>()),
            0
        )
        XCTAssertEqual(rows[0].deletedAt, deletedAt)
    }

    func testRemoteUnfollowReleasesActivePlayerBeforeCascadeDelete() async throws {
        let app = try makeApplicationContainerWithEpisode(position: 30)
        let episode = try XCTUnwrap(applicationEpisode(in: app))
        let player = PlayerService()
        player.configure(context: app.mainContext)
        player.play(episode)
        XCTAssertEqual(player.nowPlayingEpisodeID, episode.persistentModelID)

        let projection = try makeProjectionContainer()
        let tombstone = CloudPodcastProjection()
        tombstone.feedURL = "https://example.com/feed"
        tombstone.title = "Show"
        tombstone.deletedAt = Date.distantFuture
        tombstone.modifiedAt = Date.distantFuture
        tombstone.sourceDeviceID = "mac"
        projection.mainContext.insert(tombstone)
        try projection.mainContext.save()

        try await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: app,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "phone"
        ).reconcile()

        XCTAssertNil(player.nowPlayingEpisode)
        XCTAssertNil(player.nowPlayingEpisodeID)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(try app.mainContext.fetchCount(FetchDescriptor<Podcast>()), 0)
        XCTAssertEqual(try app.mainContext.fetchCount(FetchDescriptor<Episode>()), 0)
        player.pause()
        player.seek(to: 60)
        try app.mainContext.save()
        XCTAssertEqual(try app.mainContext.fetchCount(FetchDescriptor<Episode>()), 0)
    }

    func testRemoteUnfollowNotifiesBeforeDelayedCascadeDelete() async throws {
        let app = try makeApplicationContainerWithEpisode(position: 30)
        let podcast = try XCTUnwrap(
            app.mainContext.fetch(FetchDescriptor<Podcast>()).first
        )
        let podcastID = podcast.persistentModelID
        let projection = try makeProjectionContainer()
        let tombstone = CloudPodcastProjection()
        tombstone.feedURL = "https://example.com/feed"
        tombstone.title = "Show"
        tombstone.deletedAt = Date.distantFuture
        tombstone.modifiedAt = Date.distantFuture
        tombstone.sourceDeviceID = "mac"
        projection.mainContext.insert(tombstone)
        try projection.mainContext.save()

        let center = NotificationCenter()
        var notifiedPodcastID: PersistentIdentifier?
        let token = center.addObserver(
            forName: .earshotWillDeleteEpisodes,
            object: nil,
            queue: .main
        ) { note in
            let podcastID = note.userInfo?[PlayerService.willDeletePodcastIDKey]
                as? PersistentIdentifier
            MainActor.assumeIsolated {
                notifiedPodcastID = podcastID
            }
        }
        defer { center.removeObserver(token) }
        let coordinator = await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: app,
            projectionContainer: projection,
            center: center,
            deviceID: "phone",
            // Leave enough separation for reconcile() and its assertions even
            // on a loaded simulator; one millisecond raced the test process.
            remotePodcastDeletionDelayNanoseconds: 100_000_000
        )

        try await coordinator.reconcile()

        XCTAssertEqual(notifiedPodcastID, podcastID)
        XCTAssertEqual(try app.mainContext.fetchCount(FetchDescriptor<Podcast>()), 1)
        XCTAssertEqual(try app.mainContext.fetchCount(FetchDescriptor<Episode>()), 1)

        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(try app.mainContext.fetchCount(FetchDescriptor<Podcast>()), 0)
        XCTAssertEqual(try app.mainContext.fetchCount(FetchDescriptor<Episode>()), 0)
    }

    func testReconcileRemovesOrphansLeftByRemoteUnfollowRefreshRace() async throws {
        let app = try makeApplicationContainer()
        let orphan = Episode(
            guid: "orphan",
            title: "Detached episode",
            audioURL: "https://example.com/orphan.mp3"
        )
        let session = ListeningSession(durationSeconds: 30)
        session.episode = orphan
        app.mainContext.insert(orphan)
        app.mainContext.insert(session)
        try app.mainContext.save()

        let coordinator = await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: app,
            projectionContainer: try makeProjectionContainer(),
            center: NotificationCenter(),
            deviceID: "phone"
        )

        try await coordinator.reconcile()

        XCTAssertEqual(try app.mainContext.fetchCount(FetchDescriptor<Episode>()), 0)
        XCTAssertEqual(
            try app.mainContext.fetchCount(FetchDescriptor<ListeningSession>()),
            0
        )
    }

    func testReconcileUnloadsPlayerBeforeRemovingLoadedOrphan() async throws {
        let app = try makeApplicationContainer()
        let orphan = Episode(
            guid: "playing-orphan",
            title: "Playing orphan",
            audioURL: "https://example.com/orphan.mp3"
        )
        app.mainContext.insert(orphan)
        try app.mainContext.save()

        let player = PlayerService()
        player.configure(context: app.mainContext)
        player.load(orphan)
        XCTAssertEqual(player.nowPlayingEpisodeID, orphan.persistentModelID)

        let coordinator = await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: app,
            projectionContainer: try makeProjectionContainer(),
            center: .default,
            deviceID: "phone"
        )

        try await coordinator.reconcile()

        XCTAssertNil(player.nowPlayingEpisode)
        XCTAssertNil(player.nowPlayingEpisodeID)
        XCTAssertEqual(try app.mainContext.fetchCount(FetchDescriptor<Episode>()), 0)
    }

    func testRemoteUnfollowDelayDoesNotDeleteRapidRefollow() async throws {
        let app = try makeApplicationContainerWithEpisode(position: 30)
        let projection = try makeProjectionContainer()
        let tombstone = CloudPodcastProjection()
        tombstone.feedURL = "https://example.com/feed"
        tombstone.title = "Show"
        tombstone.deletedAt = Date.distantFuture
        tombstone.modifiedAt = Date.distantFuture
        tombstone.sourceDeviceID = "mac"
        projection.mainContext.insert(tombstone)
        try projection.mainContext.save()
        let coordinator = await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: app,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "phone",
            remotePodcastDeletionDelayNanoseconds: 20_000_000
        )

        try await coordinator.reconcile()
        tombstone.deletedAt = nil
        tombstone.modifiedAt = .now
        try projection.mainContext.save()

        try await Task.sleep(nanoseconds: 40_000_000)

        XCTAssertEqual(try app.mainContext.fetchCount(FetchDescriptor<Podcast>()), 1)
        XCTAssertEqual(try app.mainContext.fetchCount(FetchDescriptor<Episode>()), 1)
    }

    func testPromotionActivationRestartsAndPublishesEntireGraphWithoutReorderingQueue() async throws {
        enum Injected: Error { case afterQueue, markerSave }
        let app = try makeApplicationContainer()
        let context = app.mainContext
        let feedURL = "https://example.com/promoted-graph"
        let podcast = Podcast(
            feedURL: feedURL, title: "Promoted graph",
            subscriptionStateRaw: PodcastSubscriptionState.catalogOnly.rawValue
        )
        let first = Episode(
            guid: "first", title: "First", audioURL: "https://example.com/first.mp3",
            status: .inQueue, positionSeconds: 42, inboxDismissed: true
        )
        let second = Episode(
            guid: "second", title: "Second", audioURL: "https://example.com/second.mp3",
            status: .inQueue
        )
        first.podcast = podcast
        second.podcast = podcast
        let catalog = Podcast(
            feedURL: "https://catalog.example/feed", title: "Catalog anchors",
            subscriptionStateRaw: PodcastSubscriptionState.catalogOnly.rawValue
        )
        let before = Episode(
            guid: "before", title: "Before", audioURL: "https://example.com/before.mp3",
            status: .inQueue
        )
        let middle = Episode(
            guid: "middle", title: "Middle", audioURL: "https://example.com/middle.mp3",
            status: .inQueue
        )
        before.podcast = catalog
        middle.podcast = catalog
        context.insert(podcast)
        context.insert(first)
        context.insert(second)
        context.insert(catalog)
        context.insert(before)
        context.insert(middle)
        context.insert(QueueItem(episode: before, position: 0))
        context.insert(QueueItem(episode: first, position: 1))
        context.insert(QueueItem(episode: middle, position: 2))
        context.insert(QueueItem(episode: second, position: 3))
        context.insert(Bookmark(episode: first, positionSeconds: 12, note: "Keep"))
        context.insert(ListeningSession(
            episode: first, podcast: podcast, durationSeconds: 30
        ))
        let folder = PodcastFolder(name: "Promoted folder")
        context.insert(folder)
        context.insert(FolderMembership(folder: folder, podcast: podcast))
        context.insert(EpisodeFolderMembership(folder: folder, episode: first))
        try AppSettingIdentity.setValue(
            "all", for: SettingsKey.podcastFilter(feedURL: feedURL), in: context
        )
        try context.save()
        XCTAssertEqual(QueueLineupStore(context: context).save([second, first]).savedCount, 2)
        podcast.subscriptionStateRaw = nil
        try PendingCloudFollowIntent.set(feedURL: feedURL, in: context)
        context.insert(AppSetting(
            key: SettingsKey.pendingCloudFollowPrefix + UUID().uuidString, value: feedURL
        ))
        try context.save()
        let originalQueue = try context.fetch(FetchDescriptor<QueueItem>(
            sortBy: [SortDescriptor(\.position)]
        )).compactMap { $0.episode?.guid }
        let projection = try makeProjectionContainer()
        let tombstone = CloudPodcastProjection()
        tombstone.feedURL = feedURL
        tombstone.deletedAt = .distantFuture
        tombstone.sourceDeviceID = "remote"
        let unrelatedQueue = CloudQueueItemProjection()
        unrelatedQueue.feedURL = "https://unrelated.example/feed"
        unrelatedQueue.episodeGUID = "unrelated"
        unrelatedQueue.isQueued = true
        unrelatedQueue.position = 99
        unrelatedQueue.sourceDeviceID = "remote"
        let unrelatedSetting = CloudSettingProjection()
        unrelatedSetting.key = SettingsKey.globalSpeed
        unrelatedSetting.value = "1.75"
        unrelatedSetting.sourceDeviceID = "remote"
        let unrelatedState = CloudEpisodeStateProjection()
        unrelatedState.feedURL = "https://unrelated.example/feed"
        unrelatedState.episodeGUID = "state"
        unrelatedState.positionSeconds = 77
        unrelatedState.sourceDeviceID = "phone"
        let remoteOnlyQueue = CloudQueueItemProjection()
        remoteOnlyQueue.feedURL = feedURL
        remoteOnlyQueue.episodeGUID = "remote-only"
        remoteOnlyQueue.isQueued = true
        remoteOnlyQueue.position = 20
        remoteOnlyQueue.sourceDeviceID = "remote"
        projection.mainContext.insert(unrelatedQueue)
        projection.mainContext.insert(unrelatedSetting)
        projection.mainContext.insert(unrelatedState)
        projection.mainContext.insert(remoteOnlyQueue)
        projection.mainContext.insert(tombstone)
        try projection.mainContext.save()
        let interrupted = await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: app,
            projectionContainer: projection,
            deviceID: "phone",
            followActivationCheckpoint: { if $0 == "queue" { throw Injected.afterQueue } }
        )
        do { try await interrupted.publishLocalSubscriptionChange(feedURL: feedURL) }
        catch Injected.afterQueue { }
        XCTAssertTrue(try PendingCloudFollowIntent.exists(feedURL: feedURL, in: ModelContext(app)))
        let clearFailing = await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: app, projectionContainer: projection, deviceID: "phone",
            pendingIntentSave: { _ in throw Injected.markerSave }
        )
        do { try await clearFailing.publishLocalSubscriptionChange(feedURL: feedURL) }
        catch Injected.markerSave { }
        XCTAssertTrue(try PendingCloudFollowIntent.exists(feedURL: feedURL, in: ModelContext(app)))
        let coordinator = await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: app, projectionContainer: projection, deviceID: "phone"
        )
        try await coordinator.publishLocalSubscriptionChange(feedURL: feedURL)
        let projected = ModelContext(projection)
        XCTAssertEqual(try projected.fetchCount(FetchDescriptor<CloudPodcastProjection>()), 1)
        XCTAssertEqual(try projected.fetchCount(FetchDescriptor<CloudEpisodeStateProjection>()), 2)
        XCTAssertEqual(try projected.fetchCount(FetchDescriptor<CloudQueueItemProjection>()), 4)
        XCTAssertGreaterThanOrEqual(
            try projected.fetchCount(FetchDescriptor<CloudSettingProjection>()), 2
        )
        XCTAssertEqual(try projected.fetchCount(FetchDescriptor<CloudBookmarkProjection>()), 1)
        XCTAssertEqual(
            try projected.fetchCount(FetchDescriptor<CloudListeningSessionProjection>()), 1
        )
        let projectedFolder = try XCTUnwrap(
            projected.fetch(FetchDescriptor<CloudFolderProjection>()).first
        )
        XCTAssertTrue(try folderFeeds(projectedFolder.podcastMembersJSON).contains(feedURL))
        XCTAssertTrue(try folderFeeds(projectedFolder.episodeMembersJSON).contains(feedURL))
        try await coordinator.reconcile()
        XCTAssertEqual(
            try ModelContext(app).fetch(FetchDescriptor<QueueItem>(
                sortBy: [SortDescriptor(\.position)]
            )).compactMap { $0.episode?.guid },
            originalQueue
        )
        let remoteOnlyRows = try projected.fetch(FetchDescriptor<CloudQueueItemProjection>())
            .filter { $0.feedURL == feedURL && $0.episodeGUID == "remote-only" }
        XCTAssertEqual(remoteOnlyRows.count, 1)
        XCTAssertTrue(remoteOnlyRows[0].isQueued)
        XCTAssertEqual(remoteOnlyRows[0].sourceDeviceID, "remote")

        let targetRows = try projected.fetch(FetchDescriptor<CloudQueueItemProjection>())
            .filter { $0.feedURL == feedURL && ["first", "second"].contains($0.episodeGUID) }
        for row in targetRows {
            row.position = row.episodeGUID == "second" ? 1 : 3
            row.modifiedAt = .distantFuture
            row.sourceDeviceID = "remote"
        }
        try projected.save()
        try await coordinator.reconcile()
        XCTAssertEqual(
            try ModelContext(app).fetch(FetchDescriptor<QueueItem>(sortBy: [SortDescriptor(\.position)]))
                .compactMap { $0.episode?.guid },
            ["before", "second", "middle", "first"]
        )
        XCTAssertFalse(try PendingCloudFollowIntent.exists(feedURL: feedURL, in: context))
        XCTAssertEqual(unrelatedQueue.position, 99)
        XCTAssertEqual(unrelatedSetting.value, "1.75")
        XCTAssertEqual(unrelatedState.positionSeconds, 77)
    }

    func testMidActivationUnfollowNeutralizesTargetGraphAndPreservesUnrelatedRows() async throws {
        let app = try makeApplicationContainer()
        let feedURL = "https://example.com/mid-unfollow"
        let podcast = Podcast(feedURL: feedURL, title: "Mid Unfollow")
        let episode = Episode(
            guid: "episode", title: "Episode", audioURL: "https://example.com/audio",
            status: .inQueue, positionSeconds: 20
        )
        episode.podcast = podcast
        app.mainContext.insert(podcast)
        app.mainContext.insert(episode)
        app.mainContext.insert(QueueItem(episode: episode, position: 0))
        app.mainContext.insert(Bookmark(episode: episode, positionSeconds: 4))
        app.mainContext.insert(ListeningSession(
            episode: episode, podcast: podcast, durationSeconds: 10
        ))
        let folder = PodcastFolder(name: "Target folder")
        app.mainContext.insert(folder)
        app.mainContext.insert(FolderMembership(folder: folder, podcast: podcast))
        try AppSettingIdentity.setValue(
            "all", for: SettingsKey.podcastFilter(feedURL: feedURL), in: app.mainContext
        )
        try PendingCloudFollowIntent.set(feedURL: feedURL, in: app.mainContext)
        try app.mainContext.save()
        let projection = try makeProjectionContainer()
        let unrelated = CloudQueueItemProjection()
        unrelated.feedURL = "https://unrelated.example/feed"
        unrelated.episodeGUID = "keep"
        unrelated.isQueued = true
        unrelated.sourceDeviceID = "phone"
        let unrelatedState = CloudEpisodeStateProjection()
        unrelatedState.feedURL = unrelated.feedURL
        unrelatedState.episodeGUID = "state"
        unrelatedState.positionSeconds = 55
        unrelatedState.sourceDeviceID = "phone"
        projection.mainContext.insert(unrelated)
        projection.mainContext.insert(unrelatedState)
        try projection.mainContext.save()
        let didUnfollow = Mutex(false)
        let coordinator = await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: app,
            projectionContainer: projection,
            deviceID: "phone",
            followActivationCheckpoint: { stage in
                guard stage == "verified", !didUnfollow.withLock({ value in
                    defer { value = true }
                    return value
                }) else { return }
                let context = ModelContext(app)
                if let target = try PodcastIdentityService(context: context)
                    .existingFollowed(feedURL: feedURL) {
                    _ = SubscriptionDeletionRepository(context: context).unsubscribe(target)
                }
            }
        )
        do { try await coordinator.publishLocalSubscriptionChange(feedURL: feedURL) }
        catch is CancellationError { }
        try await coordinator.reconcile()
        let check = ModelContext(projection)
        XCTAssertEqual(try ModelContext(app).fetchCount(FetchDescriptor<Podcast>()), 0)
        XCTAssertFalse(try check.fetch(FetchDescriptor<CloudPodcastProjection>()).contains {
            $0.feedURL == feedURL && $0.deletedAt == nil
        })
        XCTAssertFalse(try check.fetch(FetchDescriptor<CloudEpisodeStateProjection>()).contains {
            $0.feedURL == feedURL && $0.deletedAt == nil
        })
        XCTAssertFalse(try check.fetch(FetchDescriptor<CloudQueueItemProjection>()).contains {
            $0.feedURL == feedURL && $0.isQueued && $0.deletedAt == nil
        })
        XCTAssertFalse(try check.fetch(FetchDescriptor<CloudSettingProjection>()).contains {
            $0.key.contains(feedURL) && $0.deletedAt == nil
        })
        XCTAssertFalse(try check.fetch(FetchDescriptor<CloudBookmarkProjection>()).contains {
            $0.feedURL == feedURL && $0.deletedAt == nil
        })
        XCTAssertFalse(try check.fetch(FetchDescriptor<CloudListeningSessionProjection>()).contains {
            $0.feedURL == feedURL && $0.deletedAt == nil
        })
        for row in try check.fetch(FetchDescriptor<CloudFolderProjection>()) {
            XCTAssertFalse(try folderFeeds(row.podcastMembersJSON).contains(feedURL))
            XCTAssertFalse(try folderFeeds(row.episodeMembersJSON).contains(feedURL))
        }
        XCTAssertTrue(try check.fetch(FetchDescriptor<CloudQueueItemProjection>()).contains {
            $0.feedURL == unrelated.feedURL && $0.isQueued
        })
        XCTAssertTrue(try check.fetch(FetchDescriptor<CloudEpisodeStateProjection>()).contains {
            $0.feedURL == unrelated.feedURL && $0.positionSeconds == 55 && $0.deletedAt == nil
        })
    }

    func testPendingUnfollowSurvivesRestartAndPreventsRemoteRecreation() async throws {
        enum Injected: Error { case markerSave }
        let app = try makeApplicationContainerWithEpisode(position: 30)
        let feedURL = "https://example.com/feed"
        let projection = try makeProjectionContainer()
        let active = CloudPodcastProjection()
        active.feedURL = feedURL
        active.title = "Remote"
        active.sourceDeviceID = "remote"
        projection.mainContext.insert(active)
        try projection.mainContext.save()
        let podcast = try XCTUnwrap(
            PodcastIdentityService(context: app.mainContext).existingFollowed(feedURL: feedURL)
        )
        XCTAssertTrue(SubscriptionDeletionRepository(context: app.mainContext).unsubscribe(podcast))
        XCTAssertTrue(try PendingCloudUnfollowIntent.feedURLs(in: ModelContext(app)).contains(feedURL))

        let failing = await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: app, projectionContainer: projection, deviceID: "phone",
            pendingIntentSave: { _ in throw Injected.markerSave }
        )
        do { try await failing.reconcile(); XCTFail("Expected marker-save failure") }
        catch Injected.markerSave { }
        XCTAssertTrue(try PendingCloudUnfollowIntent.feedURLs(in: ModelContext(app)).contains(feedURL))
        let restarted = await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: app, projectionContainer: projection, deviceID: "phone"
        )
        try await restarted.reconcile()

        XCTAssertNil(try PodcastIdentityService(context: ModelContext(app))
            .existingFollowed(feedURL: feedURL))
        XCTAssertFalse(try projection.mainContext.fetch(FetchDescriptor<CloudPodcastProjection>())
            .contains { $0.feedURL == feedURL && $0.deletedAt == nil })
        XCTAssertFalse(try PendingCloudUnfollowIntent.feedURLs(in: ModelContext(app)).contains(feedURL))
    }
    func testCatalogShellWithoutFollowIntentIgnoresRemoteTombstone() async throws {
        let app = try makeApplicationContainer()
        let feedURL = "https://example.com/catalog-feed"
        app.mainContext.insert(Podcast(
            feedURL: feedURL, title: "Catalog",
            subscriptionStateRaw: PodcastSubscriptionState.catalogOnly.rawValue
        ))
        try app.mainContext.save()
        let projection = try makeProjectionContainer()
        let tombstone = CloudPodcastProjection()
        tombstone.feedURL = feedURL
        tombstone.title = "Old Follow"
        tombstone.deletedAt = Date.distantFuture
        projection.mainContext.insert(tombstone)
        try projection.mainContext.save()

        try await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: app,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "phone"
        ).reconcile()

        let shell = try XCTUnwrap(
            PodcastIdentityService(context: ModelContext(app))
                .existingAnyState(feedURL: feedURL)
        )
        XCTAssertFalse(shell.isFollowed)
        XCTAssertEqual(try ModelContext(app).fetchCount(FetchDescriptor<Podcast>()), 1)
    }

    func testActiveRemoteSubscriptionPromotesCatalogAndRestartsGraphActivation() async throws {
        enum Injected: Error { case afterQueue }
        let app = try makeApplicationContainer()
        let feedURL = "https://example.com/remote-promoted"
        let catalog = Podcast(
            feedURL: feedURL, title: "Catalog title",
            subscriptionStateRaw: PodcastSubscriptionState.catalogOnly.rawValue,
            speedOverride: 1.6
        )
        let episode = Episode(
            guid: "kept", title: "Catalog episode", audioURL: "https://example.com/kept.mp3",
            status: .inQueue, positionSeconds: 90, inboxDismissed: true
        )
        episode.podcast = catalog
        app.mainContext.insert(catalog)
        app.mainContext.insert(episode)
        app.mainContext.insert(QueueItem(episode: episode, position: 0))
        app.mainContext.insert(Bookmark(episode: episode, positionSeconds: 12, note: "Keep"))
        app.mainContext.insert(ListeningSession(
            episode: episode, podcast: catalog, durationSeconds: 30
        ))
        try AppSettingIdentity.setValue(
            "all", for: SettingsKey.podcastFilter(feedURL: feedURL), in: app.mainContext
        )
        try app.mainContext.save()
        let podcastID = catalog.persistentModelID
        let episodeID = episode.persistentModelID
        let projection = try makeProjectionContainer()
        let remote = CloudPodcastProjection()
        remote.feedURL = feedURL
        remote.title = "Remote title"
        remote.speedOverride = 1.2
        remote.sourceDeviceID = "older-device"
        remote.modifiedAt = Date(timeIntervalSince1970: 500)
        let unrelated = CloudSettingProjection()
        unrelated.key = SettingsKey.globalSpeed
        unrelated.value = "1.75"
        unrelated.sourceDeviceID = "older-device"
        projection.mainContext.insert(remote)
        projection.mainContext.insert(unrelated)
        try projection.mainContext.save()

        let interrupted = await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: app, projectionContainer: projection, deviceID: "new-device",
            followActivationCheckpoint: { if $0 == "queue" { throw Injected.afterQueue } }
        )
        do {
            try await interrupted.reconcile()
            XCTFail("Expected activation interruption")
        } catch Injected.afterQueue { }

        var stored = try XCTUnwrap(
            PodcastIdentityService(context: ModelContext(app)).existingFollowed(feedURL: feedURL)
        )
        XCTAssertEqual(stored.persistentModelID, podcastID)
        XCTAssertEqual(stored.title, "Remote title")
        XCTAssertTrue(try PendingCloudRemoteActivationIntent.exists(
            feedURL: feedURL, in: ModelContext(app)
        ))

        let restarted = await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: app, projectionContainer: projection, deviceID: "new-device"
        )
        try await restarted.reconcile()

        let application = ModelContext(app)
        stored = try XCTUnwrap(
            PodcastIdentityService(context: application).existingFollowed(feedURL: feedURL)
        )
        XCTAssertEqual(stored.persistentModelID, podcastID)
        let retained = try XCTUnwrap(application.fetch(FetchDescriptor<Episode>()).first)
        XCTAssertEqual(retained.persistentModelID, episodeID)
        XCTAssertEqual(retained.positionSeconds, 90)
        XCTAssertTrue(retained.inboxDismissed)
        XCTAssertEqual(retained.queueItem?.position, 0)
        XCTAssertEqual(retained.bookmarks?.first?.note, "Keep")
        XCTAssertFalse(try PendingCloudRemoteActivationIntent.exists(
            feedURL: feedURL, in: application
        ))

        let projected = ModelContext(projection)
        let subscription = try XCTUnwrap(
            projected.fetch(FetchDescriptor<CloudPodcastProjection>()).first {
                FeedURLIdentity.matches($0.feedURL, feedURL)
            }
        )
        XCTAssertNil(subscription.deletedAt)
        XCTAssertEqual(subscription.sourceDeviceID, "older-device")
        XCTAssertTrue(try projected.fetch(FetchDescriptor<CloudEpisodeStateProjection>()).contains {
            FeedURLIdentity.matches($0.feedURL, feedURL) && $0.episodeGUID == "kept"
        })
        XCTAssertTrue(try projected.fetch(FetchDescriptor<CloudQueueItemProjection>()).contains {
            FeedURLIdentity.matches($0.feedURL, feedURL) && $0.episodeGUID == "kept" && $0.isQueued
        })
        XCTAssertTrue(try projected.fetch(FetchDescriptor<CloudBookmarkProjection>()).contains {
            FeedURLIdentity.matches($0.feedURL, feedURL) && $0.episodeGUID == "kept"
        })
        XCTAssertTrue(try projected.fetch(FetchDescriptor<CloudListeningSessionProjection>()).contains {
            FeedURLIdentity.matches($0.feedURL, feedURL)
        })
        XCTAssertEqual(unrelated.value, "1.75")
    }

    func testRemoteCatalogPromotionSaveFailureRollsBackStateAndMarker() async throws {
        enum Injected: Error { case save }
        let app = try makeApplicationContainer()
        let feedURL = "https://example.com/remote-save-failure"
        let catalog = Podcast(
            feedURL: feedURL, title: "Catalog",
            subscriptionStateRaw: PodcastSubscriptionState.catalogOnly.rawValue
        )
        let episode = Episode(
            guid: "kept", title: "Keep", audioURL: "https://example.com/kept.mp3",
            positionSeconds: 44
        )
        episode.podcast = catalog
        app.mainContext.insert(catalog)
        app.mainContext.insert(episode)
        try app.mainContext.save()
        let projection = try makeProjectionContainer()
        let remote = CloudPodcastProjection()
        remote.feedURL = feedURL
        remote.title = "Remote"
        remote.sourceDeviceID = "remote"
        projection.mainContext.insert(remote)
        try projection.mainContext.save()
        let failing = await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: app, projectionContainer: projection,
            remoteSubscriptionSave: { _ in throw Injected.save }
        )

        do {
            try await failing.reconcile()
            XCTFail("Expected promotion save failure")
        } catch Injected.save { }

        var fresh = ModelContext(app)
        var stored = try XCTUnwrap(
            PodcastIdentityService(context: fresh).existingAnyState(feedURL: feedURL)
        )
        XCTAssertFalse(stored.isFollowed)
        XCTAssertEqual(stored.title, "Catalog")
        XCTAssertEqual(stored.episodes?.first?.positionSeconds, 44)
        XCTAssertFalse(try PendingCloudRemoteActivationIntent.exists(feedURL: feedURL, in: fresh))
        XCTAssertEqual(try ModelContext(projection).fetchCount(
            FetchDescriptor<CloudEpisodeStateProjection>()
        ), 0)

        try await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: app, projectionContainer: projection
        ).reconcile()
        fresh = ModelContext(app)
        stored = try XCTUnwrap(
            PodcastIdentityService(context: fresh).existingFollowed(feedURL: feedURL)
        )
        XCTAssertEqual(stored.title, "Remote")
        XCTAssertEqual(stored.episodes?.first?.positionSeconds, 44)
        XCTAssertFalse(try PendingCloudRemoteActivationIntent.exists(feedURL: feedURL, in: fresh))
    }

    func testConcurrentCatalogAddAndRemoteFollowConvergeOnOneGraph() async throws {
        let app = try makeApplicationContainer()
        let projection = try makeProjectionContainer()
        let feedURL = "https://example.com/concurrent-remote"
        let remote = CloudPodcastProjection()
        remote.feedURL = feedURL
        remote.title = "Remote show"
        remote.sourceDeviceID = "remote"
        projection.mainContext.insert(remote)
        try projection.mainContext.save()
        let repository = CatalogEpisodeQueueRepository(container: app)
        let preview = PreviewEpisode(
            podcastFeedURL: feedURL, podcastTitle: "Catalog show",
            podcastArtworkURL: nil, id: "episode", title: "Episode",
            pubDate: Date(timeIntervalSince1970: 100), durationSeconds: 60,
            audioURL: "https://example.com/episode.mp3",
            episodeDescription: nil, searchableDescription: "", artworkURL: nil,
            episodeNumber: nil, seasonNumber: nil, chapterURL: nil, transcriptURL: nil
        )
        let coordinator = await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: app, projectionContainer: projection
        )

        let addTask = Task { @MainActor in await repository.add(preview) }
        let reconcileTask = Task { try await coordinator.reconcile() }
        let addResult: Result<CatalogEpisodeQueueOutcome, CatalogEpisodeQueueFailure> =
            await addTask.value
        XCTAssertEqual(addResult, .success(.added))
        try await reconcileTask.value

        let fresh = ModelContext(app)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<Podcast>()), 1)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<Episode>()), 1)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<QueueItem>()), 1)
        XCTAssertNotNil(
            try PodcastIdentityService(context: fresh).existingFollowed(feedURL: feedURL)
        )
        XCTAssertFalse(try PendingCloudRemoteActivationIntent.exists(feedURL: feedURL, in: fresh))
    }

    func testFollowIntentReadFailureAbortsRemoteDeletionFailClosed() async throws {
        enum IntentReadFailure: Error { case injected }
        let app = try makeApplicationContainerWithEpisode(position: 30)
        let projection = try makeProjectionContainer()
        let tombstone = CloudPodcastProjection()
        tombstone.feedURL = "https://example.com/feed"
        tombstone.title = "Old remote state"
        tombstone.deletedAt = Date.distantFuture
        projection.mainContext.insert(tombstone)
        try projection.mainContext.save()
        let coordinator = await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: app,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "phone",
            pendingFollowFeedURLs: { _ in throw IntentReadFailure.injected }
        )

        do {
            try await coordinator.reconcile()
            XCTFail("A critical intent read failure must abort remote application")
        } catch IntentReadFailure.injected { }

        let check = ModelContext(app)
        XCTAssertEqual(try check.fetchCount(FetchDescriptor<Podcast>()), 1)
        XCTAssertEqual(try check.fetchCount(FetchDescriptor<Episode>()), 1)
        XCTAssertNotNil(tombstone.deletedAt)
    }

    func testRepeatedReconciliationSchedulesOneDelayedRemoteDelete() async throws {
        let app = try makeApplicationContainerWithEpisode(position: 30)
        let projection = try makeProjectionContainer()
        let tombstone = CloudPodcastProjection()
        tombstone.feedURL = "https://example.com/feed"
        tombstone.title = "Show"
        tombstone.deletedAt = Date.distantFuture
        tombstone.modifiedAt = Date.distantFuture
        tombstone.sourceDeviceID = "mac"
        projection.mainContext.insert(tombstone)
        try projection.mainContext.save()
        let center = NotificationCenter()
        var notificationCount = 0
        let token = center.addObserver(
            forName: .earshotWillDeleteEpisodes,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { notificationCount += 1 }
        }
        defer { center.removeObserver(token) }
        let coordinator = await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: app,
            projectionContainer: projection,
            center: center,
            deviceID: "phone",
            remotePodcastDeletionDelayNanoseconds: 20_000_000
        )

        try await coordinator.reconcile()
        try await coordinator.reconcile()

        XCTAssertEqual(notificationCount, 1)
        XCTAssertEqual(try app.mainContext.fetchCount(FetchDescriptor<Podcast>()), 1)

        try await Task.sleep(nanoseconds: 40_000_000)

        XCTAssertEqual(notificationCount, 1)
        XCTAssertEqual(try app.mainContext.fetchCount(FetchDescriptor<Podcast>()), 0)
    }

    func testDuplicateCloudRowsConvergeToNewestRecord() async throws {
        let app = try makeApplicationContainer()
        let projection = try makeProjectionContainer()
        let older = CloudPodcastProjection()
        older.feedURL = "https://example.com/feed.xml"
        older.title = "Older"
        older.modifiedAt = Date(timeIntervalSince1970: 100)
        let newer = CloudPodcastProjection()
        newer.feedURL = "HTTPS://EXAMPLE.COM:443/feed.xml#ignored"
        newer.title = "Newer"
        newer.modifiedAt = Date(timeIntervalSince1970: 200)
        projection.mainContext.insert(older)
        projection.mainContext.insert(newer)
        try projection.mainContext.save()
        let coordinator = await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: app,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "mac"
        )

        try await coordinator.reconcile()

        XCTAssertEqual(
            try projection.mainContext.fetchCount(
                FetchDescriptor<CloudPodcastProjection>()
            ),
            1
        )
        XCTAssertEqual(
            try app.mainContext.fetch(FetchDescriptor<Podcast>()).first?.title,
            "Newer"
        )
    }

    func testReconciliationNeverRewindsFeedHighWaterMark() async throws {
        let app = try makeApplicationContainer()
        let localMark = Date(timeIntervalSince1970: 300)
        let local = Podcast(
            feedURL: "https://example.com/feed.xml",
            title: "Show",
            lastSeenPubDate: localMark
        )
        app.mainContext.insert(local)
        try app.mainContext.save()

        let projection = try makeProjectionContainer()
        let cloudMark = Date(timeIntervalSince1970: 100)
        let cloud = CloudPodcastProjection()
        cloud.feedURL = local.feedURL
        cloud.title = local.title
        cloud.lastSeenPubDate = cloudMark
        projection.mainContext.insert(cloud)
        try projection.mainContext.save()

        let coordinator = await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: app,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "phone"
        )

        try await coordinator.reconcile()
        let refreshedLocal = try XCTUnwrap(
            ModelContext(app).fetch(FetchDescriptor<Podcast>()).first
        )
        let refreshedCloud = try XCTUnwrap(
            ModelContext(projection).fetch(FetchDescriptor<CloudPodcastProjection>()).first
        )

        XCTAssertEqual(refreshedLocal.lastSeenPubDate, localMark)
        XCTAssertEqual(refreshedCloud.lastSeenPubDate, localMark)
    }

    func testReconciliationAdvancesLocalFeedHighWaterMarkFromCloud() async throws {
        let app = try makeApplicationContainer()
        let localMark = Date(timeIntervalSince1970: 100)
        let local = Podcast(
            feedURL: "https://example.com/feed.xml",
            title: "Show",
            lastSeenPubDate: localMark
        )
        app.mainContext.insert(local)
        try app.mainContext.save()

        let projection = try makeProjectionContainer()
        let cloudMark = Date(timeIntervalSince1970: 300)
        let cloud = CloudPodcastProjection()
        cloud.feedURL = local.feedURL
        cloud.title = local.title
        cloud.lastSeenPubDate = cloudMark
        projection.mainContext.insert(cloud)
        try projection.mainContext.save()

        let coordinator = await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: app,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "phone"
        )

        try await coordinator.reconcile()
        let refreshedLocal = try XCTUnwrap(
            ModelContext(app).fetch(FetchDescriptor<Podcast>()).first
        )

        XCTAssertEqual(refreshedLocal.lastSeenPubDate, cloudMark)
        XCTAssertEqual(cloud.lastSeenPubDate, cloudMark)
    }

    func testPublishingLegacyDuplicateLocalFeedURLsDoesNotTrap() async throws {
        let app = try makeApplicationContainer()
        app.mainContext.insert(Podcast(
            feedURL: "https://example.com/feed.xml",
            title: "First",
            createdAt: Date(timeIntervalSince1970: 100)
        ))
        app.mainContext.insert(Podcast(
            feedURL: "HTTPS://EXAMPLE.COM:443/feed.xml#duplicate",
            title: "Second",
            createdAt: Date(timeIntervalSince1970: 200)
        ))
        try app.mainContext.save()
        let projection = try makeProjectionContainer()
        let coordinator = await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: app,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "phone"
        )

        try await coordinator.publishLocalSubscriptionChanges()

        let rows = try projection.mainContext.fetch(
            FetchDescriptor<CloudPodcastProjection>()
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].title, "First")
    }

    func testEverywhereDeleteIntentPrecedesApplicationStoreDeletion() async throws {
        let app = try makeApplicationContainer()
        app.mainContext.insert(Podcast(
            feedURL: "https://example.com/feed.xml",
            title: "Podcast"
        ))
        try app.mainContext.save()
        let projection = try makeProjectionContainer()
        let coordinator = await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: app,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "phone"
        )
        try await coordinator.reconcile()
        let deletionDate = Date(timeIntervalSince1970: 1_800_000_001)
        let episodeRow = episodeStateRow(device: "phone", position: 90, updatedAt: 100)
        projection.mainContext.insert(episodeRow)
        try projection.mainContext.save()

        try await coordinator.markAllSubscriptionsDeleted(now: deletionDate)
        let refreshedProjectionContext = ModelContext(projection)

        let row = try XCTUnwrap(
            refreshedProjectionContext.fetch(
                FetchDescriptor<CloudPodcastProjection>()
            ).first
        )
        XCTAssertEqual(row.deletedAt, deletionDate)
        XCTAssertEqual(
            try refreshedProjectionContext.fetch(
                FetchDescriptor<CloudEpisodeStateProjection>()
            ).first?.deletedAt,
            deletionDate
        )

        let freshApplicationStore = try makeApplicationContainer()
        let restarted = await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: freshApplicationStore,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "phone"
        )
        try await restarted.reconcile()
        XCTAssertEqual(
            try freshApplicationStore.mainContext.fetchCount(FetchDescriptor<Podcast>()),
            0
        )
    }

    func testEverywhereDeleteIsIdempotentAndTombstonesEveryLibraryProjection() async throws {
        let app = try makeApplicationContainer()
        let projection = try makeProjectionContainer()
        let coordinator = await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: app,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "phone"
        )
        let podcast = CloudPodcastProjection()
        podcast.feedURL = "https://example.com/feed"
        let episode = episodeStateRow(device: "phone", position: 30, updatedAt: 10)
        let queue = CloudQueueItemProjection()
        queue.feedURL = "https://example.com/feed"
        queue.episodeGUID = "episode"
        queue.sourceDeviceID = "phone"
        queue.isQueued = true
        let bookmark = CloudBookmarkProjection()
        bookmark.bookmarkID = "bookmark"
        bookmark.feedURL = "https://example.com/feed"
        bookmark.episodeGUID = "episode"
        let session = CloudListeningSessionProjection()
        session.sessionID = "session"
        session.feedURL = "https://example.com/feed"
        let folder = CloudFolderProjection()
        folder.folderID = "folder"
        projection.mainContext.insert(podcast)
        projection.mainContext.insert(episode)
        projection.mainContext.insert(queue)
        projection.mainContext.insert(bookmark)
        projection.mainContext.insert(session)
        projection.mainContext.insert(folder)
        try projection.mainContext.save()
        let deletionDate = Date(timeIntervalSince1970: 500)

        try await coordinator.markAllSubscriptionsDeleted(now: deletionDate)
        try await coordinator.markAllSubscriptionsDeleted(now: Date(timeIntervalSince1970: 600))
        let refreshed = ModelContext(projection)

        XCTAssertEqual(
            try refreshed.fetch(FetchDescriptor<CloudPodcastProjection>()).first?.deletedAt,
            deletionDate
        )
        XCTAssertEqual(
            try refreshed.fetch(FetchDescriptor<CloudEpisodeStateProjection>()).first?.deletedAt,
            deletionDate
        )
        let refreshedQueue = try XCTUnwrap(
            refreshed.fetch(FetchDescriptor<CloudQueueItemProjection>()).first
        )
        XCTAssertEqual(refreshedQueue.deletedAt, deletionDate)
        XCTAssertFalse(refreshedQueue.isQueued)
        XCTAssertEqual(
            try refreshed.fetch(FetchDescriptor<CloudBookmarkProjection>()).first?.deletedAt,
            deletionDate
        )
        XCTAssertEqual(
            try refreshed.fetch(FetchDescriptor<CloudListeningSessionProjection>()).first?.deletedAt,
            deletionDate
        )
        XCTAssertEqual(
            try refreshed.fetch(FetchDescriptor<CloudFolderProjection>()).first?.deletedAt,
            deletionDate
        )
    }

    func testEpisodeProjectionContainsOnlyMeaningfulUserState() async throws {
        let app = try makeApplicationContainer()
        let podcast = Podcast(feedURL: "https://example.com/feed", title: "Show")
        app.mainContext.insert(podcast)
        var meaningful: [Episode] = []
        for index in 0..<1_000 {
            let episode = Episode(
                guid: "episode-\(index)", title: "Episode \(index)",
                audioURL: "https://example.com/\(index).mp3"
            )
            episode.podcast = podcast
            app.mainContext.insert(episode)
            if index == 42 || index == 73 { meaningful.append(episode) }
        }
        meaningful[0].positionSeconds = 120
        meaningful[1].isPlayed = true
        try app.mainContext.save()
        let projection = try makeProjectionContainer()
        let coordinator = await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: app,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "phone"
        )

        try await coordinator.reconcile()

        let rows = try projection.mainContext.fetch(
            FetchDescriptor<CloudEpisodeStateProjection>()
        )
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.map(\.episodeGUID)), ["episode-42", "episode-73"])
    }

    func testStaleProgressCannotMovePlaybackBackward() async throws {
        let app = try makeApplicationContainerWithEpisode(position: 200)
        let projection = try makeProjectionContainer()
        let phone = episodeStateRow(device: "phone", position: 200, updatedAt: 200)
        let staleMac = episodeStateRow(device: "mac", position: 100, updatedAt: 100)
        projection.mainContext.insert(phone)
        projection.mainContext.insert(staleMac)
        try projection.mainContext.save()
        let coordinator = await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: app,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "phone"
        )

        try await coordinator.reconcile()

        XCTAssertEqual(try XCTUnwrap(applicationEpisode(in: app)).positionSeconds, 200)
    }

    func testExplicitRewindOverridesOlderProgressThenLaterProgressAdvances() async throws {
        let app = try makeApplicationContainerWithEpisode(position: 200)
        let projection = try makeProjectionContainer()
        let stale = episodeStateRow(device: "phone", position: 200, updatedAt: 100)
        let rewind = episodeStateRow(device: "mac", position: 50, updatedAt: 200)
        rewind.positionResetAt = Date(timeIntervalSince1970: 200)
        projection.mainContext.insert(stale)
        projection.mainContext.insert(rewind)
        try projection.mainContext.save()
        let coordinator = await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: app,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "phone"
        )

        try await coordinator.reconcile()
        XCTAssertEqual(try XCTUnwrap(applicationEpisode(in: app)).positionSeconds, 50)

        rewind.positionSeconds = 80
        rewind.positionUpdatedAt = Date(timeIntervalSince1970: 300)
        rewind.modifiedAt = Date(timeIntervalSince1970: 300)
        try projection.mainContext.save()
        try await coordinator.reconcile()
        XCTAssertEqual(try XCTUnwrap(applicationEpisode(in: app)).positionSeconds, 80)
    }

    func testStaleUnplayedDeviceCannotUndoNewerPlayedStateWithoutExplicitAction() async throws {
        let app = try makeApplicationContainerWithEpisode(position: 100)
        let projection = try makeProjectionContainer()
        let played = episodeStateRow(device: "phone", position: 0, updatedAt: 200)
        played.isPlayed = true
        projection.mainContext.insert(played)
        try projection.mainContext.save()
        let coordinator = await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: app,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "mac"
        )

        try await coordinator.reconcile()

        XCTAssertTrue(try XCTUnwrap(applicationEpisode(in: app)).isPlayed)
    }

    func testExplicitMarkUnplayedCanOverrideNewerPlayedState() async throws {
        let app = try makeApplicationContainerWithEpisode(position: 100)
        let projection = try makeProjectionContainer()
        let played = episodeStateRow(device: "phone", position: 0, updatedAt: 200)
        played.isPlayed = true
        projection.mainContext.insert(played)
        try projection.mainContext.save()
        let coordinator = await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: app,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "mac"
        )
        try await coordinator.reconcile()
        let episode = try XCTUnwrap(applicationEpisode(in: app))
        episode.isPlayed = false
        try app.mainContext.save()
        let snapshot = try XCTUnwrap(EpisodeUserStateSnapshot(
            episode: episode,
            playedChangedExplicitly: true
        ))

        try await coordinator.publishLocalEpisodeStateChanges(
            snapshots: [snapshot],
            now: Date(timeIntervalSince1970: 300)
        )
        try await coordinator.reconcile()

        XCTAssertFalse(episode.isPlayed)
    }

    func testInboxDismissalSyncsIndependentlyFromPlayedState() async throws {
        let app = try makeApplicationContainerWithEpisode(position: 0)
        let projection = try makeProjectionContainer()
        let dismissed = episodeStateRow(device: "phone", position: 0, updatedAt: 100)
        dismissed.inboxDismissed = true
        dismissed.inboxDismissedUpdatedAt = Date(timeIntervalSince1970: 100)
        projection.mainContext.insert(dismissed)
        try projection.mainContext.save()
        let coordinator = await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: app,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "mac"
        )

        try await coordinator.reconcile()

        let episode = try XCTUnwrap(applicationEpisode(in: app))
        XCTAssertTrue(episode.inboxDismissed)
        XCTAssertFalse(episode.isPlayed)
    }

    func testNewerInboxReentryWinsOverOlderDismissal() async throws {
        let app = try makeApplicationContainerWithEpisode(position: 0)
        let episode = try XCTUnwrap(applicationEpisode(in: app))
        episode.inboxDismissed = true
        try app.mainContext.save()
        let projection = try makeProjectionContainer()
        let dismissed = episodeStateRow(device: "phone", position: 0, updatedAt: 100)
        dismissed.inboxDismissed = true
        dismissed.inboxDismissedUpdatedAt = Date(timeIntervalSince1970: 100)
        projection.mainContext.insert(dismissed)
        let reentered = episodeStateRow(device: "mac", position: 0, updatedAt: 200)
        reentered.inboxDismissed = false
        reentered.inboxDismissedUpdatedAt = Date(timeIntervalSince1970: 200)
        projection.mainContext.insert(reentered)
        try projection.mainContext.save()
        let coordinator = await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: app,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "ipad"
        )

        try await coordinator.reconcile()
        let refreshedEpisode = try XCTUnwrap(
            ModelContext(app).fetch(FetchDescriptor<Episode>()).first
        )

        XCTAssertFalse(refreshedEpisode.inboxDismissed)
        XCTAssertFalse(refreshedEpisode.isPlayed)
    }

    func testLegacyEpisodeProjectionDoesNotChangeInboxDismissal() async throws {
        let app = try makeApplicationContainerWithEpisode(position: 0)
        let projection = try makeProjectionContainer()
        let legacy = episodeStateRow(device: "phone", position: 0, updatedAt: 100)
        legacy.inboxDismissed = true
        projection.mainContext.insert(legacy)
        try projection.mainContext.save()
        let coordinator = await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: app,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "mac"
        )

        try await coordinator.reconcile()

        XCTAssertFalse(try XCTUnwrap(applicationEpisode(in: app)).inboxDismissed)
    }

    func testLivePositionSnapshotPublishesWithoutSavingApplicationEpisode() async throws {
        let app = try makeApplicationContainerWithEpisode(position: 10)
        let projection = try makeProjectionContainer()
        let coordinator = await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: app,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "phone"
        )
        let episode = try XCTUnwrap(applicationEpisode(in: app))
        let snapshot = try XCTUnwrap(EpisodeUserStateSnapshot(
            episode: episode,
            positionSeconds: 180
        ))

        try await coordinator.publishLocalEpisodeStateChanges(
            snapshots: [snapshot],
            now: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(episode.positionSeconds, 10,
                       "compact publication must not mutate the application store")
        let row = try XCTUnwrap(projection.mainContext.fetch(
            FetchDescriptor<CloudEpisodeStateProjection>()
        ).first)
        XCTAssertEqual(row.positionSeconds, 180)
        XCTAssertEqual(row.positionUpdatedAt, Date(timeIntervalSince1970: 200))
    }

    func testQueueProjectionConvergesOrderAndRemovalAcrossDevices() async throws {
        let phone = try makeApplicationContainer()
        let phonePodcast = Podcast(feedURL: "https://example.com/feed", title: "Show")
        let phoneA = Episode(guid: "a", title: "A", audioURL: "https://example.com/a")
        let phoneB = Episode(guid: "b", title: "B", audioURL: "https://example.com/b")
        phoneA.podcast = phonePodcast
        phoneB.podcast = phonePodcast
        phone.mainContext.insert(phonePodcast)
        phone.mainContext.insert(phoneA)
        phone.mainContext.insert(phoneB)
        phone.mainContext.insert(QueueItem(episode: phoneB, position: 0))
        phone.mainContext.insert(QueueItem(episode: phoneA, position: 1))
        try phone.mainContext.save()
        let projection = try makeProjectionContainer()
        let phoneCoordinator = await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: phone,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "phone"
        )
        try await phoneCoordinator.reconcile()

        let mac = try makeApplicationContainer()
        let macPodcast = Podcast(feedURL: "https://example.com/feed", title: "Show")
        let macA = Episode(guid: "a", title: "A", audioURL: "https://example.com/a")
        let macB = Episode(guid: "b", title: "B", audioURL: "https://example.com/b")
        macA.podcast = macPodcast
        macB.podcast = macPodcast
        mac.mainContext.insert(macPodcast)
        mac.mainContext.insert(macA)
        mac.mainContext.insert(macB)
        try mac.mainContext.save()
        let macCoordinator = await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: mac,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "mac"
        )

        try await macCoordinator.reconcile()

        XCTAssertEqual(
            try mac.mainContext.fetch(FetchDescriptor<QueueItem>(
                sortBy: [SortDescriptor(\.position)]
            )).compactMap { $0.episode?.guid },
            ["b", "a"]
        )

        let rows = try projection.mainContext.fetch(
            FetchDescriptor<CloudQueueItemProjection>()
        )
        XCTAssertEqual(rows.count, 2)
        let projectedA = try XCTUnwrap(rows.first { $0.episodeGUID == "a" })
        XCTAssertEqual(projectedA.episodeTitle, "A")
        XCTAssertEqual(projectedA.episodeAudioURL, "https://example.com/a")
        let removal = CloudQueueItemProjection()
        removal.feedURL = "https://example.com/feed"
        removal.episodeGUID = "b"
        removal.sourceDeviceID = "phone-2"
        removal.isQueued = false
        removal.modifiedAt = Date(timeIntervalSinceNow: 100)
        projection.mainContext.insert(removal)
        try projection.mainContext.save()
        try await macCoordinator.reconcile()

        XCTAssertEqual(
            try mac.mainContext.fetch(FetchDescriptor<QueueItem>())
                .compactMap { $0.episode?.guid },
            ["a"]
        )
    }

    func testQueueReorderOnStaleDeviceCannotResurrectExplicitRemoval() async throws {
        let app = try makeApplicationContainerWithEpisode(position: 0)
        let episode = try XCTUnwrap(applicationEpisode(in: app))
        app.mainContext.insert(QueueItem(episode: episode, position: 0))
        try app.mainContext.save()
        let projection = try makeProjectionContainer()

        let removal = queueRow(
            device: "phone", guid: "episode", queued: false, position: 0,
            membershipUpdatedAt: 200, modifiedAt: 200
        )
        let staleReorder = queueRow(
            device: "mac", guid: "episode", queued: true, position: 7,
            membershipUpdatedAt: 100, modifiedAt: 300
        )
        projection.mainContext.insert(removal)
        projection.mainContext.insert(staleReorder)
        try projection.mainContext.save()
        let coordinator = await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: app,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "ipad"
        )

        try await coordinator.reconcile()

        XCTAssertTrue(
            try app.mainContext.fetch(FetchDescriptor<QueueItem>()).isEmpty,
            "a newer order-only edit must not override an explicit remove decision"
        )
    }

    func testExplicitQueueReaddWinsAfterRemovalAndStaleReorder() async throws {
        let app = try makeApplicationContainerWithEpisode(position: 0)
        let projection = try makeProjectionContainer()
        projection.mainContext.insert(queueRow(
            device: "phone", guid: "episode", queued: false, position: 0,
            membershipUpdatedAt: 200, modifiedAt: 200
        ))
        projection.mainContext.insert(queueRow(
            device: "mac", guid: "episode", queued: true, position: 7,
            membershipUpdatedAt: 100, modifiedAt: 400
        ))
        projection.mainContext.insert(queueRow(
            device: "ipad", guid: "episode", queued: true, position: 1,
            membershipUpdatedAt: 300, modifiedAt: 300
        ))
        try projection.mainContext.save()
        let coordinator = await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: app,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "receiver"
        )

        try await coordinator.reconcile()

        XCTAssertEqual(
            try app.mainContext.fetch(FetchDescriptor<QueueItem>())
                .compactMap { $0.episode?.guid },
            ["episode"]
        )
    }

    func testQueuePositionStillUsesNewestOrderEditWhenMembershipClockIsOlder() async throws {
        let app = try makeApplicationContainer()
        let podcast = Podcast(feedURL: "https://example.com/feed", title: "Show")
        let a = Episode(guid: "a", title: "A", audioURL: "https://example.com/a")
        let b = Episode(guid: "b", title: "B", audioURL: "https://example.com/b")
        a.podcast = podcast
        b.podcast = podcast
        app.mainContext.insert(podcast)
        app.mainContext.insert(a)
        app.mainContext.insert(b)
        app.mainContext.insert(QueueItem(episode: b, position: 0))
        app.mainContext.insert(QueueItem(episode: a, position: 1))
        try app.mainContext.save()
        let projection = try makeProjectionContainer()

        projection.mainContext.insert(queueRow(
            device: "phone", guid: "a", queued: true, position: 2,
            membershipUpdatedAt: 200, modifiedAt: 200
        ))
        projection.mainContext.insert(queueRow(
            device: "mac", guid: "a", queued: true, position: 0,
            membershipUpdatedAt: 100, modifiedAt: 300
        ))
        projection.mainContext.insert(queueRow(
            device: "phone", guid: "b", queued: true, position: 1,
            membershipUpdatedAt: 200, modifiedAt: 200
        ))
        try projection.mainContext.save()
        let coordinator = await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: app,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "ipad"
        )

        try await coordinator.reconcile()

        XCTAssertEqual(
            try app.mainContext.fetch(FetchDescriptor<QueueItem>(
                sortBy: [SortDescriptor(\.position)]
            )).compactMap { $0.episode?.guid },
            ["a", "b"]
        )
    }

    func testPublishingQueueReorderDoesNotAdvanceMembershipClock() async throws {
        let app = try makeApplicationContainer()
        let podcast = Podcast(feedURL: "https://example.com/feed", title: "Show")
        let a = Episode(guid: "a", title: "A", audioURL: "https://example.com/a")
        let b = Episode(guid: "b", title: "B", audioURL: "https://example.com/b")
        a.podcast = podcast
        b.podcast = podcast
        app.mainContext.insert(podcast)
        app.mainContext.insert(a)
        app.mainContext.insert(b)
        let aItem = QueueItem(episode: a, position: 0)
        let bItem = QueueItem(episode: b, position: 1)
        app.mainContext.insert(aItem)
        app.mainContext.insert(bItem)
        try app.mainContext.save()
        let projection = try makeProjectionContainer()
        let coordinator = await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: app,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "phone"
        )

        try await coordinator.publishLocalQueueChanges(now: Date(timeIntervalSince1970: 100))
        let repository = QueueRepository(context: app.mainContext)
        XCTAssertTrue(repository.moveToBottom(a))
        let reorderDate = try XCTUnwrap(
            PendingCloudQueueMutation.orderings(in: app.mainContext)
                .max { $0.eventDate < $1.eventDate }?.eventDate
        )
        try await coordinator.publishLocalQueueChanges(now: Date(timeIntervalSince1970: 200))

        var rows = try projection.mainContext.fetch(FetchDescriptor<CloudQueueItemProjection>())
        let reorderedA = try XCTUnwrap(rows.first { $0.episodeGUID == "a" })
        XCTAssertEqual(reorderedA.modifiedAt, reorderDate)
        XCTAssertEqual(reorderedA.membershipUpdatedAt, Date(timeIntervalSince1970: 100))

        XCTAssertTrue(repository.cancelFromQueue(a))
        let removalDate = try XCTUnwrap(
            PendingCloudQueueMutation.memberships(in: app.mainContext)
                .filter { $0.guid == "a" && !$0.isQueued }
                .max { $0.eventDate < $1.eventDate }?.eventDate
        )
        try await coordinator.publishLocalQueueChanges(now: Date(timeIntervalSince1970: 300))

        rows = try projection.mainContext.fetch(FetchDescriptor<CloudQueueItemProjection>())
        let removedA = try XCTUnwrap(rows.first { $0.episodeGUID == "a" })
        XCTAssertFalse(removedA.isQueued)
        XCTAssertEqual(removedA.membershipUpdatedAt, removalDate)
    }

    func testUnprojectableQueueItemIsPreserved() async throws {
        let app = try makeApplicationContainer()
        let orphan = Episode(
            guid: "unrelated", title: "Unrelated", audioURL: "https://example.com/audio",
            status: .inQueue
        )
        let queueItem = QueueItem(episode: orphan, position: 0)
        app.mainContext.insert(orphan)
        app.mainContext.insert(queueItem)
        try app.mainContext.save()
        let projection = try makeProjectionContainer()
        let coordinator = await queueCoordinator(app, projection)

        try await coordinator.publishLocalQueueChanges()

        XCTAssertEqual(
            try app.mainContext.fetchCount(FetchDescriptor<Episode>()), 1
        )
        XCTAssertEqual(queueItem.episode?.guid, "unrelated")
        XCTAssertEqual(
            try projection.mainContext.fetchCount(
                FetchDescriptor<CloudQueueItemProjection>()
            ),
            0
        )
    }

    func testQueuePublisherNeverInfersRemovalFromRemoteOrLateOwnRows() async throws {
        let app = try makeApplicationContainer()
        _ = queueEpisode(in: app, guid: "legacy")
        try app.mainContext.save()
        let projection = try makeProjectionContainer()
        let remote = queueRow(
            device: "phone", guid: "remote-only", queued: true, position: 0,
            membershipUpdatedAt: 100, modifiedAt: 100
        )
        projection.mainContext.insert(remote)
        try projection.mainContext.save()
        let coordinator = await queueCoordinator(app, projection)

        try await coordinator.publishLocalQueueChanges(now: Date(timeIntervalSince1970: 200))

        let rows = try projection.mainContext.fetch(FetchDescriptor<CloudQueueItemProjection>())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.sourceDeviceID, "phone")
        XCTAssertEqual(rows.first?.isQueued, true)

        let lateOwn = queueRow(
            device: "mac", guid: "legacy", queued: true, position: 1,
            membershipUpdatedAt: 75, modifiedAt: 75
        )
        projection.mainContext.insert(lateOwn)
        try projection.mainContext.save()
        try await coordinator.publishLocalQueueChanges(now: Date(timeIntervalSince1970: 300))
        XCTAssertTrue(lateOwn.isQueued)
        XCTAssertEqual(lateOwn.membershipUpdatedAt, Date(timeIntervalSince1970: 75))
        XCTAssertTrue(try PendingCloudQueueMutation.memberships(in: app.mainContext).isEmpty)
    }

    func testDurableQueueRemovalIntentPublishesAfterCoordinatorRestart() async throws {
        let app = try makeApplicationContainer()
        let episode = queueEpisode(in: app, guid: "episode")
        try app.mainContext.save()
        let repository = QueueRepository(context: app.mainContext)
        repository.add(episode)

        let projection = try makeProjectionContainer()
        let first = await queueCoordinator(app, projection)
        try await first.publishLocalQueueChanges()
        XCTAssertTrue(try PendingCloudQueueMutation.memberships(in: app.mainContext).isEmpty)

        XCTAssertTrue(repository.cancelFromQueue(episode))
        let removal = try XCTUnwrap(
            try PendingCloudQueueMutation.memberships(in: app.mainContext)
                .filter { !$0.isQueued }
                .max { $0.eventDate < $1.eventDate }
        )

        let restarted = await queueCoordinator(app, projection)
        try await restarted.publishLocalQueueChanges()

        let own = try XCTUnwrap(
            try projection.mainContext.fetch(FetchDescriptor<CloudQueueItemProjection>())
                .first { $0.sourceDeviceID == "mac" && $0.episodeGUID == "episode" }
        )
        XCTAssertFalse(own.isQueued)
        XCTAssertEqual(
            own.membershipUpdatedAt.timeIntervalSinceReferenceDate,
            removal.eventDate.timeIntervalSinceReferenceDate,
            accuracy: 0.01
        )
        XCTAssertTrue(try PendingCloudQueueMutation.memberships(in: app.mainContext).isEmpty)
        XCTAssertTrue(try PendingCloudQueueMutation.orderings(in: app.mainContext).isEmpty)
    }

    func testExpiredQueueRemovalPublishesAfterCoordinatorRestart() async throws {
        let app = try makeApplicationContainer()
        _ = queueEpisode(
            in: app, guid: "expired", queuedAt: 0,
            addedAt: Date(timeIntervalSince1970: 0), ageLimit: 1
        )
        try app.mainContext.save()
        let projection = try makeProjectionContainer()
        projection.mainContext.insert(queueRow(
            device: "mac", guid: "expired", queued: true, position: 0,
            membershipUpdatedAt: 100, modifiedAt: 100
        ))
        try projection.mainContext.save()
        let expirationDate = Date(timeIntervalSince1970: 300_000)

        ExpirationService(context: app.mainContext).runExpiration(now: expirationDate)
        let restarted = await queueCoordinator(app, projection)
        try await restarted.publishLocalQueueChanges(now: Date(timeIntervalSince1970: 400_000))

        let own = try XCTUnwrap(
            projection.mainContext.fetch(FetchDescriptor<CloudQueueItemProjection>()).first {
                $0.sourceDeviceID == "mac" && $0.episodeGUID == "expired"
            }
        )
        XCTAssertFalse(own.isQueued)
        XCTAssertEqual(own.membershipUpdatedAt, expirationDate)
        XCTAssertTrue(try PendingCloudQueueMutation.memberships(in: app.mainContext).isEmpty)
        XCTAssertTrue(try PendingCloudQueueMutation.orderings(in: app.mainContext).isEmpty)
    }

    func testQueueBootstrapPublishesOnlyLocalKeyWithNoCloudContribution() async throws {
        let app = try makeApplicationContainer()
        _ = queueEpisode(
            in: app, guid: "local", feedURL: "https://local.example/feed", queuedAt: 0
        )
        try app.mainContext.save()
        let projection = try makeProjectionContainer()
        projection.mainContext.insert(queueRow(
            device: "phone", guid: "unrelated", queued: true, position: 0,
            membershipUpdatedAt: 100, modifiedAt: 100
        ))
        try projection.mainContext.save()
        let coordinator = await queueCoordinator(app, projection)

        try await coordinator.publishLocalQueueChanges(now: Date(timeIntervalSince1970: 200))

        let rows = try projection.mainContext.fetch(FetchDescriptor<CloudQueueItemProjection>())
        let local = try XCTUnwrap(rows.first {
            $0.sourceDeviceID == "mac" && $0.episodeGUID == "local"
        })
        XCTAssertTrue(local.isQueued)
        XCTAssertFalse(rows.contains {
            $0.sourceDeviceID == "mac" && $0.episodeGUID == "unrelated"
        })
        XCTAssertTrue(try PendingCloudQueueMutation.bootstrapCompleted(in: app.mainContext))

        let eventFeed = try XCTUnwrap(local.episodeGUID == "local" ? local.feedURL : nil)
        PendingCloudQueueMutation.stageMembership(
            feedURL: eventFeed, guid: "local", isQueued: true,
            eventDate: Date(timeIntervalSince1970: 300), in: app.mainContext
        )
        PendingCloudQueueMutation.stageOrdering(
            eventDate: Date(timeIntervalSince1970: 400), in: app.mainContext
        )
        try app.mainContext.save()
        let clockCoordinator = await queueCoordinator(app, projection)
        try await clockCoordinator.publishLocalQueueChanges(now: Date(timeIntervalSince1970: 500))
        let clocked = try XCTUnwrap(ModelContext(projection)
            .fetch(FetchDescriptor<CloudQueueItemProjection>()).first { $0.episodeGUID == "local" })
        XCTAssertEqual(clocked.membershipUpdatedAt, Date(timeIntervalSince1970: 300))
        XCTAssertEqual(clocked.modifiedAt, Date(timeIntervalSince1970: 400))
    }

    func testRemoteQueueMaterializesEpisodeMissingFromLocalCatalog() async throws {
        let app = try makeApplicationContainer()
        let podcast = Podcast(feedURL: "https://example.com/feed", title: "Show")
        app.mainContext.insert(podcast)
        try app.mainContext.save()
        let projection = try makeProjectionContainer()
        let row = CloudQueueItemProjection()
        row.feedURL = podcast.feedURL
        row.episodeGUID = "remote-episode"
        row.episodeTitle = "Remote episode"
        row.episodeAudioURL = "https://example.com/remote.mp3"
        row.episodeDescription = "Description"
        row.episodeDurationSeconds = 321
        row.episodePubDate = Date(timeIntervalSince1970: 200)
        row.sourceDeviceID = "phone"
        row.isQueued = true
        row.position = 4
        row.modifiedAt = Date(timeIntervalSince1970: 300)
        projection.mainContext.insert(row)
        try projection.mainContext.save()
        let coordinator = await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: app,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "mac"
        )

        try await coordinator.reconcile()

        let episode = try XCTUnwrap(
            app.mainContext.fetch(FetchDescriptor<Episode>()).first {
                $0.guid == "remote-episode"
            }
        )
        XCTAssertEqual(episode.podcast?.feedURL, podcast.feedURL)
        XCTAssertEqual(episode.title, "Remote episode")
        XCTAssertEqual(episode.audioURL, "https://example.com/remote.mp3")
        XCTAssertEqual(episode.durationSeconds, 321)
        XCTAssertTrue(episode.inboxDismissed)
        XCTAssertEqual(episode.status, .inQueue)
        XCTAssertEqual(
            try app.mainContext.fetch(FetchDescriptor<QueueItem>()).first?.episode?.guid,
            "remote-episode"
        )

        // Applying another device's Queue must not manufacture this device's
        // affirmative contribution when the queue-change notification is later
        // reconciled. Only a subsequent local semantic edit may do that.
        try await coordinator.publishLocalQueueChanges(now: Date(timeIntervalSince1970: 400))
        let contributions = try projection.mainContext.fetch(
            FetchDescriptor<CloudQueueItemProjection>()
        ).filter { $0.episodeGUID == "remote-episode" && $0.deletedAt == nil }
        XCTAssertEqual(contributions.map(\.sourceDeviceID), ["phone"])
        XCTAssertTrue(try PendingCloudQueueMutation.memberships(in: app.mainContext).isEmpty)
        XCTAssertTrue(try PendingCloudQueueMutation.orderings(in: app.mainContext).isEmpty)
    }

    func testPlaybackCompletionDuringRemoteQueueApplyDoesNotResurrectFinishedEpisode() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "cloud-queue-race-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try makeOnDiskApplicationContainer(
            applicationURL: root.appending(path: "application.store"),
            localURL: root.appending(path: "local.store")
        )
        let projection = try makeOnDiskProjectionContainer(
            at: root.appending(path: "projection.store")
        )

        let podcast = Podcast(feedURL: "https://example.com/feed", title: "Show")
        let finished = Episode(
            guid: "finished", title: "Finished", audioURL: "https://example.com/finished.mp3",
            status: .inQueue
        )
        let next = Episode(
            guid: "next", title: "Next", audioURL: "https://example.com/next.mp3",
            status: .inQueue
        )
        finished.podcast = podcast
        next.podcast = podcast
        app.mainContext.insert(podcast)
        app.mainContext.insert(finished)
        app.mainContext.insert(next)
        app.mainContext.insert(QueueItem(episode: finished, position: 0))
        app.mainContext.insert(QueueItem(episode: next, position: 1))
        try PendingCloudQueueMutation.markBootstrapCompleted(in: app.mainContext)
        try app.mainContext.save()

        projection.mainContext.insert(queueRow(
            device: "remote", guid: "finished", queued: true, position: 0,
            membershipUpdatedAt: 100, modifiedAt: 100
        ))
        try projection.mainContext.save()

        let queueApplicationGate = QueueApplicationRaceGate()
        let shouldPause = Mutex(true)
        let observedStages = Mutex<[String]>([])
        let coordinator = await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: app,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "receiver",
            queueApplicationCheckpoint: { stage in
                observedStages.withLock { $0.append(stage) }
                guard stage.hasPrefix("episodes-resolved:"),
                      shouldPause.withLock({ pause in
                          defer { pause = false }
                          return pause
                      }) else { return }
                await queueApplicationGate.pause()
            }
        )

        let racedReconciliation = Task {
            do {
                try await coordinator.reconcile()
                await queueApplicationGate.finish()
            } catch {
                await queueApplicationGate.finish()
                throw error
            }
        }
        guard await queueApplicationGate.waitUntilPaused() else {
            try await racedReconciliation.value
            return XCTFail("Reconciliation ended before the queue race checkpoint")
        }
        XCTAssertTrue(observedStages.withLock { $0.contains("episodes-resolved:1") })

        do {
            let playbackContext = app.mainContext
            let playbackEpisode = try XCTUnwrap(
                playbackContext.fetch(FetchDescriptor<Episode>()).first { $0.guid == "finished" }
            )
            XCTAssertNotNil(playbackEpisode.queueItem)
            XCTAssertTrue(
                QueueRepository(context: playbackContext).markPlayedAndRemove(playbackEpisode)
            )
            XCTAssertTrue(playbackEpisode.isPlayed)
            XCTAssertTrue(try PendingCloudQueueMutation.memberships(in: playbackContext).contains {
                $0.guid == "finished" && !$0.isQueued
            })
        } catch {
            await queueApplicationGate.resume()
            _ = try? await racedReconciliation.value
            throw error
        }

        await queueApplicationGate.resume()
        try await racedReconciliation.value

        let racedStages = observedStages.withLock { $0 }
        XCTAssertTrue(
            racedStages.contains("episodes-resolved:1"),
            "The coordinator must retain the finished Episode's QueueItem inverse"
        )
        XCTAssertTrue(
            racedStages.contains("existing-fetched:0"),
            "The post-completion fetch must observe no QueueItem before materialization"
        )
        var fresh = ModelContext(app)
        var items = try fresh.fetch(FetchDescriptor<QueueItem>())
        XCTAssertFalse(items.contains { $0.episode?.guid == "finished" })
        XCTAssertEqual(items.filter { $0.episode?.guid == "next" }.count, 1)

        // The raced pass must defer the stale affirmative row. A clean pass then
        // publishes playback's newer durable removal and converges all contexts.
        try await coordinator.reconcile()

        fresh = ModelContext(app)
        items = try fresh.fetch(FetchDescriptor<QueueItem>())
        XCTAssertFalse(items.contains { $0.episode?.guid == "finished" })
        XCTAssertEqual(items.filter { $0.episode?.guid == "next" }.count, 1)
        XCTAssertTrue(try PendingCloudQueueMutation.memberships(in: fresh).isEmpty)
        let contributions = try ModelContext(projection)
            .fetch(FetchDescriptor<CloudQueueItemProjection>())
            .filter { $0.episodeGUID == "finished" && $0.deletedAt == nil }
        let winner = try XCTUnwrap(contributions.sorted {
            if $0.membershipUpdatedAt != $1.membershipUpdatedAt {
                return $0.membershipUpdatedAt > $1.membershipUpdatedAt
            }
            return $0.sourceDeviceID < $1.sourceDeviceID
        }.first)
        XCTAssertFalse(winner.isQueued)
        XCTAssertEqual(winner.sourceDeviceID, "receiver")
        let episodeIDs = items.compactMap { $0.episode?.persistentModelID }
        XCTAssertEqual(Set(episodeIDs).count, episodeIDs.count)

        // Cloud application must refresh the same graph the UI and player use.
        // A subsequent real repository add/remove on mainContext must neither
        // see a stale inverse nor trap in SwiftData's relationship setter.
        let mainRepository = QueueRepository(context: app.mainContext)
        mainRepository.add(finished)
        XCTAssertNotNil(finished.queueItem)
        XCTAssertTrue(mainRepository.markPlayedAndRemove(finished))
        XCTAssertNil(finished.queueItem)
    }

    func testEqualClockPendingRemovalWinsByOrderingThenDeviceTie() async throws {
        struct Scenario: Sendable {
            let name: String
            let orderingTime: TimeInterval
            let remoteModifiedTime: TimeInterval
            let receiverDevice: String
            let remoteDevice: String
        }
        let membershipTime: TimeInterval = 100
        let scenarios = [
            Scenario(
                name: "newer ordering",
                orderingTime: 200,
                remoteModifiedTime: 150,
                receiverDevice: "z-receiver",
                remoteDevice: "a-remote"
            ),
            Scenario(
                name: "device tie",
                orderingTime: 100,
                remoteModifiedTime: 100,
                receiverDevice: "a-receiver",
                remoteDevice: "z-remote"
            ),
        ]

        for scenario in scenarios {
            let app = try makeApplicationContainer()
            let episode = queueEpisode(in: app, guid: "episode")
            try PendingCloudQueueMutation.markBootstrapCompleted(in: app.mainContext)
            try app.mainContext.save()
            let projection = try makeProjectionContainer()
            projection.mainContext.insert(queueRow(
                device: scenario.remoteDevice,
                guid: episode.guid,
                queued: true,
                position: 0,
                membershipUpdatedAt: membershipTime,
                modifiedAt: scenario.remoteModifiedTime
            ))
            try projection.mainContext.save()
            let didStage = Mutex(false)
            let coordinator = await CloudProjectionCoordinator.makeForTesting(
                applicationContainer: app,
                projectionContainer: projection,
                center: NotificationCenter(),
                deviceID: scenario.receiverDevice,
                queueApplicationCheckpoint: { stage in
                    guard stage.hasPrefix("episodes-resolved:"),
                          didStage.withLock({ staged in
                              defer { staged = true }
                              return !staged
                          }) else { return }
                    try await MainActor.run {
                        PendingCloudQueueMutation.stageMembership(
                            feedURL: "https://example.com/feed",
                            guid: "episode",
                            isQueued: false,
                            eventDate: Date(timeIntervalSince1970: membershipTime),
                            in: app.mainContext
                        )
                        PendingCloudQueueMutation.stageOrdering(
                            eventDate: Date(timeIntervalSince1970: scenario.orderingTime),
                            in: app.mainContext
                        )
                        try app.mainContext.save()
                    }
                }
            )

            try await coordinator.reconcile()

            XCTAssertTrue(
                try ModelContext(app).fetch(FetchDescriptor<QueueItem>()).isEmpty,
                scenario.name
            )
            XCTAssertFalse(
                try PendingCloudQueueMutation.memberships(in: app.mainContext).isEmpty,
                scenario.name
            )

            try await coordinator.reconcile()

            XCTAssertTrue(
                try ModelContext(app).fetch(FetchDescriptor<QueueItem>()).isEmpty,
                scenario.name
            )
            XCTAssertTrue(
                try PendingCloudQueueMutation.memberships(in: app.mainContext).isEmpty,
                scenario.name
            )
            let own = try XCTUnwrap(
                try ModelContext(projection).fetch(FetchDescriptor<CloudQueueItemProjection>())
                    .first { $0.sourceDeviceID == scenario.receiverDevice },
                scenario.name
            )
            XCTAssertFalse(own.isQueued, scenario.name)
            XCTAssertEqual(
                own.membershipUpdatedAt,
                Date(timeIntervalSince1970: membershipTime),
                scenario.name
            )
            XCTAssertEqual(
                own.modifiedAt,
                Date(timeIntervalSince1970: scenario.orderingTime),
                scenario.name
            )
        }
    }

    func testRemoteReorderPreservesCatalogSlotAndSecondReconcileIsIdempotent() async throws {
        let app = try makeApplicationContainer()
        let followed = Podcast(feedURL: "https://example.com/feed", title: "Followed")
        let catalog = Podcast(
            feedURL: "https://catalog.example/feed",
            title: "Catalog",
            subscriptionStateRaw: PodcastSubscriptionState.catalogOnly.rawValue
        )
        let a = Episode(guid: "a", title: "A", audioURL: "https://example.com/a.mp3")
        let b = Episode(guid: "b", title: "B", audioURL: "https://example.com/b.mp3")
        let localCatalog = Episode(
            guid: "catalog",
            title: "Catalog",
            audioURL: "https://catalog.example/catalog.mp3"
        )
        a.podcast = followed
        b.podcast = followed
        localCatalog.podcast = catalog
        app.mainContext.insert(followed)
        app.mainContext.insert(catalog)
        app.mainContext.insert(a)
        app.mainContext.insert(b)
        app.mainContext.insert(localCatalog)
        app.mainContext.insert(QueueItem(episode: a, position: 0))
        app.mainContext.insert(QueueItem(episode: localCatalog, position: 1))
        app.mainContext.insert(QueueItem(episode: b, position: 2))
        try PendingCloudQueueMutation.markBootstrapCompleted(in: app.mainContext)
        try app.mainContext.save()

        let projection = try makeProjectionContainer()
        projection.mainContext.insert(queueRow(
            device: "remote", guid: "a", queued: true, position: 1,
            membershipUpdatedAt: 100, modifiedAt: 200
        ))
        projection.mainContext.insert(queueRow(
            device: "remote", guid: "b", queued: true, position: 0,
            membershipUpdatedAt: 100, modifiedAt: 200
        ))
        try projection.mainContext.save()
        let coordinator = await queueCoordinator(app, projection)

        try await coordinator.reconcile()

        var context = ModelContext(app)
        var items = try context.fetch(FetchDescriptor<QueueItem>(
            sortBy: [SortDescriptor(\.position)]
        ))
        XCTAssertEqual(items.compactMap { $0.episode?.guid }, ["b", "catalog", "a"])
        XCTAssertEqual(items.map(\.position), [0, 1, 2])
        let firstIDs = items.map(\.persistentModelID)
        XCTAssertTrue(catalog.isCatalogOnly)

        try await coordinator.reconcile()

        context = ModelContext(app)
        items = try context.fetch(FetchDescriptor<QueueItem>(
            sortBy: [SortDescriptor(\.position)]
        ))
        XCTAssertEqual(items.compactMap { $0.episode?.guid }, ["b", "catalog", "a"])
        XCTAssertEqual(items.map(\.position), [0, 1, 2])
        XCTAssertEqual(items.map(\.persistentModelID), firstIDs)
        XCTAssertEqual(
            try ModelContext(projection).fetchCount(FetchDescriptor<CloudQueueItemProjection>()),
            2
        )
    }

    func testSimultaneousQueueAddReorderAndRemoveConvergesInEitherArrivalOrder() async throws {
        for reverseArrival in [false, true] {
            let app = try makeApplicationContainer()
            let podcast = Podcast(feedURL: "https://example.com/feed", title: "Show")
            app.mainContext.insert(podcast)
            for guid in ["a", "b", "c", "d"] {
                let episode = Episode(
                    guid: guid,
                    title: guid.uppercased(),
                    audioURL: "https://example.com/\(guid)"
                )
                episode.podcast = podcast
                app.mainContext.insert(episode)
                if guid == "b" {
                    app.mainContext.insert(QueueItem(episode: episode, position: 0))
                }
            }
            try LocalAppSettingIdentity.setValue(
                "b",
                for: SettingsKey.lastPlayingEpisodeID,
                in: app.mainContext
            )
            try app.mainContext.save()
            let projection = try makeProjectionContainer()
            let rows = [
                queueRow(device: "phone", guid: "a", queued: true, position: 2, modifiedAt: 100),
                queueRow(device: "mac", guid: "a", queued: true, position: 0, modifiedAt: 200),
                queueRow(device: "phone", guid: "b", queued: true, position: 0, modifiedAt: 200),
                queueRow(device: "mac", guid: "b", queued: false, position: 0, modifiedAt: 300),
                queueRow(device: "phone", guid: "c", queued: true, position: 1, modifiedAt: 200),
                queueRow(device: "mac", guid: "d", queued: true, position: 1, modifiedAt: 250),
            ]
            let arrival = reverseArrival ? Array(rows.reversed()) : rows
            for row in arrival {
                projection.mainContext.insert(row)
            }
            try projection.mainContext.save()
            let coordinator = await CloudProjectionCoordinator.makeForTesting(
                applicationContainer: app,
                projectionContainer: projection,
                center: NotificationCenter(),
                deviceID: "receiver"
            )

            try await coordinator.reconcile()

            let queue = try app.mainContext.fetch(FetchDescriptor<QueueItem>(
                sortBy: [SortDescriptor(\.position)]
            ))
            XCTAssertEqual(queue.compactMap { $0.episode?.guid }, ["a", "c", "d"])
            XCTAssertEqual(queue.map(\.position), [0, 1, 2])
            XCTAssertNotNil(
                try app.mainContext.fetch(FetchDescriptor<Episode>()).first { $0.guid == "b" },
                "removing the current item from the queue must not delete its episode"
            )
            XCTAssertEqual(
                LocalAppSettingIdentity.value(
                    for: SettingsKey.lastPlayingEpisodeID,
                    in: app.mainContext
                ),
                "b",
                "remote queue reconciliation must not replace this device's current player"
            )
        }
    }

    func testPersonalPodcastNamePersistsAcrossDiskStoreReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let applicationURL = directory.appendingPathComponent("application.store")
        let localURL = directory.appendingPathComponent("local.store")
        do {
            let app = try makeOnDiskApplicationContainer(applicationURL: applicationURL, localURL: localURL)
            let podcast = Podcast(feedURL: "https://reopen.example/feed", title: "Publisher Audio")
            app.mainContext.insert(podcast)
            try app.mainContext.save()
            try PodcastDisplayNames.shared.save("Personal Show", for: podcast, context: app.mainContext)
        }
        let reopened = try makeOnDiskApplicationContainer(applicationURL: applicationURL, localURL: localURL)
        let podcast = try XCTUnwrap(reopened.mainContext.fetch(FetchDescriptor<Podcast>()).first)
        PodcastDisplayNames.shared.reload(context: reopened.mainContext)
        XCTAssertEqual(podcast.displayName, "Personal Show")
        XCTAssertEqual(podcast.title, "Publisher Audio")
    }

    func testPersonalPodcastNameAndExplicitRestoreRoundTrip() async throws {
        let phone = try makeApplicationContainerWithEpisode(position: 120)
        let episode = try XCTUnwrap(applicationEpisode(in: phone))
        let podcast = try XCTUnwrap(episode.podcast)
        let key = SettingsKey.podcastDisplayName(feedURL: podcast.feedURL)
        try PodcastDisplayNames.shared.save("Personal Show", for: podcast, context: phone.mainContext)
        let projection = try makeProjectionContainer()
        let phoneCoordinator = await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: phone, projectionContainer: projection,
            center: NotificationCenter(), deviceID: "phone"
        )
        try await phoneCoordinator.reconcile()
        let mac = try makeApplicationContainerWithEpisode(position: 0)
        let macCoordinator = await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: mac, projectionContainer: projection,
            center: NotificationCenter(), deviceID: "mac"
        )
        try await macCoordinator.reconcile()
        XCTAssertEqual(AppSettingsStore(context: mac.mainContext).rawValue(key), "Personal Show")
        try AppSettingIdentity.setValue("", for: key, in: mac.mainContext)
        try mac.mainContext.save()
        try await macCoordinator.publishLocalSettingChange(key: key, now: .distantFuture)
        try await phoneCoordinator.reconcile()
        XCTAssertEqual(AppSettingsStore(context: phone.mainContext).rawValue(key), "")
        XCTAssertEqual(episode.positionSeconds, 120)
    }

    func testNewestMirroredSettingWinsWithoutCopyingLocalSettings() async throws {
        let phone = try makeApplicationContainer()
        let phoneSettings = AppSettingsStore(context: phone.mainContext)
        phoneSettings.setDouble(1.5, for: SettingsKey.globalSpeed)
        phoneSettings.setRawValue("phone-only", for: SettingsKey.lastPlayingEpisodeID)
        let projection = try makeProjectionContainer()
        let phoneCenter = NotificationCenter()
        let phoneCoordinator = await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: phone,
            projectionContainer: projection,
            center: phoneCenter,
            deviceID: "phone"
        )
        try await phoneCoordinator.reconcile()

        let mac = try makeApplicationContainer()
        let macCoordinator = await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: mac,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "mac"
        )
        try await macCoordinator.reconcile()
        let macSettings = AppSettingsStore(context: mac.mainContext)
        XCTAssertEqual(macSettings.double(SettingsKey.globalSpeed, default: 1), 1.5)
        XCTAssertNil(macSettings.rawValue(SettingsKey.lastPlayingEpisodeID))

        macSettings.setDouble(2, for: SettingsKey.globalSpeed)
        try await macCoordinator.publishLocalSettingChange(
            key: SettingsKey.globalSpeed,
            now: .distantFuture
        )
        var settingsApplyCount = 0
        let token = phoneCenter.addObserver(
            forName: .earshotCloudSettingsProjectionDidApply,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { settingsApplyCount += 1 }
        }
        defer { phoneCenter.removeObserver(token) }
        try await phoneCoordinator.reconcile()

        XCTAssertEqual(phoneSettings.double(SettingsKey.globalSpeed, default: 1), 2)
        XCTAssertEqual(settingsApplyCount, 1)
    }

    func testCoreLibraryRoundTripFromPhoneToMacAndBack() async throws {
        let projection = try makeProjectionContainer()
        let phone = try makeApplicationContainerWithEpisode(position: 120)
        let phoneEpisode = try XCTUnwrap(applicationEpisode(in: phone))
        phone.mainContext.insert(QueueItem(episode: phoneEpisode, position: 0))
        let phoneSettings = AppSettingsStore(context: phone.mainContext)
        phoneSettings.setDouble(1.5, for: SettingsKey.globalSpeed)
        try phone.mainContext.save()
        let phoneCoordinator = await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: phone,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "phone"
        )
        try await phoneCoordinator.reconcile()

        let mac = try makeApplicationContainerWithEpisode(position: 0)
        let macCoordinator = await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: mac,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "mac"
        )
        try await macCoordinator.reconcile()
        let macEpisode = try XCTUnwrap(applicationEpisode(in: mac))
        XCTAssertEqual(macEpisode.positionSeconds, 120)
        XCTAssertEqual(
            try mac.mainContext.fetch(FetchDescriptor<QueueItem>()).first?.episode?.guid,
            "episode"
        )
        XCTAssertEqual(
            AppSettingsStore(context: mac.mainContext)
                .double(SettingsKey.globalSpeed, default: 1),
            1.5
        )

        let macPodcast = try XCTUnwrap(
            mac.mainContext.fetch(FetchDescriptor<Podcast>()).first
        )
        macPodcast.title = "Renamed on Mac"
        macEpisode.positionSeconds = 240
        XCTAssertTrue(QueueRepository(context: mac.mainContext).cancelFromQueue(macEpisode))
        let macSettings = AppSettingsStore(context: mac.mainContext)
        macSettings.setDouble(2, for: SettingsKey.globalSpeed)
        let later = Date.distantFuture
        try await macCoordinator.publishLocalSubscriptionChanges(now: later)
        try await macCoordinator.publishLocalEpisodeStateChanges(
            snapshots: [try XCTUnwrap(EpisodeUserStateSnapshot(episode: macEpisode))],
            now: later
        )
        try await macCoordinator.publishLocalQueueChanges(now: later)
        try await macCoordinator.publishLocalSettingChange(
            key: SettingsKey.globalSpeed,
            now: later
        )

        try await phoneCoordinator.reconcile()
        let refreshedPhoneContext = ModelContext(phone)
        XCTAssertEqual(
            try refreshedPhoneContext.fetch(FetchDescriptor<Podcast>()).first?.title,
            "Renamed on Mac"
        )
        XCTAssertEqual(
            try refreshedPhoneContext.fetch(FetchDescriptor<Episode>()).first?.positionSeconds,
            240
        )
        XCTAssertTrue(try refreshedPhoneContext.fetch(FetchDescriptor<QueueItem>()).isEmpty)
        XCTAssertEqual(
            AppSettingsStore(context: refreshedPhoneContext)
                .double(SettingsKey.globalSpeed, default: 1),
            2
        )
    }

    func testFreshDeviceCannotReduceGrandfatheredPodcastAllowance() async throws {
        let app = try makeApplicationContainer()
        let projection = try makeProjectionContainer()
        let olderPhone = CloudSettingProjection()
        olderPhone.key = SettingsKey.grandfatheredPodcastCount
        olderPhone.value = "662"
        olderPhone.sourceDeviceID = "phone"
        olderPhone.modifiedAt = Date(timeIntervalSince1970: 100)
        projection.mainContext.insert(olderPhone)
        let newerMac = CloudSettingProjection()
        newerMac.key = SettingsKey.grandfatheredPodcastCount
        newerMac.value = "0"
        newerMac.sourceDeviceID = "mac"
        newerMac.modifiedAt = Date(timeIntervalSince1970: 200)
        projection.mainContext.insert(newerMac)
        try projection.mainContext.save()
        let coordinator = await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: app,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "test"
        )

        try await coordinator.reconcile()

        XCTAssertEqual(
            AppSettingsStore(context: app.mainContext).grandfatheredPodcastCount(),
            662
        )
    }

    func testBookmarksArriveAfterCatalogAndDeletionPropagates() async throws {
        let phone = try makeApplicationContainer()
        let podcast = Podcast(feedURL: "https://example.com/feed", title: "Show")
        let episode = Episode(guid: "episode", title: "Episode", audioURL: "https://example.com/audio")
        episode.podcast = podcast
        phone.mainContext.insert(podcast)
        phone.mainContext.insert(episode)
        let bookmark = Bookmark(
            episode: episode,
            positionSeconds: 42,
            note: "Remember",
            createdAt: Date(timeIntervalSince1970: 100)
        )
        phone.mainContext.insert(bookmark)
        try phone.mainContext.save()
        let projection = try makeProjectionContainer()
        let phoneCoordinator = await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: phone,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "phone"
        )
        try await phoneCoordinator.reconcile()

        let mac = try makeApplicationContainer()
        let macCoordinator = await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: mac,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "mac"
        )
        try await macCoordinator.reconcile()
        XCTAssertTrue(try mac.mainContext.fetch(FetchDescriptor<Bookmark>()).isEmpty)

        let macPodcast = Podcast(feedURL: "https://example.com/feed", title: "Show")
        let macEpisode = Episode(guid: "episode", title: "Episode", audioURL: "https://example.com/audio")
        macEpisode.podcast = macPodcast
        mac.mainContext.insert(macPodcast)
        mac.mainContext.insert(macEpisode)
        try mac.mainContext.save()
        try await macCoordinator.reconcile()
        XCTAssertEqual(try mac.mainContext.fetch(FetchDescriptor<Bookmark>()).first?.note, "Remember")

        phone.mainContext.delete(bookmark)
        try phone.mainContext.save()
        try await phoneCoordinator.publishLocalBookmarkChanges(now: Date(timeIntervalSince1970: 200))
        try await macCoordinator.reconcile()
        XCTAssertTrue(try mac.mainContext.fetch(FetchDescriptor<Bookmark>()).isEmpty)
    }

    func testListeningHistorySyncsWithoutRequiringEpisodeCatalog() async throws {
        let phone = try makeApplicationContainer()
        let podcast = Podcast(feedURL: "https://example.com/feed", title: "Show")
        phone.mainContext.insert(podcast)
        let session = ListeningSession(
            podcast: podcast,
            durationSeconds: 90,
            speed: 1.5,
            date: Date(timeIntervalSince1970: 100)
        )
        phone.mainContext.insert(session)
        try phone.mainContext.save()
        let projection = try makeProjectionContainer()
        let phoneCoordinator = await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: phone,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "phone"
        )
        try await phoneCoordinator.reconcile()

        let mac = try makeApplicationContainer()
        let macCoordinator = await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: mac,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "mac"
        )
        try await macCoordinator.reconcile()
        let imported = try XCTUnwrap(
            mac.mainContext.fetch(FetchDescriptor<ListeningSession>()).first
        )
        XCTAssertEqual(imported.durationSeconds, 90)
        XCTAssertEqual(imported.speed, 1.5)
        XCTAssertEqual(imported.podcast?.feedURL, "https://example.com/feed")

        phone.mainContext.delete(session)
        try phone.mainContext.save()
        try await phoneCoordinator.publishLocalListeningHistoryChanges(
            now: Date(timeIntervalSince1970: 200)
        )
        try await macCoordinator.reconcile()
        XCTAssertTrue(try mac.mainContext.fetch(FetchDescriptor<ListeningSession>()).isEmpty)
    }

    /// Reproduces the two build-205 TestFlight crashes: an old history row can
    /// retain a Podcast foreign key after its destination row has disappeared.
    /// SwiftData then supplies a future fault whose first stored-property read
    /// traps instead of throwing. Reconciliation must discard only that
    /// irrecoverable history row and remain idempotent across later launches.
    func testDanglingListeningSessionPodcastIsRepairedWithoutFaulting() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let applicationURL = directory.appending(path: "application.store")
        let projectionURL = directory.appending(path: "projection.store")

        try autoreleasepool {
            let app = try StoreMigration.openOrMigrate(at: applicationURL)
            let podcast = Podcast(feedURL: "https://example.com/dangling", title: "Show")
            app.mainContext.insert(podcast)
            app.mainContext.insert(ListeningSession(
                podcast: podcast,
                durationSeconds: 90,
                speed: 1.5,
                date: Date(timeIntervalSince1970: 100)
            ))
            try app.mainContext.save()
        }
        try executeSQLite(
            at: applicationURL,
            sql: "UPDATE ZLISTENINGSESSION SET ZPODCAST = 999999"
        )

        for _ in 0..<2 {
            do {
                let app = try StoreMigration.openOrMigrate(at: applicationURL)
                let projection = try makeOnDiskProjectionContainer(at: projectionURL)
                try await CloudProjectionCoordinator.makeForTesting(
                    applicationContainer: app,
                    projectionContainer: projection,
                    center: NotificationCenter(),
                    deviceID: "phone"
                ).reconcile()

                XCTAssertEqual(try app.mainContext.fetchCount(FetchDescriptor<Podcast>()), 1)
                XCTAssertEqual(
                    try app.mainContext.fetchCount(FetchDescriptor<ListeningSession>()),
                    0
                )
                XCTAssertEqual(
                    try projection.mainContext.fetchCount(
                        FetchDescriptor<CloudListeningSessionProjection>()
                    ),
                    0
                )
            }
        }
    }

    /// A missing Episode must not cost the user an otherwise valid podcast-level
    /// history record. This is the complementary dangling-reference shape.
    func testDanglingListeningSessionEpisodePreservesPodcastHistory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let applicationURL = directory.appending(path: "application.store")
        let projectionURL = directory.appending(path: "projection.store")

        try autoreleasepool {
            let app = try StoreMigration.openOrMigrate(at: applicationURL)
            let podcast = Podcast(feedURL: "https://example.com/preserved", title: "Show")
            let episode = Episode(
                guid: "missing-episode",
                title: "Episode",
                audioURL: "https://example.com/episode.mp3"
            )
            episode.podcast = podcast
            app.mainContext.insert(podcast)
            app.mainContext.insert(episode)
            app.mainContext.insert(ListeningSession(
                episode: episode,
                podcast: podcast,
                durationSeconds: 120,
                speed: 1.25,
                date: Date(timeIntervalSince1970: 200)
            ))
            try app.mainContext.save()
        }
        try executeSQLite(
            at: applicationURL,
            sql: "UPDATE ZLISTENINGSESSION SET ZEPISODE = 999999"
        )

        for _ in 0..<2 {
            do {
                let app = try StoreMigration.openOrMigrate(at: applicationURL)
                let projection = try makeOnDiskProjectionContainer(at: projectionURL)
                try await CloudProjectionCoordinator.makeForTesting(
                    applicationContainer: app,
                    projectionContainer: projection,
                    center: NotificationCenter(),
                    deviceID: "phone"
                ).reconcile()

                let session = try XCTUnwrap(
                    app.mainContext.fetch(FetchDescriptor<ListeningSession>()).first
                )
                XCTAssertNil(session.episode)
                XCTAssertEqual(session.podcast?.feedURL, "https://example.com/preserved")
                let row = try XCTUnwrap(
                    projection.mainContext.fetch(
                        FetchDescriptor<CloudListeningSessionProjection>()
                    ).first
                )
                XCTAssertEqual(row.feedURL, "https://example.com/preserved")
                XCTAssertNil(row.episodeGUID)
                XCTAssertEqual(row.durationSeconds, 120)
            }
        }
    }

    func testPartialListeningHistoryBackfillResumesOnDiskWithoutDuplicates() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let applicationURL = directory.appending(path: "application.store")
        let localURL = directory.appending(path: "local.store")
        let projectionURL = directory.appending(path: "projection.store")
        let sessionCount = 139
        let partialProjectionCount = 46

        try autoreleasepool {
            let app = try makeOnDiskApplicationContainer(
                applicationURL: applicationURL,
                localURL: localURL
            )
            let podcast = Podcast(feedURL: "https://example.com/feed", title: "Show")
            app.mainContext.insert(podcast)
            for index in 0..<sessionCount {
                app.mainContext.insert(ListeningSession(
                    podcast: podcast,
                    durationSeconds: index + 1,
                    speed: 1.5,
                    date: Date(timeIntervalSince1970: TimeInterval(index + 1))
                ))
            }
            try app.mainContext.save()

            let projection = try makeOnDiskProjectionContainer(at: projectionURL)
            for index in 0..<partialProjectionCount {
                let row = CloudListeningSessionProjection()
                row.sessionID = "existing-\(index)"
                row.feedURL = "https://example.com/feed"
                row.durationSeconds = index + 1
                row.speed = 1.5
                row.date = Date(timeIntervalSince1970: TimeInterval(index + 1))
                row.modifiedAt = Date(timeIntervalSince1970: 500)
                row.sourceDeviceID = "remote"
                projection.mainContext.insert(row)
            }
            try projection.mainContext.save()
        }

        for _ in 0..<2 {
            do {
                let app = try makeOnDiskApplicationContainer(
                    applicationURL: applicationURL,
                    localURL: localURL
                )
                let projection = try makeOnDiskProjectionContainer(at: projectionURL)
                try await CloudProjectionCoordinator.makeForTesting(
                    applicationContainer: app,
                    projectionContainer: projection,
                    center: NotificationCenter(),
                    deviceID: "phone"
                ).reconcile()

                let rows = try projection.mainContext.fetch(
                    FetchDescriptor<CloudListeningSessionProjection>()
                )
                XCTAssertEqual(rows.count, sessionCount)
                XCTAssertEqual(Set(rows.map { $0.sessionID }).count, sessionCount)
                XCTAssertEqual(
                    Set(rows.map {
                        "\($0.feedURL)|\($0.durationSeconds)|\($0.speed)|\($0.date.timeIntervalSince1970)"
                    }).count,
                    sessionCount
                )
                XCTAssertEqual(
                    try app.mainContext.fetchCount(FetchDescriptor<ListeningSession>()),
                    sessionCount
                )
            }
        }
    }

    func testListeningHistoryBackfillPreservesTombstoneAcrossRestart() async throws {
        let app = try makeApplicationContainer()
        let podcast = Podcast(feedURL: "https://example.com/feed", title: "Show")
        app.mainContext.insert(podcast)
        app.mainContext.insert(ListeningSession(
            podcast: podcast,
            durationSeconds: 90,
            speed: 1.5,
            date: Date(timeIntervalSince1970: 100)
        ))
        try app.mainContext.save()

        let projection = try makeProjectionContainer()
        let tombstone = CloudListeningSessionProjection()
        tombstone.sessionID = "deleted-session"
        tombstone.feedURL = "https://example.com/feed"
        tombstone.durationSeconds = 90
        tombstone.speed = 1.5
        tombstone.date = Date(timeIntervalSince1970: 100)
        tombstone.modifiedAt = Date(timeIntervalSince1970: 200)
        tombstone.deletedAt = Date(timeIntervalSince1970: 200)
        tombstone.sourceDeviceID = "remote"
        projection.mainContext.insert(tombstone)
        try projection.mainContext.save()

        for _ in 0..<2 {
            try await CloudProjectionCoordinator.makeForTesting(
                applicationContainer: app,
                projectionContainer: projection,
                center: NotificationCenter(),
                deviceID: "phone"
            ).reconcile()

            XCTAssertTrue(
                try app.mainContext.fetch(FetchDescriptor<ListeningSession>()).isEmpty
            )
            let rows = try projection.mainContext.fetch(
                FetchDescriptor<CloudListeningSessionProjection>()
            )
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows.first?.sessionID, "deleted-session")
            XCTAssertNotNil(rows.first?.deletedAt)
        }
    }

    func testNestedFoldersAndMembershipsConvergeWithoutCycles() async throws {
        let phone = try makeApplicationContainer()
        let podcast = Podcast(feedURL: "https://example.com/feed", title: "Show")
        let episode = Episode(guid: "episode", title: "Episode", audioURL: "https://example.com/audio")
        episode.podcast = podcast
        phone.mainContext.insert(podcast)
        phone.mainContext.insert(episode)
        let parent = PodcastFolder(name: "Parent", createdAt: Date(timeIntervalSince1970: 10))
        let child = PodcastFolder(name: "Child", createdAt: Date(timeIntervalSince1970: 20))
        child.parent = parent
        phone.mainContext.insert(parent)
        phone.mainContext.insert(child)
        phone.mainContext.insert(FolderMembership(folder: child, podcast: podcast, sortOrder: 2))
        phone.mainContext.insert(EpisodeFolderMembership(folder: child, episode: episode, sortOrder: 3))
        try phone.mainContext.save()
        let projection = try makeProjectionContainer()
        let phoneCoordinator = await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: phone,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "phone"
        )
        try await phoneCoordinator.reconcile()

        let mac = try makeApplicationContainer()
        let macPodcast = Podcast(feedURL: "https://example.com/feed", title: "Show")
        let macEpisode = Episode(guid: "episode", title: "Episode", audioURL: "https://example.com/audio")
        macEpisode.podcast = macPodcast
        mac.mainContext.insert(macPodcast)
        mac.mainContext.insert(macEpisode)
        try mac.mainContext.save()
        let macCoordinator = await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: mac,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "mac"
        )
        try await macCoordinator.reconcile()

        let macFolders = try mac.mainContext.fetch(FetchDescriptor<PodcastFolder>())
        let macChild = try XCTUnwrap(macFolders.first { $0.name == "Child" })
        XCTAssertEqual(macChild.parent?.name, "Parent")
        XCTAssertEqual(macChild.memberships?.first?.podcast?.feedURL, "https://example.com/feed")
        XCTAssertEqual(
            try mac.mainContext.fetch(FetchDescriptor<EpisodeFolderMembership>())
                .first?.episode?.guid,
            "episode"
        )

        phone.mainContext.delete(child)
        try phone.mainContext.save()
        try await phoneCoordinator.publishLocalFolderChanges(now: Date(timeIntervalSince1970: 100))
        try await macCoordinator.reconcile()

        let remainingFolders = try mac.mainContext.fetch(FetchDescriptor<PodcastFolder>())
        XCTAssertEqual(remainingFolders.map(\.name), ["Parent"])
        XCTAssertTrue(try mac.mainContext.fetch(FetchDescriptor<FolderMembership>()).isEmpty)
        XCTAssertTrue(
            try mac.mainContext.fetch(FetchDescriptor<EpisodeFolderMembership>()).isEmpty
        )
    }

    func testRemoteFolderCycleRepairsPersistAndNotifyOnce() async throws {
        let app = try makeApplicationContainer()
        let projection = try makeProjectionContainer()
        for (index, id, parentID) in [
            (0, "a", "b"),
            (1, "b", "c"),
            (2, "c", "a"),
        ] {
            let row = CloudFolderProjection()
            row.folderID = id
            row.name = id.uppercased()
            row.parentFolderID = parentID
            row.createdAt = Date(timeIntervalSince1970: TimeInterval(index + 1))
            row.modifiedAt = Date(timeIntervalSince1970: 100)
            row.sourceDeviceID = "remote"
            projection.mainContext.insert(row)
        }
        try projection.mainContext.save()
        let center = NotificationCenter()
        var repairNotices = 0
        let token = center.addObserver(
            forName: .earshotFolderSyncConflictRepaired,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { repairNotices += 1 }
        }
        defer { center.removeObserver(token) }

        try await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: app,
            projectionContainer: projection,
            center: center,
            deviceID: "phone"
        ).reconcile()

        let folders = try app.mainContext.fetch(FetchDescriptor<PodcastFolder>())
        let byName = Dictionary(uniqueKeysWithValues: folders.map { ($0.name, $0) })
        XCTAssertEqual(folders.count, 3)
        XCTAssertEqual(byName["A"]?.parent?.name, "B")
        XCTAssertEqual(byName["B"]?.parent?.name, "C")
        XCTAssertNil(byName["C"]?.parent)
        XCTAssertEqual(repairNotices, 1)
        for folder in folders {
            var seen: Set<PersistentIdentifier> = []
            var cursor: PodcastFolder? = folder
            while let current = cursor {
                XCTAssertTrue(seen.insert(current.persistentModelID).inserted)
                cursor = current.parent
            }
        }
    }

    func testCatalogGraphStaysLocalAcrossEveryProjectionEntity() async throws {
        let app = try makeApplicationContainer()
        let context = app.mainContext
        let feedURL = "https://catalog-local.example/feed"
        let podcast = Podcast(
            feedURL: feedURL,
            title: "Catalog local",
            subscriptionStateRaw: PodcastSubscriptionState.catalogOnly.rawValue
        )
        context.insert(podcast)
        let episode = Episode(
            guid: "catalog-episode",
            title: "Catalog episode",
            audioURL: "https://catalog-local.example/episode.mp3",
            positionSeconds: 42,
            inboxDismissed: true
        )
        episode.podcast = podcast
        context.insert(episode)
        context.insert(QueueItem(episode: episode, position: 0))
        context.insert(Bookmark(episode: episode, positionSeconds: 12, note: "Local"))
        context.insert(ListeningSession(
            episode: episode,
            podcast: podcast,
            durationSeconds: 30
        ))
        let folder = PodcastFolder(name: "Corrupt catalog folder")
        context.insert(folder)
        context.insert(FolderMembership(folder: folder, podcast: podcast))
        context.insert(EpisodeFolderMembership(folder: folder, episode: episode))
        try AppSettingIdentity.setValue(
            "all",
            for: SettingsKey.podcastFilter(feedURL: feedURL),
            in: context
        )
        try context.save()

        let projection = try makeProjectionContainer()
        let coordinator = await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: app,
            projectionContainer: projection
        )
        try await coordinator.reconcile()

        let projected = projection.mainContext
        XCTAssertEqual(try projected.fetchCount(FetchDescriptor<CloudPodcastProjection>()), 0)
        XCTAssertEqual(try projected.fetchCount(FetchDescriptor<CloudEpisodeStateProjection>()), 0)
        XCTAssertEqual(try projected.fetchCount(FetchDescriptor<CloudQueueItemProjection>()), 0)
        XCTAssertEqual(try projected.fetchCount(FetchDescriptor<CloudSettingProjection>()), 0)
        XCTAssertEqual(try projected.fetchCount(FetchDescriptor<CloudBookmarkProjection>()), 0)
        XCTAssertEqual(try projected.fetchCount(FetchDescriptor<CloudListeningSessionProjection>()), 0)
        let folderRows = try projected.fetch(FetchDescriptor<CloudFolderProjection>())
        XCTAssertEqual(folderRows.count, 1)
        XCTAssertFalse(folderRows[0].podcastMembersJSON.contains(feedURL))
        XCTAssertFalse(folderRows[0].episodeMembersJSON.contains(feedURL))

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<QueueItem>()), 1)
        XCTAssertNotNil(
            try PodcastIdentityService(context: context)
                .existingAnyState(feedURL: feedURL)
        )

        let remoteEpisode = CloudEpisodeStateProjection()
        remoteEpisode.feedURL = feedURL
        remoteEpisode.episodeGUID = episode.guid
        remoteEpisode.sourceDeviceID = "remote"
        remoteEpisode.positionSeconds = 999
        remoteEpisode.positionUpdatedAt = Date(timeIntervalSince1970: 200)
        remoteEpisode.isPlayed = true
        remoteEpisode.playedUpdatedAt = Date(timeIntervalSince1970: 200)
        remoteEpisode.modifiedAt = Date(timeIntervalSince1970: 200)
        let remoteQueue = CloudQueueItemProjection()
        remoteQueue.feedURL = feedURL
        remoteQueue.episodeGUID = episode.guid
        remoteQueue.sourceDeviceID = "remote"
        remoteQueue.isQueued = false
        remoteQueue.position = 99
        remoteQueue.membershipUpdatedAt = Date(timeIntervalSince1970: 200)
        remoteQueue.modifiedAt = Date(timeIntervalSince1970: 200)
        let remoteSetting = CloudSettingProjection()
        remoteSetting.key = SettingsKey.podcastFilter(feedURL: feedURL)
        remoteSetting.value = "unplayed"
        remoteSetting.sourceDeviceID = "remote"
        remoteSetting.modifiedAt = Date(timeIntervalSince1970: 200)
        projected.insert(remoteEpisode)
        projected.insert(remoteQueue)
        projected.insert(remoteSetting)
        try projected.save()

        try await coordinator.reconcile()

        XCTAssertTrue(podcast.isCatalogOnly)
        XCTAssertEqual(podcast.title, "Catalog local")
        XCTAssertEqual(episode.positionSeconds, 42)
        XCTAssertFalse(episode.isPlayed)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<QueueItem>()), 1)
        XCTAssertEqual(
            AppSettingIdentity.value(
                for: SettingsKey.podcastFilter(feedURL: feedURL),
                in: context
            ),
            "all"
        )
        XCTAssertNil(remoteEpisode.deletedAt)
        XCTAssertNil(remoteQueue.deletedAt)
        XCTAssertEqual(remoteSetting.value, "unplayed")
    }

    func testMorningLineupProjectsFollowedOnlyAndMergesWithoutErasingLocalCatalog() async throws {
        let app = try makeApplicationContainer()
        let context = app.mainContext
        let followedA = Podcast(feedURL: "https://followed.example/a", title: "A")
        let followedB = Podcast(feedURL: "https://followed.example/b", title: "B")
        let catalog = Podcast(
            feedURL: "https://catalog.example/feed",
            title: "Catalog",
            subscriptionStateRaw: PodcastSubscriptionState.catalogOnly.rawValue
        )
        func episode(_ guid: String, podcast: Podcast) -> Episode {
            let value = Episode(
                guid: guid,
                title: guid,
                audioURL: "https://example.com/\(guid).mp3"
            )
            value.podcast = podcast
            context.insert(value)
            return value
        }
        [followedA, followedB, catalog].forEach(context.insert)
        let a = episode("a", podcast: followedA)
        let localCatalog = episode("catalog", podcast: catalog)
        let b = episode("b", podcast: followedB)
        try context.save()
        XCTAssertEqual(
            QueueLineupStore(context: context).save([a, localCatalog, b]).savedCount,
            3
        )
        let projection = try makeProjectionContainer()
        let coordinator = await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: app,
            projectionContainer: projection,
            deviceID: "phone"
        )

        try await coordinator.reconcile()

        let lineupKey = SettingsKey.morningLineup
        let cloudRows = try projection.mainContext.fetch(
            FetchDescriptor<CloudSettingProjection>(predicate: #Predicate {
                $0.key == lineupKey
            })
        )
        let phoneRow = try XCTUnwrap(cloudRows.first { $0.sourceDeviceID == "phone" })
        XCTAssertEqual(
            QueueLineupIdentityPolicy.identities(from: phoneRow.value)?.map(\.episodeGUID),
            ["a", "b"]
        )
        XCTAssertFalse(phoneRow.value.contains("catalog.example"))

        let remote = CloudSettingProjection()
        remote.key = SettingsKey.morningLineup
        remote.value = QueueLineupIdentityPolicy.encoded([
            QueueLineupIdentity(feedURL: followedB.feedURL, episodeGUID: b.guid),
            QueueLineupIdentity(feedURL: followedA.feedURL, episodeGUID: a.guid),
        ])
        remote.sourceDeviceID = "remote"
        remote.modifiedAt = .distantFuture
        projection.mainContext.insert(remote)
        try projection.mainContext.save()
        try await coordinator.reconcile()

        let localAfterRemote = try XCTUnwrap(
            AppSettingIdentity.value(for: SettingsKey.morningLineup, in: context)
        )
        XCTAssertEqual(
            QueueLineupIdentityPolicy.identities(from: localAfterRemote)?.map(\.episodeGUID),
            ["b", "catalog", "a"],
            "remote followed order replaces followed slots without erasing local catalog"
        )

        remote.value = "invalid remote lineup"
        try projection.mainContext.save()
        try await coordinator.reconcile()
        XCTAssertEqual(
            AppSettingIdentity.value(for: SettingsKey.morningLineup, in: context),
            localAfterRemote,
            "invalid remote input leaves the richer local lineup intact"
        )

        try AppSettingIdentity.setValue(
            "invalid local lineup",
            for: SettingsKey.morningLineup,
            in: context
        )
        try context.save()
        let cloudBeforeInvalidPublish = phoneRow.value
        try await coordinator.publishLocalSettingChange(
            key: SettingsKey.morningLineup,
            now: Date(timeIntervalSince1970: 300)
        )
        XCTAssertEqual(phoneRow.value, cloudBeforeInvalidPublish)

        // Promotion makes the formerly local-only identity eligible for the next
        // outbound projection without requiring any lineup rewrite.
        catalog.subscriptionStateRaw = nil
        QueueLineupStore(context: context).save([b, localCatalog, a])
        for row in try projection.mainContext.fetch(FetchDescriptor<CloudSettingProjection>())
            where row.key == SettingsKey.morningLineup {
            projection.mainContext.delete(row)
        }
        try projection.mainContext.save()
        try await coordinator.publishLocalSettingChange(
            key: SettingsKey.morningLineup,
            now: Date(timeIntervalSince1970: 400)
        )
        let promoted = try XCTUnwrap(
            try projection.mainContext.fetch(
                FetchDescriptor<CloudSettingProjection>(predicate: #Predicate {
                    $0.key == lineupKey
                })
            ).first {
                $0.sourceDeviceID == "phone"
            }
        )
        XCTAssertEqual(
            QueueLineupIdentityPolicy.identities(from: promoted.value)?.map(\.episodeGUID),
            ["b", "catalog", "a"]
        )
    }

    private func makeApplicationContainer() throws -> ModelContainer {
        let full = Schema(versionedSchema: EarshotSchemaV12.self)
        return try ModelContainer(
            for: full,
            configurations:
                ModelConfiguration(
                    "FutureMirrored",
                    schema: Schema(EarshotSchemaV12.mirroredModels),
                    isStoredInMemoryOnly: true,
                    cloudKitDatabase: .none
                ),
                ModelConfiguration(
                    "DeviceLocal",
                    schema: Schema(EarshotSchemaV12.localModels),
                    isStoredInMemoryOnly: true,
                    cloudKitDatabase: .none
                )
        )
    }

    private func makeProjectionContainer() throws -> ModelContainer {
        let schema = Schema([
            CloudPodcastProjection.self,
            CloudEpisodeStateProjection.self,
            CloudQueueItemProjection.self,
            CloudSettingProjection.self,
            CloudBookmarkProjection.self,
            CloudListeningSessionProjection.self,
            CloudFolderProjection.self,
        ])
        return try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(
                "CloudProjection",
                schema: schema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )
        )
    }

    private func makeOnDiskApplicationContainer(
        applicationURL: URL,
        localURL: URL
    ) throws -> ModelContainer {
        let full = Schema(versionedSchema: EarshotSchemaV12.self)
        return try ModelContainer(
            for: full,
            configurations:
                ModelConfiguration(
                    "FutureMirrored",
                    schema: Schema(EarshotSchemaV12.mirroredModels),
                    url: applicationURL,
                    cloudKitDatabase: .none
                ),
                ModelConfiguration(
                    "DeviceLocal",
                    schema: Schema(EarshotSchemaV12.localModels),
                    url: localURL,
                    cloudKitDatabase: .none
                )
        )
    }

    private func makeOnDiskProjectionContainer(at url: URL) throws -> ModelContainer {
        let schema = Schema([
            CloudPodcastProjection.self,
            CloudEpisodeStateProjection.self,
            CloudQueueItemProjection.self,
            CloudSettingProjection.self,
            CloudBookmarkProjection.self,
            CloudListeningSessionProjection.self,
            CloudFolderProjection.self,
        ])
        return try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(
                "CloudProjection",
                schema: schema,
                url: url,
                cloudKitDatabase: .none
            )
        )
    }

    private func makeApplicationContainerWithEpisode(position: Int) throws -> ModelContainer {
        let container = try makeApplicationContainer()
        let podcast = Podcast(feedURL: "https://example.com/feed", title: "Show")
        let episode = Episode(
            guid: "episode", title: "Episode", audioURL: "https://example.com/episode.mp3",
            positionSeconds: position
        )
        episode.podcast = podcast
        container.mainContext.insert(podcast)
        container.mainContext.insert(episode)
        try container.mainContext.save()
        return container
    }

    private func waitForProjectionPodcastCount(
        _ expectedCount: Int,
        in container: ModelContainer
    ) async throws {
        for _ in 0..<100 {
            let context = ModelContext(container)
            if try context.fetchCount(FetchDescriptor<CloudPodcastProjection>()) == expectedCount {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for \(expectedCount) projected podcasts")
    }

    private func waitForProjectedSpeed(
        _ expectedSpeed: Double,
        feedURL: String,
        in container: ModelContainer
    ) async throws {
        for _ in 0..<100 {
            let context = ModelContext(container)
            let rows = try context.fetch(FetchDescriptor<CloudPodcastProjection>())
            if rows.first(where: { $0.feedURL == feedURL })?.speedOverride == expectedSpeed {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for projected subscription update")
    }

    private func executeSQLite(at url: URL, sql: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_close(database) }
        // Core Data can release its last WAL writer just after the seed
        // container leaves scope. Let SQLite wait for that bounded lock handoff
        // instead of making the test depend on executor/autorelease timing.
        sqlite3_busy_timeout(database, 5_000)
        // Do not demand an exclusive TRUNCATE checkpoint here. SwiftData may
        // retain a read handle briefly after the fixture's seed container leaves
        // scope, especially when these async tests run back-to-back. A new SQLite
        // connection sees the committed Core Data WAL and commits this fixture
        // mutation into that same WAL, so checkpointing is unnecessary. Requiring
        // it made otherwise-correct tests fail with SQLITE_BUSY / Cocoa 512 and
        // could provoke "vnode unlinked while in use" diagnostics during cleanup.
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        guard result == SQLITE_OK else {
            let detail = database.map { String(cString: sqlite3_errmsg($0)) }
                ?? "Unknown SQLite error"
            throw NSError(
                domain: "CloudProjectionCoordinatorTests.SQLiteFixture",
                code: Int(result),
                userInfo: [NSLocalizedDescriptionKey: detail]
            )
        }
    }

    private func applicationEpisode(in container: ModelContainer) throws -> Episode? {
        try container.mainContext.fetch(FetchDescriptor<Episode>()).first
    }

    private func folderFeeds(_ json: String) throws -> Set<String> {
        let values = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]
        )
        return Set(values.compactMap { $0["feedURL"] as? String }.map(FeedURLIdentity.canonical))
    }

    private func episodeStateRow(
        device: String,
        position: Int,
        updatedAt: TimeInterval
    ) -> CloudEpisodeStateProjection {
        let row = CloudEpisodeStateProjection()
        row.feedURL = "https://example.com/feed"
        row.episodeGUID = "episode"
        row.sourceDeviceID = device
        row.positionSeconds = position
        row.positionUpdatedAt = Date(timeIntervalSince1970: updatedAt)
        row.playedUpdatedAt = Date(timeIntervalSince1970: updatedAt)
        row.modifiedAt = Date(timeIntervalSince1970: updatedAt)
        return row
    }

    private func queueEpisode(
        in app: ModelContainer,
        guid: String,
        feedURL: String = "https://example.com/feed",
        queuedAt position: Int? = nil,
        addedAt: Date = .now,
        ageLimit: Int? = nil
    ) -> Episode {
        let podcast = Podcast(feedURL: feedURL, title: "Show")
        podcast.queueAgeLimitDays = ageLimit
        let episode = Episode(
            guid: guid, title: guid, audioURL: "https://example.com/\(guid).mp3",
            status: position == nil ? .newEpisode : .inQueue
        )
        episode.podcast = podcast
        app.mainContext.insert(podcast)
        app.mainContext.insert(episode)
        if let position {
            app.mainContext.insert(QueueItem(episode: episode, position: position, addedAt: addedAt))
        }
        return episode
    }

    private func queueCoordinator(
        _ app: ModelContainer,
        _ projection: ModelContainer,
        device: String = "mac"
    ) async -> CloudProjectionCoordinator {
        await CloudProjectionCoordinator.makeForTesting(
            applicationContainer: app, projectionContainer: projection,
            center: NotificationCenter(), deviceID: device
        )
    }

    private func queueRow(
        device: String,
        guid: String,
        queued: Bool,
        position: Int,
        membershipUpdatedAt: TimeInterval? = nil,
        modifiedAt: TimeInterval
    ) -> CloudQueueItemProjection {
        let row = CloudQueueItemProjection()
        row.feedURL = "https://example.com/feed"
        row.episodeGUID = guid
        row.sourceDeviceID = device
        row.isQueued = queued
        row.position = position
        row.membershipUpdatedAt = membershipUpdatedAt.map(Date.init(timeIntervalSince1970:))
            ?? .distantPast
        row.modifiedAt = Date(timeIntervalSince1970: modifiedAt)
        return row
    }
}
