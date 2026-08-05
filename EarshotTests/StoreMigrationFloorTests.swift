import CoreData
import SwiftData
import XCTest
@testable import Earshot

/// Build 157 was Earshot's first public App Store build and shipped schema V6.
/// These fixtures prove that earlier TestFlight-only stores are rejected without
/// mutation and reach the explicit OPML recovery state instead of entering a
/// partial migration route.
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

    func testV5StoreSurfacesUnsupportedRecoveryWithoutMutation() throws {
        try seed(EarshotSchemaV5.self) { context in
            context.insert(EarshotSchemaV5.Podcast(
                feedURL: "https://v5.example/feed", title: "V5 TestFlight Library"
            ))
        }
        try assertUnsupportedStore(majorVersion: 5)
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
            return XCTFail("a pre-V6 store must return recovery without a container")
        }
        XCTAssertEqual(recovery, .storePredatesSupportedSchema)
        XCTAssertEqual(try storedMajorVersion(), majorVersion)
        XCTAssertEqual(
            try Data(contentsOf: storeURL), before,
            "rejecting a pre-V6 store must not rewrite the user's only copy"
        )
    }

    private func storedMajorVersion() throws -> Int? {
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            type: .sqlite, at: storeURL
        )
        let identifier = (metadata[NSStoreModelVersionIdentifiersKey] as? [String])?.first
        return identifier.flatMap { Int($0.split(separator: ".").first ?? "") }
    }
}
