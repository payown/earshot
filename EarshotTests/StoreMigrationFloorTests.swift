import CoreData
import SwiftData
import XCTest
@testable import Earshot

/// Public App Store build 155 shipped schema V5. These fixtures prove that the
/// earlier TestFlight-only schemas are rejected without mutating the source,
/// while the production V5 floor takes the supported migration route.
@MainActor
final class StoreMigrationFloorTests: XCTestCase {
    nonisolated(unsafe) private var directory: URL!
    nonisolated(unsafe) private var storeURL: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appending(
            path: "migration-floor-\(UUID())", directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        storeURL = directory.appending(path: "default.store")
    }

    override func tearDownWithError() throws {
        StoreMigration.injectedFailurePoint = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testV1StoreSurfacesUnsupportedRecoveryWithoutMutation() throws {
        try seed(EarshotSchemaV1.self) { context in
            context.insert(EarshotSchemaV1.Podcast(
                feedURL: "https://v1.example/feed", title: "V1 TestFlight Library"
            ))
        }
        try assertUnsupportedStore(majorVersion: 1)
    }

    func testV2StoreSurfacesUnsupportedRecoveryWithoutMutation() throws {
        try seed(EarshotSchemaV2.self) { context in
            context.insert(EarshotSchemaV2.Podcast(
                feedURL: "https://v2.example/feed", title: "V2 TestFlight Library"
            ))
        }
        try assertUnsupportedStore(majorVersion: 2)
    }

    func testV3StoreSurfacesUnsupportedRecoveryWithoutMutation() throws {
        try seed(EarshotSchemaV3.self) { context in
            context.insert(EarshotSchemaV3.Podcast(
                feedURL: "https://v3.example/feed", title: "V3 TestFlight Library"
            ))
        }
        try assertUnsupportedStore(majorVersion: 3)
    }

    func testV4StoreSurfacesUnsupportedRecoveryWithoutMutation() throws {
        try seed(EarshotSchemaV4.self) { context in
            context.insert(EarshotSchemaV4.Podcast(
                feedURL: "https://v4.example/feed", title: "V4 TestFlight Library"
            ))
        }
        try assertUnsupportedStore(majorVersion: 4)
    }

    func testV5ProductionStoreMigratesAndSavesAfterReopen() throws {
        try seed(EarshotSchemaV5.self) { context in
            let podcast = EarshotSchemaV5.Podcast(
                feedURL: "https://v5.example/feed", title: "V5 App Store Library"
            )
            let episode = EarshotSchemaV5.Episode(
                guid: "v5-production-episode", title: "Before migration",
                audioURL: "https://v5.example/episode.mp3", positionSeconds: 83
            )
            episode.podcast = podcast
            let folder = EarshotSchemaV5.PodcastFolder(
                name: "Production folder", sortOrder: 2
            )
            let membership = EarshotSchemaV5.FolderMembership(
                folder: folder, podcast: podcast, sortOrder: 3
            )
            context.insert(podcast)
            context.insert(episode)
            context.insert(folder)
            context.insert(membership)
            context.insert(EarshotSchemaV5.Bookmark(
                episode: episode, positionSeconds: 41, note: "Production bookmark"
            ))
        }

        let load = ModelContainerFactory.load(at: storeURL)
        guard case .ready(let migrated) = load else {
            return XCTFail("the production V5 floor must migrate to V10")
        }
        XCTAssertEqual(try storedMajorVersion(), 10)
        var episode = FetchDescriptor<Episode>(
            predicate: #Predicate { $0.guid == "v5-production-episode" }
        )
        episode.fetchLimit = 1
        let migratedEpisode = try XCTUnwrap(
            try migrated.mainContext.fetch(episode).first
        )
        XCTAssertEqual(migratedEpisode.positionSeconds, 83)
        let folder = try XCTUnwrap(
            try migrated.mainContext.fetch(FetchDescriptor<PodcastFolder>()).first
        )
        XCTAssertEqual(folder.name, "Production folder")
        XCTAssertNil(folder.parent)
        XCTAssertEqual(folder.memberships?.first?.podcast?.feedURL, "https://v5.example/feed")
        XCTAssertEqual(
            try migrated.mainContext.fetch(FetchDescriptor<Bookmark>()).first?.note,
            "Production bookmark"
        )
        migratedEpisode.title = "Saved after V5 migration"
        try migrated.mainContext.save()

        let reopened = try StoreMigration.openOrMigrate(at: storeURL)
        XCTAssertEqual(
            try reopened.mainContext.fetch(episode).first?.title,
            "Saved after V5 migration"
        )
    }

    func testV5ProductionStoreResumesAfterValidatedLocalSplit() throws {
        try seed(EarshotSchemaV5.self) { context in
            let podcast = EarshotSchemaV5.Podcast(
                feedURL: "https://v5.example/resume", title: "Resume V5"
            )
            let episode = EarshotSchemaV5.Episode(
                guid: "resume-v5", title: "Resume source",
                audioURL: "https://v5.example/resume.mp3", positionSeconds: 29
            )
            episode.podcast = podcast
            context.insert(podcast)
            context.insert(episode)
        }
        StoreMigration.injectedFailurePoint = .afterSplitMarker

        XCTAssertThrowsError(try StoreMigration.openOrMigrate(at: storeURL)) { error in
            XCTAssertEqual(
                error as? StoreMigration.InjectedMigrationFailure,
                .init(point: .afterSplitMarker)
            )
        }
        XCTAssertEqual(try storedMajorVersion(), 5)
        XCTAssertEqual(
            try storedMajorVersion(at: StoreMigration.localStoreURL(for: storeURL)), 10
        )

        StoreMigration.injectedFailurePoint = nil
        let resumed = try StoreMigration.openOrMigrate(at: storeURL)
        XCTAssertEqual(try storedMajorVersion(), 10)
        var descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate { $0.guid == "resume-v5" }
        )
        descriptor.fetchLimit = 1
        let episode = try XCTUnwrap(try resumed.mainContext.fetch(descriptor).first)
        XCTAssertEqual(episode.positionSeconds, 29)
        episode.title = "Saved after V5 resume"
        try resumed.mainContext.save()

        let reopened = try StoreMigration.openOrMigrate(at: storeURL)
        XCTAssertEqual(
            try reopened.mainContext.fetch(descriptor).first?.title,
            "Saved after V5 resume"
        )
    }

    private func seed(
        _ version: any VersionedSchema.Type,
        insert: (ModelContext) -> Void
    ) throws {
        let schema = Schema(versionedSchema: version)
        try autoreleasepool {
            let container = try ModelContainer(
                for: schema,
                configurations: ModelConfiguration(schema: schema, url: storeURL)
            )
            insert(container.mainContext)
            try container.mainContext.save()
        }
    }

    private func assertUnsupportedStore(majorVersion: Int) throws {
        XCTAssertEqual(try storedMajorVersion(), majorVersion)
        let before = try Data(contentsOf: storeURL)

        let load = ModelContainerFactory.load(at: storeURL)

        guard case .recovery(let recovery) = load else {
            return XCTFail("a pre-V5 store must return recovery without a container")
        }
        XCTAssertTrue(recovery.isUnsupportedSchema)
        XCTAssertNotNil(
            recovery.recoveryBackup,
            "unsupported recovery must carry its verified snapshot into the first screen"
        )
        XCTAssertEqual(try storedMajorVersion(), majorVersion)
        XCTAssertEqual(
            try Data(contentsOf: storeURL), before,
            "rejecting a pre-V5 store must not rewrite the user's only copy"
        )
    }

    private func storedMajorVersion() throws -> Int? {
        try storedMajorVersion(at: storeURL)
    }

    private func storedMajorVersion(at url: URL) throws -> Int? {
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            type: .sqlite, at: url
        )
        let identifier = (metadata[NSStoreModelVersionIdentifiersKey] as? [String])?.first
        return identifier.flatMap { Int($0.split(separator: ".").first ?? "") }
    }
}
