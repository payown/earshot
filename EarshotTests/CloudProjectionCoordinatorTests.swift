import SQLite3
import SwiftData
import XCTest
@testable import Earshot

@MainActor
final class CloudProjectionCoordinatorTests: XCTestCase {
    /// Reproduces the build-204 failure shape: a cold catalog with 99 current
    /// subscriptions, 948 remote deletion tombstones left by Delete Everywhere,
    /// and one unusually large Podcast-to-Episodes relationship.
    /// This is opt-in because constructing 54,000 persisted Episodes is too
    /// expensive for every unit-test run; it is mandatory for release candidates.
    func testLargeMigratedLibraryFirstProjectionAndFolderReadStayBelowWatchdog() throws {
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

        try autoreleasepool {
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

        let coordinator = CloudProjectionCoordinator(
            applicationContainer: app,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "scale-phone"
        )
        let firstStarted = ContinuousClock.now
        try coordinator.reconcile()
        let firstSeconds = secondsSince(firstStarted)
        let secondStarted = ContinuousClock.now
        try coordinator.reconcile()
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

    func testDevelopmentSeedMarkersBracketDurableProjectionWithAllEntityCounts() throws {
        let app = try makeApplicationContainer()
        app.mainContext.insert(Podcast(feedURL: "https://example.com/feed", title: "Show"))
        try app.mainContext.save()
        let projection = try makeProjectionContainer()
        var markers: [CompactProjectionSeedMarker] = []
        let coordinator = CloudProjectionCoordinator(
            applicationContainer: app,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "phone",
            seedInstrumentationEnabled: { true },
            seedMarkerRecorder: { markers.append($0) }
        )

        try coordinator.start()

        XCTAssertEqual(markers.count, 2)
        guard case .start(let startRunID) = markers[0],
              case .complete(let completeRunID, let duration, let counts) = markers[1]
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

    func testSyncDisabledStartCreatesNoSeedMarker() throws {
        let app = try makeApplicationContainer()
        let projection = try makeProjectionContainer()
        var markers: [CompactProjectionSeedMarker] = []
        let coordinator = CloudProjectionCoordinator(
            applicationContainer: app,
            projectionContainer: projection,
            center: NotificationCenter(),
            seedInstrumentationEnabled: { false },
            seedMarkerRecorder: { markers.append($0) }
        )

        try coordinator.start()

        XCTAssertTrue(markers.isEmpty)
    }

    func testStartObservesLocalChangesAndStopFullyDetaches() async throws {
        let app = try makeApplicationContainer()
        let projection = try makeProjectionContainer()
        let center = NotificationCenter()
        let coordinator = CloudProjectionCoordinator(
            applicationContainer: app,
            projectionContainer: projection,
            center: center,
            deviceID: "phone"
        )
        try coordinator.start()
        app.mainContext.insert(Podcast(
            feedURL: "https://example.com/first",
            title: "First"
        ))
        try app.mainContext.save()
        center.post(name: .earshotSubscriptionsDidChange, object: nil)
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

    func testTargetedSubscriptionNotificationUpdatesOnlyNamedPodcast() throws {
        let app = try makeApplicationContainer()
        let projection = try makeProjectionContainer()
        let center = NotificationCenter()
        let coordinator = CloudProjectionCoordinator(
            applicationContainer: app,
            projectionContainer: projection,
            center: center,
            deviceID: "phone"
        )
        try coordinator.start()
        let first = Podcast(feedURL: "https://example.com/first", title: "First")
        let second = Podcast(feedURL: "https://example.com/second", title: "Second")
        app.mainContext.insert(first)
        app.mainContext.insert(second)
        try app.mainContext.save()
        center.post(name: .earshotSubscriptionsDidChange, object: nil)

        first.speedOverride = 1.5
        second.speedOverride = 1.75
        try app.mainContext.save()
        center.post(name: .earshotSubscriptionsDidChange, object: first.feedURL)

        let rows = try projection.mainContext.fetch(
            FetchDescriptor<CloudPodcastProjection>()
        )
        let values = Dictionary(uniqueKeysWithValues: rows.map { ($0.feedURL, $0.speedOverride) })
        XCTAssertEqual(values[first.feedURL]!, 1.5)
        XCTAssertNil(values[second.feedURL]!)
    }

    func testBurstOfRemoteImportNotificationsCoalescesAndStopsCleanly() async throws {
        let app = try makeApplicationContainer()
        let projection = try makeProjectionContainer()
        let center = NotificationCenter()
        let coordinator = CloudProjectionCoordinator(
            applicationContainer: app,
            projectionContainer: projection,
            center: center,
            deviceID: "phone"
        )
        try coordinator.start()
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
        for _ in 0..<5 { await Task.yield() }

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

    func testExistingSubscriptionsSeedOnlyCompactProjectionRows() throws {
        let app = try makeApplicationContainer()
        for index in 0..<662 {
            app.mainContext.insert(Podcast(
                feedURL: "https://example.com/\(index).xml",
                title: "Podcast \(index)"
            ))
        }
        try app.mainContext.save()
        let projection = try makeProjectionContainer()
        let coordinator = CloudProjectionCoordinator(
            applicationContainer: app,
            projectionContainer: projection
        )

        try coordinator.reconcile()

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

    func testCompletedSubscriptionBackfillIsRestartableOnDiskWithoutDuplicates() throws {
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
            let coordinator = CloudProjectionCoordinator(
                applicationContainer: app,
                projectionContainer: projection,
                center: NotificationCenter(),
                deviceID: "phone"
            )
            try coordinator.reconcile()
            XCTAssertEqual(
                try projection.mainContext.fetchCount(
                    FetchDescriptor<CloudPodcastProjection>()
                ),
                662
            )
        }

        try autoreleasepool {
            let app = try makeOnDiskApplicationContainer(
                applicationURL: applicationURL,
                localURL: localURL
            )
            let projection = try makeOnDiskProjectionContainer(at: projectionURL)
            let restarted = CloudProjectionCoordinator(
                applicationContainer: app,
                projectionContainer: projection,
                center: NotificationCenter(),
                deviceID: "phone"
            )
            try restarted.reconcile()
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

    func testPartialSubscriptionBackfillResumesOnDiskWithoutDuplicates() throws {
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

        try autoreleasepool {
            let app = try makeOnDiskApplicationContainer(
                applicationURL: applicationURL,
                localURL: localURL
            )
            let projection = try makeOnDiskProjectionContainer(at: projectionURL)
            try CloudProjectionCoordinator(
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

    func testImportedProjectionCreatesApplicationSubscription() throws {
        let app = try makeApplicationContainer()
        let projection = try makeProjectionContainer()
        let remote = CloudPodcastProjection()
        remote.feedURL = "HTTPS://EXAMPLE.COM:443/feed.xml#fragment"
        remote.title = "Remote podcast"
        remote.autoQueue = true
        projection.mainContext.insert(remote)
        try projection.mainContext.save()
        let coordinator = CloudProjectionCoordinator(
            applicationContainer: app,
            projectionContainer: projection
        )

        try coordinator.reconcile()

        let podcasts = try app.mainContext.fetch(FetchDescriptor<Podcast>())
        XCTAssertEqual(podcasts.count, 1)
        XCTAssertEqual(podcasts[0].feedURL, "https://example.com/feed.xml")
        XCTAssertEqual(podcasts[0].title, "Remote podcast")
        XCTAssertTrue(podcasts[0].autoQueue)
    }

    func testLocalDeletionPersistsTombstoneAndSurvivesCoordinatorRestart() throws {
        let source = try makeApplicationContainer()
        let podcast = Podcast(feedURL: "https://example.com/feed.xml", title: "Podcast")
        source.mainContext.insert(podcast)
        try source.mainContext.save()
        let projection = try makeProjectionContainer()
        let first = CloudProjectionCoordinator(
            applicationContainer: source,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "phone"
        )
        try first.reconcile()
        source.mainContext.delete(podcast)
        try source.mainContext.save()
        let deletedAt = Date(timeIntervalSince1970: 1_800_000_000)

        try first.publishLocalSubscriptionChanges(now: deletedAt)

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
        let restarted = CloudProjectionCoordinator(
            applicationContainer: secondDevice,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "mac"
        )
        try restarted.reconcile()

        XCTAssertEqual(
            try secondDevice.mainContext.fetchCount(FetchDescriptor<Podcast>()),
            0
        )
        XCTAssertEqual(rows[0].deletedAt, deletedAt)
    }

    func testRemoteUnfollowReleasesActivePlayerBeforeCascadeDelete() throws {
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

        try CloudProjectionCoordinator(
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
            queue: nil
        ) { note in
            let podcastID = note.userInfo?[PlayerService.willDeletePodcastIDKey]
                as? PersistentIdentifier
            MainActor.assumeIsolated {
                notifiedPodcastID = podcastID
            }
        }
        defer { center.removeObserver(token) }
        let coordinator = CloudProjectionCoordinator(
            applicationContainer: app,
            projectionContainer: projection,
            center: center,
            deviceID: "phone",
            remotePodcastDeletionDelayNanoseconds: 1_000_000
        )

        try coordinator.reconcile()

        XCTAssertEqual(notifiedPodcastID, podcastID)
        XCTAssertEqual(try app.mainContext.fetchCount(FetchDescriptor<Podcast>()), 1)
        XCTAssertEqual(try app.mainContext.fetchCount(FetchDescriptor<Episode>()), 1)

        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(try app.mainContext.fetchCount(FetchDescriptor<Podcast>()), 0)
        XCTAssertEqual(try app.mainContext.fetchCount(FetchDescriptor<Episode>()), 0)
    }

    func testReconcileRemovesOrphansLeftByRemoteUnfollowRefreshRace() throws {
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

        let coordinator = CloudProjectionCoordinator(
            applicationContainer: app,
            projectionContainer: try makeProjectionContainer(),
            center: NotificationCenter(),
            deviceID: "phone"
        )

        try coordinator.reconcile()

        XCTAssertEqual(try app.mainContext.fetchCount(FetchDescriptor<Episode>()), 0)
        XCTAssertEqual(
            try app.mainContext.fetchCount(FetchDescriptor<ListeningSession>()),
            0
        )
    }

    func testReconcileUnloadsPlayerBeforeRemovingLoadedOrphan() throws {
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

        let coordinator = CloudProjectionCoordinator(
            applicationContainer: app,
            projectionContainer: try makeProjectionContainer(),
            center: .default,
            deviceID: "phone"
        )

        try coordinator.reconcile()

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
        let coordinator = CloudProjectionCoordinator(
            applicationContainer: app,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "phone",
            remotePodcastDeletionDelayNanoseconds: 20_000_000
        )

        try coordinator.reconcile()
        tombstone.deletedAt = nil
        tombstone.modifiedAt = .now
        try projection.mainContext.save()

        try await Task.sleep(nanoseconds: 40_000_000)

        XCTAssertEqual(try app.mainContext.fetchCount(FetchDescriptor<Podcast>()), 1)
        XCTAssertEqual(try app.mainContext.fetchCount(FetchDescriptor<Episode>()), 1)
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
            queue: nil
        ) { _ in
            MainActor.assumeIsolated { notificationCount += 1 }
        }
        defer { center.removeObserver(token) }
        let coordinator = CloudProjectionCoordinator(
            applicationContainer: app,
            projectionContainer: projection,
            center: center,
            deviceID: "phone",
            remotePodcastDeletionDelayNanoseconds: 20_000_000
        )

        try coordinator.reconcile()
        try coordinator.reconcile()

        XCTAssertEqual(notificationCount, 1)
        XCTAssertEqual(try app.mainContext.fetchCount(FetchDescriptor<Podcast>()), 1)

        try await Task.sleep(nanoseconds: 40_000_000)

        XCTAssertEqual(notificationCount, 1)
        XCTAssertEqual(try app.mainContext.fetchCount(FetchDescriptor<Podcast>()), 0)
    }

    func testDuplicateCloudRowsConvergeToNewestRecord() throws {
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
        let coordinator = CloudProjectionCoordinator(
            applicationContainer: app,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "mac"
        )

        try coordinator.reconcile()

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

    func testReconciliationNeverRewindsFeedHighWaterMark() throws {
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

        let coordinator = CloudProjectionCoordinator(
            applicationContainer: app,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "phone"
        )

        try coordinator.reconcile()

        XCTAssertEqual(local.lastSeenPubDate, localMark)
        XCTAssertEqual(cloud.lastSeenPubDate, localMark)
    }

    func testReconciliationAdvancesLocalFeedHighWaterMarkFromCloud() throws {
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

        let coordinator = CloudProjectionCoordinator(
            applicationContainer: app,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "phone"
        )

        try coordinator.reconcile()

        XCTAssertEqual(local.lastSeenPubDate, cloudMark)
        XCTAssertEqual(cloud.lastSeenPubDate, cloudMark)
    }

    func testPublishingLegacyDuplicateLocalFeedURLsDoesNotTrap() throws {
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
        let coordinator = CloudProjectionCoordinator(
            applicationContainer: app,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "phone"
        )

        try coordinator.publishLocalSubscriptionChanges()

        let rows = try projection.mainContext.fetch(
            FetchDescriptor<CloudPodcastProjection>()
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].title, "First")
    }

    func testEverywhereDeleteIntentPrecedesApplicationStoreDeletion() throws {
        let app = try makeApplicationContainer()
        app.mainContext.insert(Podcast(
            feedURL: "https://example.com/feed.xml",
            title: "Podcast"
        ))
        try app.mainContext.save()
        let projection = try makeProjectionContainer()
        let coordinator = CloudProjectionCoordinator(
            applicationContainer: app,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "phone"
        )
        try coordinator.reconcile()
        let deletionDate = Date(timeIntervalSince1970: 1_800_000_001)
        let episodeRow = episodeStateRow(device: "phone", position: 90, updatedAt: 100)
        projection.mainContext.insert(episodeRow)
        try projection.mainContext.save()

        try coordinator.markAllSubscriptionsDeleted(now: deletionDate)

        let row = try XCTUnwrap(
            projection.mainContext.fetch(
                FetchDescriptor<CloudPodcastProjection>()
            ).first
        )
        XCTAssertEqual(row.deletedAt, deletionDate)
        XCTAssertEqual(episodeRow.deletedAt, deletionDate)

        let freshApplicationStore = try makeApplicationContainer()
        let restarted = CloudProjectionCoordinator(
            applicationContainer: freshApplicationStore,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "phone"
        )
        try restarted.reconcile()
        XCTAssertEqual(
            try freshApplicationStore.mainContext.fetchCount(FetchDescriptor<Podcast>()),
            0
        )
    }

    func testEverywhereDeleteIsIdempotentAndTombstonesEveryLibraryProjection() throws {
        let app = try makeApplicationContainer()
        let projection = try makeProjectionContainer()
        let coordinator = CloudProjectionCoordinator(
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

        try coordinator.markAllSubscriptionsDeleted(now: deletionDate)
        try coordinator.markAllSubscriptionsDeleted(now: Date(timeIntervalSince1970: 600))

        XCTAssertEqual(podcast.deletedAt, deletionDate)
        XCTAssertEqual(episode.deletedAt, deletionDate)
        XCTAssertEqual(queue.deletedAt, deletionDate)
        XCTAssertFalse(queue.isQueued)
        XCTAssertEqual(bookmark.deletedAt, deletionDate)
        XCTAssertEqual(session.deletedAt, deletionDate)
        XCTAssertEqual(folder.deletedAt, deletionDate)
    }

    func testEpisodeProjectionContainsOnlyMeaningfulUserState() throws {
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
        let coordinator = CloudProjectionCoordinator(
            applicationContainer: app,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "phone"
        )

        try coordinator.reconcile()

        let rows = try projection.mainContext.fetch(
            FetchDescriptor<CloudEpisodeStateProjection>()
        )
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.map(\.episodeGUID)), ["episode-42", "episode-73"])
    }

    func testStaleProgressCannotMovePlaybackBackward() throws {
        let app = try makeApplicationContainerWithEpisode(position: 200)
        let projection = try makeProjectionContainer()
        let phone = episodeStateRow(device: "phone", position: 200, updatedAt: 200)
        let staleMac = episodeStateRow(device: "mac", position: 100, updatedAt: 100)
        projection.mainContext.insert(phone)
        projection.mainContext.insert(staleMac)
        try projection.mainContext.save()
        let coordinator = CloudProjectionCoordinator(
            applicationContainer: app,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "phone"
        )

        try coordinator.reconcile()

        XCTAssertEqual(try XCTUnwrap(applicationEpisode(in: app)).positionSeconds, 200)
    }

    func testExplicitRewindOverridesOlderProgressThenLaterProgressAdvances() throws {
        let app = try makeApplicationContainerWithEpisode(position: 200)
        let projection = try makeProjectionContainer()
        let stale = episodeStateRow(device: "phone", position: 200, updatedAt: 100)
        let rewind = episodeStateRow(device: "mac", position: 50, updatedAt: 200)
        rewind.positionResetAt = Date(timeIntervalSince1970: 200)
        projection.mainContext.insert(stale)
        projection.mainContext.insert(rewind)
        try projection.mainContext.save()
        let coordinator = CloudProjectionCoordinator(
            applicationContainer: app,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "phone"
        )

        try coordinator.reconcile()
        XCTAssertEqual(try XCTUnwrap(applicationEpisode(in: app)).positionSeconds, 50)

        rewind.positionSeconds = 80
        rewind.positionUpdatedAt = Date(timeIntervalSince1970: 300)
        rewind.modifiedAt = Date(timeIntervalSince1970: 300)
        try projection.mainContext.save()
        try coordinator.reconcile()
        XCTAssertEqual(try XCTUnwrap(applicationEpisode(in: app)).positionSeconds, 80)
    }

    func testStaleUnplayedDeviceCannotUndoNewerPlayedStateWithoutExplicitAction() throws {
        let app = try makeApplicationContainerWithEpisode(position: 100)
        let projection = try makeProjectionContainer()
        let played = episodeStateRow(device: "phone", position: 0, updatedAt: 200)
        played.isPlayed = true
        projection.mainContext.insert(played)
        try projection.mainContext.save()
        let coordinator = CloudProjectionCoordinator(
            applicationContainer: app,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "mac"
        )

        try coordinator.reconcile()

        XCTAssertTrue(try XCTUnwrap(applicationEpisode(in: app)).isPlayed)
    }

    func testExplicitMarkUnplayedCanOverrideNewerPlayedState() throws {
        let app = try makeApplicationContainerWithEpisode(position: 100)
        let projection = try makeProjectionContainer()
        let played = episodeStateRow(device: "phone", position: 0, updatedAt: 200)
        played.isPlayed = true
        projection.mainContext.insert(played)
        try projection.mainContext.save()
        let coordinator = CloudProjectionCoordinator(
            applicationContainer: app,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "mac"
        )
        try coordinator.reconcile()
        let episode = try XCTUnwrap(applicationEpisode(in: app))
        episode.isPlayed = false
        try app.mainContext.save()
        let snapshot = try XCTUnwrap(EpisodeUserStateSnapshot(
            episode: episode,
            playedChangedExplicitly: true
        ))

        try coordinator.publishLocalEpisodeStateChanges(
            snapshots: [snapshot],
            now: Date(timeIntervalSince1970: 300)
        )
        try coordinator.reconcile()

        XCTAssertFalse(episode.isPlayed)
    }

    func testLivePositionSnapshotPublishesWithoutSavingApplicationEpisode() throws {
        let app = try makeApplicationContainerWithEpisode(position: 10)
        let projection = try makeProjectionContainer()
        let coordinator = CloudProjectionCoordinator(
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

        try coordinator.publishLocalEpisodeStateChanges(
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

    func testQueueProjectionConvergesOrderAndRemovalAcrossDevices() throws {
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
        let phoneCoordinator = CloudProjectionCoordinator(
            applicationContainer: phone,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "phone"
        )
        try phoneCoordinator.reconcile()

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
        let macCoordinator = CloudProjectionCoordinator(
            applicationContainer: mac,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "mac"
        )

        try macCoordinator.reconcile()

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
        try macCoordinator.reconcile()

        XCTAssertEqual(
            try mac.mainContext.fetch(FetchDescriptor<QueueItem>())
                .compactMap { $0.episode?.guid },
            ["a"]
        )
    }

    func testUnprojectableQueueItemIsPreserved() throws {
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
        let coordinator = CloudProjectionCoordinator(
            applicationContainer: app,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "mac"
        )

        try coordinator.publishLocalQueueChanges()

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

    func testRemoteQueueMaterializesEpisodeMissingFromLocalCatalog() throws {
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
        let coordinator = CloudProjectionCoordinator(
            applicationContainer: app,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "mac"
        )

        try coordinator.reconcile()

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
    }

    func testSimultaneousQueueAddReorderAndRemoveConvergesInEitherArrivalOrder() throws {
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
            let coordinator = CloudProjectionCoordinator(
                applicationContainer: app,
                projectionContainer: projection,
                center: NotificationCenter(),
                deviceID: "receiver"
            )

            try coordinator.reconcile()

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

    func testNewestMirroredSettingWinsWithoutCopyingLocalSettings() throws {
        let phone = try makeApplicationContainer()
        let phoneSettings = AppSettingsStore(context: phone.mainContext)
        phoneSettings.setDouble(1.5, for: SettingsKey.globalSpeed)
        phoneSettings.setRawValue("phone-only", for: SettingsKey.lastPlayingEpisodeID)
        let projection = try makeProjectionContainer()
        let phoneCoordinator = CloudProjectionCoordinator(
            applicationContainer: phone,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "phone"
        )
        try phoneCoordinator.reconcile()

        let mac = try makeApplicationContainer()
        let macCoordinator = CloudProjectionCoordinator(
            applicationContainer: mac,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "mac"
        )
        try macCoordinator.reconcile()
        let macSettings = AppSettingsStore(context: mac.mainContext)
        XCTAssertEqual(macSettings.double(SettingsKey.globalSpeed, default: 1), 1.5)
        XCTAssertNil(macSettings.rawValue(SettingsKey.lastPlayingEpisodeID))

        macSettings.setDouble(2, for: SettingsKey.globalSpeed)
        try macCoordinator.publishLocalSettingChange(
            key: SettingsKey.globalSpeed,
            now: .distantFuture
        )
        try phoneCoordinator.reconcile()

        XCTAssertEqual(phoneSettings.double(SettingsKey.globalSpeed, default: 1), 2)
    }

    func testCoreLibraryRoundTripFromPhoneToMacAndBack() throws {
        let projection = try makeProjectionContainer()
        let phone = try makeApplicationContainerWithEpisode(position: 120)
        let phoneEpisode = try XCTUnwrap(applicationEpisode(in: phone))
        phone.mainContext.insert(QueueItem(episode: phoneEpisode, position: 0))
        let phoneSettings = AppSettingsStore(context: phone.mainContext)
        phoneSettings.setDouble(1.5, for: SettingsKey.globalSpeed)
        try phone.mainContext.save()
        let phoneCoordinator = CloudProjectionCoordinator(
            applicationContainer: phone,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "phone"
        )
        try phoneCoordinator.reconcile()

        let mac = try makeApplicationContainerWithEpisode(position: 0)
        let macCoordinator = CloudProjectionCoordinator(
            applicationContainer: mac,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "mac"
        )
        try macCoordinator.reconcile()
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
        for item in try mac.mainContext.fetch(FetchDescriptor<QueueItem>()) {
            mac.mainContext.delete(item)
        }
        let macSettings = AppSettingsStore(context: mac.mainContext)
        macSettings.setDouble(2, for: SettingsKey.globalSpeed)
        try mac.mainContext.save()
        let later = Date.distantFuture
        try macCoordinator.publishLocalSubscriptionChanges(now: later)
        try macCoordinator.publishLocalEpisodeStateChanges(
            snapshots: [try XCTUnwrap(EpisodeUserStateSnapshot(episode: macEpisode))],
            now: later
        )
        try macCoordinator.publishLocalQueueChanges(now: later)
        try macCoordinator.publishLocalSettingChange(
            key: SettingsKey.globalSpeed,
            now: later
        )

        try phoneCoordinator.reconcile()
        XCTAssertEqual(
            try phone.mainContext.fetch(FetchDescriptor<Podcast>()).first?.title,
            "Renamed on Mac"
        )
        XCTAssertEqual(phoneEpisode.positionSeconds, 240)
        XCTAssertTrue(try phone.mainContext.fetch(FetchDescriptor<QueueItem>()).isEmpty)
        XCTAssertEqual(phoneSettings.double(SettingsKey.globalSpeed, default: 1), 2)
    }

    func testFreshDeviceCannotReduceGrandfatheredPodcastAllowance() throws {
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
        let coordinator = CloudProjectionCoordinator(
            applicationContainer: app,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "test"
        )

        try coordinator.reconcile()

        XCTAssertEqual(
            AppSettingsStore(context: app.mainContext).grandfatheredPodcastCount(),
            662
        )
    }

    func testBookmarksArriveAfterCatalogAndDeletionPropagates() throws {
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
        let phoneCoordinator = CloudProjectionCoordinator(
            applicationContainer: phone,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "phone"
        )
        try phoneCoordinator.reconcile()

        let mac = try makeApplicationContainer()
        let macCoordinator = CloudProjectionCoordinator(
            applicationContainer: mac,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "mac"
        )
        try macCoordinator.reconcile()
        XCTAssertTrue(try mac.mainContext.fetch(FetchDescriptor<Bookmark>()).isEmpty)

        let macPodcast = Podcast(feedURL: "https://example.com/feed", title: "Show")
        let macEpisode = Episode(guid: "episode", title: "Episode", audioURL: "https://example.com/audio")
        macEpisode.podcast = macPodcast
        mac.mainContext.insert(macPodcast)
        mac.mainContext.insert(macEpisode)
        try mac.mainContext.save()
        try macCoordinator.reconcile()
        XCTAssertEqual(try mac.mainContext.fetch(FetchDescriptor<Bookmark>()).first?.note, "Remember")

        phone.mainContext.delete(bookmark)
        try phone.mainContext.save()
        try phoneCoordinator.publishLocalBookmarkChanges(now: Date(timeIntervalSince1970: 200))
        try macCoordinator.reconcile()
        XCTAssertTrue(try mac.mainContext.fetch(FetchDescriptor<Bookmark>()).isEmpty)
    }

    func testListeningHistorySyncsWithoutRequiringEpisodeCatalog() throws {
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
        let phoneCoordinator = CloudProjectionCoordinator(
            applicationContainer: phone,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "phone"
        )
        try phoneCoordinator.reconcile()

        let mac = try makeApplicationContainer()
        let macCoordinator = CloudProjectionCoordinator(
            applicationContainer: mac,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "mac"
        )
        try macCoordinator.reconcile()
        let imported = try XCTUnwrap(
            mac.mainContext.fetch(FetchDescriptor<ListeningSession>()).first
        )
        XCTAssertEqual(imported.durationSeconds, 90)
        XCTAssertEqual(imported.speed, 1.5)
        XCTAssertEqual(imported.podcast?.feedURL, "https://example.com/feed")

        phone.mainContext.delete(session)
        try phone.mainContext.save()
        try phoneCoordinator.publishLocalListeningHistoryChanges(
            now: Date(timeIntervalSince1970: 200)
        )
        try macCoordinator.reconcile()
        XCTAssertTrue(try mac.mainContext.fetch(FetchDescriptor<ListeningSession>()).isEmpty)
    }

    /// Reproduces the two build-205 TestFlight crashes: an old history row can
    /// retain a Podcast foreign key after its destination row has disappeared.
    /// SwiftData then supplies a future fault whose first stored-property read
    /// traps instead of throwing. Reconciliation must discard only that
    /// irrecoverable history row and remain idempotent across later launches.
    func testDanglingListeningSessionPodcastIsRepairedWithoutFaulting() throws {
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
            try autoreleasepool {
                let app = try StoreMigration.openOrMigrate(at: applicationURL)
                let projection = try makeOnDiskProjectionContainer(at: projectionURL)
                try CloudProjectionCoordinator(
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
    func testDanglingListeningSessionEpisodePreservesPodcastHistory() throws {
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
            try autoreleasepool {
                let app = try StoreMigration.openOrMigrate(at: applicationURL)
                let projection = try makeOnDiskProjectionContainer(at: projectionURL)
                try CloudProjectionCoordinator(
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

    func testPartialListeningHistoryBackfillResumesOnDiskWithoutDuplicates() throws {
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
            try autoreleasepool {
                let app = try makeOnDiskApplicationContainer(
                    applicationURL: applicationURL,
                    localURL: localURL
                )
                let projection = try makeOnDiskProjectionContainer(at: projectionURL)
                try CloudProjectionCoordinator(
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

    func testListeningHistoryBackfillPreservesTombstoneAcrossRestart() throws {
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
            try CloudProjectionCoordinator(
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

    func testNestedFoldersAndMembershipsConvergeWithoutCycles() throws {
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
        let phoneCoordinator = CloudProjectionCoordinator(
            applicationContainer: phone,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "phone"
        )
        try phoneCoordinator.reconcile()

        let mac = try makeApplicationContainer()
        let macPodcast = Podcast(feedURL: "https://example.com/feed", title: "Show")
        let macEpisode = Episode(guid: "episode", title: "Episode", audioURL: "https://example.com/audio")
        macEpisode.podcast = macPodcast
        mac.mainContext.insert(macPodcast)
        mac.mainContext.insert(macEpisode)
        try mac.mainContext.save()
        let macCoordinator = CloudProjectionCoordinator(
            applicationContainer: mac,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "mac"
        )
        try macCoordinator.reconcile()

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
        try phoneCoordinator.publishLocalFolderChanges(now: Date(timeIntervalSince1970: 100))
        try macCoordinator.reconcile()

        let remainingFolders = try mac.mainContext.fetch(FetchDescriptor<PodcastFolder>())
        XCTAssertEqual(remainingFolders.map(\.name), ["Parent"])
        XCTAssertTrue(try mac.mainContext.fetch(FetchDescriptor<FolderMembership>()).isEmpty)
        XCTAssertTrue(
            try mac.mainContext.fetch(FetchDescriptor<EpisodeFolderMembership>()).isEmpty
        )
    }

    func testRemoteFolderCycleRepairsPersistAndNotifyOnce() throws {
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
            queue: nil
        ) { _ in
            MainActor.assumeIsolated { repairNotices += 1 }
        }
        defer { center.removeObserver(token) }

        try CloudProjectionCoordinator(
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

    private func makeApplicationContainer() throws -> ModelContainer {
        let full = Schema(versionedSchema: EarshotSchemaV10.self)
        return try ModelContainer(
            for: full,
            configurations:
                ModelConfiguration(
                    "FutureMirrored",
                    schema: Schema(EarshotSchemaV10.mirroredModels),
                    isStoredInMemoryOnly: true,
                    cloudKitDatabase: .none
                ),
                ModelConfiguration(
                    "DeviceLocal",
                    schema: Schema(EarshotSchemaV10.localModels),
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
        let full = Schema(versionedSchema: EarshotSchemaV10.self)
        return try ModelContainer(
            for: full,
            configurations:
                ModelConfiguration(
                    "FutureMirrored",
                    schema: Schema(EarshotSchemaV10.mirroredModels),
                    url: applicationURL,
                    cloudKitDatabase: .none
                ),
                ModelConfiguration(
                    "DeviceLocal",
                    schema: Schema(EarshotSchemaV10.localModels),
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

    private func executeSQLite(at url: URL, sql: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil)
                == SQLITE_OK,
              sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private func applicationEpisode(in container: ModelContainer) throws -> Episode? {
        try container.mainContext.fetch(FetchDescriptor<Episode>()).first
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

    private func queueRow(
        device: String,
        guid: String,
        queued: Bool,
        position: Int,
        modifiedAt: TimeInterval
    ) -> CloudQueueItemProjection {
        let row = CloudQueueItemProjection()
        row.feedURL = "https://example.com/feed"
        row.episodeGUID = guid
        row.sourceDeviceID = device
        row.isQueued = queued
        row.position = position
        row.modifiedAt = Date(timeIntervalSince1970: modifiedAt)
        return row
    }
}
