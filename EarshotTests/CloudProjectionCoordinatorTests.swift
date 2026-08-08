import SwiftData
import XCTest
@testable import Earshot

@MainActor
final class CloudProjectionCoordinatorTests: XCTestCase {
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
            ]
        )
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
}
