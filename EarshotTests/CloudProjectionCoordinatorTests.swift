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
            projection.schema.entities.map(\.name),
            ["CloudPodcastProjection"]
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

        try coordinator.markAllSubscriptionsDeleted(now: deletionDate)

        let row = try XCTUnwrap(
            projection.mainContext.fetch(
                FetchDescriptor<CloudPodcastProjection>()
            ).first
        )
        XCTAssertEqual(row.deletedAt, deletionDate)

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
        let schema = Schema([CloudPodcastProjection.self])
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
}
