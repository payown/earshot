import XCTest
import SwiftData
@testable import Earshot

/// Exercises the V2→V3 SwiftData migration against a real on-disk store, the way
/// a tester's device upgrade actually runs it (issue #425,
/// `.claude/rules/database-migrations.md` rule 2). A fresh `onCreate` proves
/// nothing about migrations, so this builds a store at the *frozen V2 schema*
/// with realistic data — including a Podcast whose `notificationEnabled` is the
/// non-optional V2 Bool — then opens it through the production path
/// (`StoreMigration.openOrMigrate`) and
/// asserts the upgrade completes without aborting and preserves all data.
@MainActor
final class StoreMigrationV2toV3Tests: XCTestCase {
    nonisolated(unsafe) private var dir: URL!
    nonisolated(unsafe) private var storeURL: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("migration-v2v3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storeURL = dir.appendingPathComponent("default.store")
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private let pubA = Date(timeIntervalSince1970: 1_600_000_000)
    private let pubB = Date(timeIntervalSince1970: 1_600_100_000)

    /// Writes a store at the frozen V2 schema with two podcasts, episodes (one
    /// with NULL optional fields, one played), a queue item, a bookmark, a
    /// folder + membership, and `notificationEnabled` set on a V2 (non-optional)
    /// Bool.
    private func seedV2Store() throws {
        try autoreleasepool {
            let schema = Schema(versionedSchema: EarshotSchemaV2.self)
            let v2 = try ModelContainer(
                for: schema,
                configurations: ModelConfiguration(schema: schema, url: storeURL)
            )
            let ctx = v2.mainContext

            // Podcast 1 — notifications ON (non-optional V2 Bool == true).
            let p1 = EarshotSchemaV2.Podcast(
                feedURL: "https://ex.com/one.xml",
                title: "Show One",
                author: "Author One",
                notificationEnabled: true
            )
            ctx.insert(p1)

            // Podcast 2 — notifications OFF, minimal fields (NULL optionals).
            let p2 = EarshotSchemaV2.Podcast(
                feedURL: "https://ex.com/two.xml",
                title: "Show Two",
                notificationEnabled: false
            )
            ctx.insert(p2)

            // Episode A — fully populated, played.
            let epA = EarshotSchemaV2.Episode(
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

            // Episode B — NULL optional fields, new/unplayed, queued.
            let epB = EarshotSchemaV2.Episode(
                guid: "b",
                title: "Ep B",
                audioURL: "https://ex.com/b.mp3",
                pubDate: pubB,
                status: .inQueue,
                createdAt: pubB
            )
            epB.podcast = p1
            ctx.insert(epB)

            let q = EarshotSchemaV2.QueueItem(episode: epB, position: 0)
            ctx.insert(q)

            let bm = EarshotSchemaV2.Bookmark(episode: epA, positionSeconds: 120, note: "good bit")
            ctx.insert(bm)

            let folder = EarshotSchemaV2.PodcastFolder(name: "News")
            ctx.insert(folder)
            let membership = EarshotSchemaV2.FolderMembership(folder: folder, podcast: p1, sortOrder: 0)
            ctx.insert(membership)

            try ctx.save()
        }
    }

    func testV2StoreMigratesToV3PreservingData() throws {
        try seedV2Store()

        // Migrate via the production path; nullable legacy data must not throw.
        let v3 = try StoreMigration.openOrMigrate(at: storeURL)
        let ctx = v3.mainContext

        // Podcasts survive.
        let podcasts = try ctx.fetch(
            FetchDescriptor<Podcast>(sortBy: [SortDescriptor(\.feedURL)])
        )
        XCTAssertEqual(podcasts.count, 2)
        XCTAssertEqual(podcasts[0].title, "Show One")
        XCTAssertEqual(podcasts[0].author, "Author One")
        XCTAssertEqual(podcasts[1].title, "Show Two")
        XCTAssertNil(podcasts[1].author, "NULL optional preserved")

        // notificationEnabled reads back correctly with nil-as-false semantics.
        // The V2 `true` survives as `true`; the V2 `false` survives (true/false,
        // never the abort that a non-optional destination would cause).
        XCTAssertEqual(podcasts[0].notificationEnabled, true)
        XCTAssertEqual(podcasts[0].notificationEnabled ?? false, true)
        XCTAssertEqual(podcasts[1].notificationEnabled ?? false, false)

        // Episodes survive with status / played state.
        let episodes = try ctx.fetch(
            FetchDescriptor<Episode>(sortBy: [SortDescriptor(\.guid)])
        )
        XCTAssertEqual(episodes.count, 2)
        XCTAssertEqual(episodes[0].guid, "a")
        XCTAssertTrue(episodes[0].isPlayed, "Ep A was played in V2")
        XCTAssertEqual(episodes[0].status, .played)
        XCTAssertEqual(episodes[0].durationSeconds, 1800)
        XCTAssertEqual(episodes[1].guid, "b")
        XCTAssertEqual(episodes[1].status, .inQueue)
        XCTAssertNil(episodes[1].durationSeconds, "NULL optional preserved")

        // Relationship preserved.
        XCTAssertEqual(episodes[0].podcast?.title, "Show One")

        // Queue, bookmark, folder, membership survive.
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<QueueItem>()).count, 1)
        let bookmarks = try ctx.fetch(FetchDescriptor<Bookmark>())
        XCTAssertEqual(bookmarks.count, 1)
        XCTAssertEqual(bookmarks.first?.note, "good bit")
        XCTAssertEqual(bookmarks.first?.episode?.guid, "a")
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<PodcastFolder>()).count, 1)
        let memberships = try ctx.fetch(FetchDescriptor<FolderMembership>())
        XCTAssertEqual(memberships.count, 1)
        XCTAssertEqual(memberships.first?.podcast?.feedURL, "https://ex.com/one.xml")
    }

    /// After migrating, the store must reopen cleanly as V3 (no second
    /// migration, data still present).
    func testMigratedStoreReopensAsV8() throws {
        try seedV2Store()

        try autoreleasepool {
            _ = try StoreMigration.openOrMigrate(at: storeURL)
        }

        let reopened = try StoreMigration.openOrMigrate(at: storeURL)
        let count = try reopened.mainContext.fetch(FetchDescriptor<Episode>()).count
        XCTAssertEqual(count, 2, "data should persist across reopen")
    }
}
