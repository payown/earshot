import XCTest
import SwiftData
@testable import Earshot

/// Exercises the manual V1→V2 SwiftData migration against a real on-disk store,
/// the way a tester's device upgrade actually runs it (issue #355). A fresh
/// `onCreate` proves nothing about migrations, so this builds a store at the
/// *previous* schema with realistic data and asserts the upgrade preserves it.
@MainActor
final class StoreMigrationTests: XCTestCase {
    // nonisolated(unsafe): XCTest drives setUp -> test -> tearDown serially on a
    // single thread, but the override points are nonisolated, so the @MainActor
    // class isolation can't apply. Safe here; no concurrent access.
    private nonisolated(unsafe) var dir: URL!
    private nonisolated(unsafe) var storeURL: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storeURL = dir.appendingPathComponent("default.store")
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    /// Writes a store at the original (V1) schema with two episodes.
    private func seedV1Store(pub1: Date, pub2: Date) throws {
        try autoreleasepool {
            let schemaV1 = Schema(versionedSchema: EarshotSchemaV1.self)
            let v1 = try ModelContainer(
                for: schemaV1,
                configurations: ModelConfiguration(schema: schemaV1, url: storeURL)
            )
            let ctx = v1.mainContext
            let pod = EarshotSchemaV1.Podcast(feedURL: "https://ex.com/f.xml", title: "Show")
            ctx.insert(pod)
            let e1 = EarshotSchemaV1.Episode(
                guid: "g1", title: "Ep1", audioURL: "https://ex.com/1.mp3",
                pubDate: pub1, isPlayed: true
            )
            e1.podcast = pod
            ctx.insert(e1)
            let e2 = EarshotSchemaV1.Episode(
                guid: "g2", title: "Ep2", audioURL: "https://ex.com/2.mp3",
                pubDate: pub2, isPlayed: false
            )
            e2.podcast = pod
            ctx.insert(e2)
            try ctx.save()
        }
    }

    func testV1StoreMigratesToV2PreservingData() throws {
        let pub1 = Date(timeIntervalSince1970: 1_600_000_000)
        let pub2 = Date(timeIntervalSince1970: 1_600_100_000)
        try seedV1Store(pub1: pub1, pub2: pub2)

        // Migrate via the production path.
        let v2 = try StoreMigration.openOrMigrate(at: storeURL)
        let ctx = v2.mainContext

        let podcasts = try ctx.fetch(FetchDescriptor<Podcast>())
        XCTAssertEqual(podcasts.count, 1, "podcast should survive migration")
        XCTAssertEqual(podcasts.first?.title, "Show")

        let episodes = try ctx.fetch(
            FetchDescriptor<Episode>(sortBy: [SortDescriptor(sendableKeyPath(\Episode.guid))])
        )
        XCTAssertEqual(episodes.count, 2, "both episodes should survive migration")

        // New `createdAt` backfilled from pubDate during migration.
        XCTAssertEqual(episodes[0].createdAt, pub1)
        XCTAssertEqual(episodes[1].createdAt, pub2)

        // Old `isPlayed` Bool mapped into the new `status` enum.
        XCTAssertTrue(episodes[0].isPlayed, "g1 was played in V1")
        XCTAssertFalse(episodes[1].isPlayed, "g2 was unplayed in V1")
        XCTAssertEqual(episodes[0].status, .played)
        XCTAssertEqual(episodes[1].status, .newEpisode)

        // Relationship preserved.
        XCTAssertEqual(episodes[0].podcast?.title, "Show")
    }

    /// After migrating, the store must reopen cleanly as V2 on the next launch
    /// (no second migration, data still present).
    func testMigratedStoreReopensAsV2() throws {
        let pub = Date(timeIntervalSince1970: 1_600_000_000)
        try seedV1Store(pub1: pub, pub2: pub.addingTimeInterval(100))

        try autoreleasepool {
            _ = try StoreMigration.openOrMigrate(at: storeURL)
        }

        // Second open should take the fast (already-V2) path and keep the data.
        let reopened = try StoreMigration.openOrMigrate(at: storeURL)
        let count = try reopened.mainContext.fetch(FetchDescriptor<Episode>()).count
        XCTAssertEqual(count, 2, "data should persist across reopen")
    }
}
