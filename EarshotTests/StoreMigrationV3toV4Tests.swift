import XCTest
import SwiftData
@testable import Earshot

/// Exercises the V3→V4 SwiftData migration against a real on-disk store, the way
/// a tester's device upgrade actually runs it (issue #456,
/// `.claude/rules/database-migrations.md` rule 2). A fresh `onCreate` proves
/// nothing about migrations, so this builds a store at the *frozen V3 schema*
/// with realistic data — including a Podcast that predates the new
/// `introSkipSeconds` attribute — then opens it through the production path
/// (`StoreMigration.openOrMigrate`, which runs `EarshotMigrationPlan`) and
/// asserts the upgrade completes without aborting, preserves all data, and reads
/// back `introSkipSeconds` as nil for every pre-existing row.
@MainActor
final class StoreMigrationV3toV4Tests: XCTestCase {
    nonisolated(unsafe) private var dir: URL!
    nonisolated(unsafe) private var storeURL: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("migration-v3v4-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storeURL = dir.appendingPathComponent("default.store")
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private let pubA = Date(timeIntervalSince1970: 1_600_000_000)
    private let pubB = Date(timeIntervalSince1970: 1_600_100_000)

    /// Writes a store at the frozen V3 schema with two podcasts (one with a
    /// per-podcast `speedOverride` set, matching real aged data), episodes (one
    /// with NULL optional fields, one played), a queue item, and a bookmark.
    /// `EarshotSchemaV3.Podcast` has no `introSkipSeconds` field at all — it did
    /// not exist yet at V3.
    private func seedV3Store() throws {
        try autoreleasepool {
            let schema = Schema(versionedSchema: EarshotSchemaV3.self)
            let v3 = try ModelContainer(
                for: schema,
                configurations: ModelConfiguration(schema: schema, url: storeURL)
            )
            let ctx = v3.mainContext

            let p1 = EarshotSchemaV3.Podcast(
                feedURL: "https://ex.com/one.xml",
                title: "Show One",
                author: "Author One",
                notificationEnabled: true,
                speedOverride: 1.5
            )
            ctx.insert(p1)

            let p2 = EarshotSchemaV3.Podcast(
                feedURL: "https://ex.com/two.xml",
                title: "Show Two",
                notificationEnabled: false
            )
            ctx.insert(p2)

            let epA = EarshotSchemaV3.Episode(
                guid: "a",
                title: "Ep A",
                audioURL: "https://ex.com/a.mp3",
                episodeDescription: "desc",
                durationSeconds: 1800,
                pubDate: pubA,
                status: .played,
                positionSeconds: 1800,
                playedAt: pubA,
                createdAt: pubA
            )
            epA.podcast = p1
            ctx.insert(epA)

            let epB = EarshotSchemaV3.Episode(
                guid: "b",
                title: "Ep B",
                audioURL: "https://ex.com/b.mp3",
                pubDate: pubB,
                status: .inQueue,
                createdAt: pubB
            )
            epB.podcast = p1
            ctx.insert(epB)

            let q = EarshotSchemaV3.QueueItem(episode: epB, position: 0)
            ctx.insert(q)

            let bm = EarshotSchemaV3.Bookmark(episode: epA, positionSeconds: 120, note: "good bit")
            ctx.insert(bm)

            try ctx.save()
        }
    }

    func testV3StoreMigratesToV4PreservingData() throws {
        try seedV3Store()

        // Migrate via the production path (runs EarshotMigrationPlan, V3->V4
        // lightweight). This must NOT abort/throw on the new-attribute path.
        let v4 = try StoreMigration.openOrMigrate(at: storeURL)
        let ctx = v4.mainContext

        let podcasts = try ctx.fetch(
            FetchDescriptor<Podcast>(sortBy: [SortDescriptor(\.feedURL)])
        )
        XCTAssertEqual(podcasts.count, 2)
        XCTAssertEqual(podcasts[0].title, "Show One")
        XCTAssertEqual(podcasts[0].speedOverride, 1.5, "pre-existing override survives")

        // The new attribute reads back nil for every row that predates it —
        // never a crash, never a spurious default skip.
        XCTAssertNil(podcasts[0].introSkipSeconds, "new attribute defaults to nil on migrated rows")
        XCTAssertNil(podcasts[1].introSkipSeconds)

        // Episodes and their relationships survive.
        let episodes = try ctx.fetch(
            FetchDescriptor<Episode>(sortBy: [SortDescriptor(\.guid)])
        )
        XCTAssertEqual(episodes.count, 2)
        XCTAssertTrue(episodes[0].isPlayed, "Ep A was played in V3")
        XCTAssertEqual(episodes[0].podcast?.title, "Show One")
        XCTAssertNil(episodes[1].durationSeconds, "NULL optional preserved")

        XCTAssertEqual(try ctx.fetch(FetchDescriptor<QueueItem>()).count, 1)
        let bookmarks = try ctx.fetch(FetchDescriptor<Bookmark>())
        XCTAssertEqual(bookmarks.count, 1)
        XCTAssertEqual(bookmarks.first?.note, "good bit")

        // The migrated store is writable on the new attribute going forward.
        podcasts[0].introSkipSeconds = 30
        try ctx.save()
        XCTAssertEqual(podcasts[0].introSkipSeconds, 30)
    }

    /// After migrating, the store must reopen cleanly as V4 (no second
    /// migration, data still present).
    func testMigratedStoreReopensAsV4() throws {
        try seedV3Store()

        try autoreleasepool {
            _ = try StoreMigration.openOrMigrate(at: storeURL)
        }

        let reopened = try StoreMigration.openOrMigrate(at: storeURL)
        let count = try reopened.mainContext.fetch(FetchDescriptor<Episode>()).count
        XCTAssertEqual(count, 2, "data should persist across reopen")
    }
}
