import XCTest
import SwiftData
@testable import Earshot

/// Exercises the manual V1→V2 SwiftData migration against a real on-disk store,
/// the way a tester's device upgrade actually runs it (issue #355). A fresh
/// `onCreate` proves nothing about migrations, so this builds a store at the
/// *previous* schema with realistic data and asserts the upgrade preserves it.
@MainActor
final class StoreMigrationTests: XCTestCase {
    nonisolated(unsafe) private var dir: URL!
    nonisolated(unsafe) private var storeURL: URL!

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

    /// Writes a store at the original (V1) schema with several podcasts and a mix
    /// of episodes — some played, some not, and some with NULL optional fields —
    /// so the upgrade path is exercised against realistic aged data rather than an
    /// empty/uniform store (per `.claude/rules/database-migrations.md`).
    /// Returns the total episode count seeded.
    @discardableResult
    private func seedRichV1Store() throws -> Int {
        var episodeCount = 0
        try autoreleasepool {
            let schemaV1 = Schema(versionedSchema: EarshotSchemaV1.self)
            let v1 = try ModelContainer(
                for: schemaV1,
                configurations: ModelConfiguration(schema: schemaV1, url: storeURL)
            )
            let ctx = v1.mainContext

            // Podcast A: full metadata, two episodes (one played).
            let podA = EarshotSchemaV1.Podcast(
                feedURL: "https://ex.com/a.xml",
                title: "Alpha Show",
                artworkURL: "https://ex.com/a.png",
                podcastDescription: "A described show"
            )
            ctx.insert(podA)
            let a1 = EarshotSchemaV1.Episode(
                guid: "a1", title: "Alpha Ep1", audioURL: "https://ex.com/a1.mp3",
                episodeDescription: "notes", pubDate: Date(timeIntervalSince1970: 1_500_000_000),
                isPlayed: true
            )
            a1.podcast = podA
            ctx.insert(a1)
            let a2 = EarshotSchemaV1.Episode(
                // NULL description and NULL pubDate — the aged-data edge case.
                guid: "a2", title: "Alpha Ep2", audioURL: "https://ex.com/a2.mp3",
                episodeDescription: nil, pubDate: nil, isPlayed: false
            )
            a2.podcast = podA
            ctx.insert(a2)

            // Podcast B: NULL artwork + NULL description, one played episode.
            let podB = EarshotSchemaV1.Podcast(
                feedURL: "https://ex.com/b.xml",
                title: "Beta Show",
                artworkURL: nil,
                podcastDescription: nil
            )
            ctx.insert(podB)
            let b1 = EarshotSchemaV1.Episode(
                guid: "b1", title: "Beta Ep1", audioURL: "https://ex.com/b1.mp3",
                pubDate: Date(timeIntervalSince1970: 1_600_000_000), isPlayed: true
            )
            b1.podcast = podB
            ctx.insert(b1)

            // Podcast C: no episodes at all (empty relationship edge case).
            let podC = EarshotSchemaV1.Podcast(
                feedURL: "https://ex.com/c.xml",
                title: "Gamma Show"
            )
            ctx.insert(podC)

            try ctx.save()
            episodeCount = 3
        }
        return episodeCount
    }

    /// Regression guard for #529: `openOrMigrate` must copy the original V1 store
    /// into `store-backups/` **before** it deletes the file to rebuild fresh, so a
    /// failed rebuild can never destroy the tester's only copy. Asserts both that
    /// the migrated data survives AND that a backup copy now exists on disk.
    func testV1MigrationBacksUpOriginalStoreBeforeReplacement() throws {
        // Acceptance criterion: back up before delete (#529 / migrations rule 5)
        let seededEpisodes = try seedRichV1Store()

        // Sanity: no backups exist yet before migration runs.
        let backupsDir = dir.appendingPathComponent("store-backups", isDirectory: true)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: backupsDir.path),
            "no backup should exist before migration runs"
        )

        // Migrate via the production path.
        let migrated = try StoreMigration.openOrMigrate(at: storeURL)
        let ctx = migrated.mainContext

        // Migrated data survives.
        let podcasts = try ctx.fetch(FetchDescriptor<Podcast>())
        XCTAssertEqual(podcasts.count, 3, "all podcasts should survive migration")
        let episodes = try ctx.fetch(
            FetchDescriptor<Episode>(sortBy: [SortDescriptor(\.guid)])
        )
        XCTAssertEqual(episodes.count, seededEpisodes, "all episodes should survive migration")
        // Played state preserved across the mixed fixture.
        let played = try XCTUnwrap(episodes.first { $0.guid == "a1" })
        let unplayed = try XCTUnwrap(episodes.first { $0.guid == "a2" })
        XCTAssertTrue(played.isPlayed, "a1 was played in V1")
        XCTAssertFalse(unplayed.isPlayed, "a2 was unplayed in V1")

        // The regression guard: a backup of the original store now exists on disk.
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: backupsDir.path),
            "openOrMigrate must create a store-backups directory before replacing the V1 store"
        )
        let backupContents = try FileManager.default.subpathsOfDirectory(atPath: backupsDir.path)
        XCTAssertTrue(
            backupContents.contains { $0.hasSuffix("default.store") },
            "the backup must include a copy of the original store file, found: \(backupContents)"
        )
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
            FetchDescriptor<Episode>(sortBy: [SortDescriptor(\.guid)])
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

    func testV1ReimportCanonicalizesAndMergesDuplicateSnapshotIdentity() throws {
        let context = TestStore.freshContext()
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        let new = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshots = [
            StoreMigration.PodcastSnapshot(
                feedURL: "HTTPS://Example.COM:443/feed.xml#old",
                title: "Old title",
                artworkURL: nil,
                podcastDescription: "Old description",
                createdAt: old,
                episodes: [
                    StoreMigration.EpisodeSnapshot(
                        guid: "shared", title: "Old episode",
                        audioURL: "https://example.com/old.mp3",
                        episodeDescription: nil, pubDate: old, isPlayed: false
                    ),
                ]
            ),
            StoreMigration.PodcastSnapshot(
                feedURL: "https://example.com/feed.xml",
                title: "New title",
                artworkURL: "https://example.com/art.png",
                podcastDescription: nil,
                createdAt: new,
                episodes: [
                    StoreMigration.EpisodeSnapshot(
                        guid: "shared", title: "New episode",
                        audioURL: "https://example.com/new.mp3",
                        episodeDescription: "New description", pubDate: new,
                        isPlayed: true
                    ),
                    StoreMigration.EpisodeSnapshot(
                        guid: "unique", title: "Unique episode",
                        audioURL: "https://example.com/unique.mp3",
                        episodeDescription: nil, pubDate: new, isPlayed: false
                    ),
                ]
            ),
        ]

        try StoreMigration.write(snapshots, into: context)

        let podcasts = try context.fetch(FetchDescriptor<Podcast>())
        XCTAssertEqual(podcasts.count, 1)
        XCTAssertEqual(podcasts.first?.feedURL, "https://example.com/feed.xml")
        XCTAssertEqual(podcasts.first?.title, "New title")
        XCTAssertEqual(podcasts.first?.createdAt, old)
        let episodes = try context.fetch(FetchDescriptor<Episode>())
        XCTAssertEqual(episodes.count, 2)
        let shared = try XCTUnwrap(episodes.first { $0.guid == "shared" })
        XCTAssertEqual(shared.title, "New episode")
        XCTAssertEqual(shared.audioURL, "https://example.com/new.mp3")
        XCTAssertTrue(shared.isPlayed)
    }
}
