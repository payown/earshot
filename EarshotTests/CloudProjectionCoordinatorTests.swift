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
