import XCTest
import SwiftData
@testable import Earshot

/// Exercises the V4→V5 SwiftData migration against a real on-disk store, the way
/// a tester's device upgrade actually runs it (issue #701,
/// `.claude/rules/database-migrations.md` rule 2 / the SwiftUI section's required
/// CI gate). A fresh `onCreate` proves nothing about migrations, so this builds a
/// store at the *frozen V4 schema* with realistic data, then opens it through the
/// production path (`StoreMigration.openOrMigrate`, which runs
/// `EarshotMigrationPlan`) and asserts the upgrade completes without aborting and
/// preserves everything.
///
/// The risk this test exists to catch: V4→V5 adds the ``ActiveDownload`` entity,
/// and a store carrying 241,979 episodes runs this migration on first launch. If
/// adding an entity turned out NOT to be lightweight-inferrable, or if it
/// perturbed `Episode` in any way, every episode's `downloadStatus` could reset
/// (or the open could abort outright and trip the reset-on-failure wipe). So the
/// assertions are on the VALUES — one episode per `DownloadStatus` case —
/// not merely on "it did not throw".
@MainActor
final class StoreMigrationV4toV5Tests: XCTestCase {

    nonisolated(unsafe) private var dir: URL!
    nonisolated(unsafe) private var storeURL: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("migration-v4v5-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storeURL = dir.appendingPathComponent("default.store")
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private let pubA = Date(timeIntervalSince1970: 1_600_000_000)
    private let pubB = Date(timeIntervalSince1970: 1_600_100_000)

    /// One episode per `DownloadStatus` case, so a silently-dropped or reset
    /// value cannot pass. `.downloading` and `.pending` matter most: those are the
    /// two states the new `ActiveDownload` table mirrors.
    private static let downloadCases: [(guid: String, status: DownloadStatus)] = [
        ("ep-none", .none),
        ("ep-pending", .pending),
        ("ep-downloading", .downloading),
        ("ep-downloaded", .downloaded),
        ("ep-failed", .failed),
    ]

    /// Writes a store at the frozen V4 schema with two podcasts (one with a
    /// per-podcast `speedOverride` and `introSkipSeconds`, matching real aged
    /// data), one episode per download status (one with NULL optional fields, one
    /// played), a queue item, and a bookmark. `EarshotSchemaV4` has no
    /// `ActiveDownload` entity at all — it did not exist yet at V4.
    private func seedV4Store() throws {
        try autoreleasepool {
            let schema = Schema(versionedSchema: EarshotSchemaV4.self)
            let v4 = try ModelContainer(
                for: schema,
                configurations: ModelConfiguration(schema: schema, url: storeURL)
            )
            let ctx = v4.mainContext

            let p1 = EarshotSchemaV4.Podcast(
                feedURL: "https://ex.com/one.xml",
                title: "Show One",
                author: "Author One",
                notificationEnabled: true,
                speedOverride: 1.5,
                introSkipSeconds: 30
            )
            ctx.insert(p1)

            let p2 = EarshotSchemaV4.Podcast(
                feedURL: "https://ex.com/two.xml",
                title: "Show Two",
                notificationEnabled: false
            )
            ctx.insert(p2)

            for (guid, status) in Self.downloadCases {
                let ep = EarshotSchemaV4.Episode(
                    guid: guid,
                    title: "Ep \(guid)",
                    audioURL: "https://ex.com/\(guid).mp3",
                    // Leave durationSeconds NULL to cover an older row's nullable
                    // column.
                    pubDate: pubA,
                    downloadStatus: status,
                    downloadPath: status == .downloaded ? "\(guid).mp3" : nil,
                    createdAt: pubA
                )
                ep.podcast = p1
                ctx.insert(ep)
            }

            // A played episode on the second podcast, plus queue + bookmark rows,
            // so relationship integrity across the migration is covered too.
            let played = EarshotSchemaV4.Episode(
                guid: "ep-played",
                title: "Played",
                audioURL: "https://ex.com/played.mp3",
                episodeDescription: "desc",
                durationSeconds: 1800,
                pubDate: pubB,
                status: .played,
                positionSeconds: 1800,
                playedAt: pubB,
                createdAt: pubB
            )
            played.podcast = p2
            ctx.insert(played)

            let queued = EarshotSchemaV4.Episode(
                guid: "ep-queued",
                title: "Queued",
                audioURL: "https://ex.com/queued.mp3",
                pubDate: pubB,
                status: .inQueue,
                createdAt: pubB
            )
            queued.podcast = p2
            ctx.insert(queued)

            ctx.insert(EarshotSchemaV4.QueueItem(episode: queued, position: 0))
            ctx.insert(EarshotSchemaV4.Bookmark(episode: played, positionSeconds: 120, note: "good bit"))

            try ctx.save()
        }
    }

    /// The load-bearing assertion of the whole #701 design: a real V4 store
    /// migrates, and every `downloadStatus` value comes back INTACT. `Episode` is
    /// not reshaped by V4→V5, so nothing should be able to touch these values —
    /// this proves it.
    func testV4StoreMigratesToV5PreservingEveryDownloadStatus() throws {
        try seedV4Store()

        let v5 = try StoreMigration.openOrMigrate(at: storeURL)
        let ctx = v5.mainContext

        let episodes = try ctx.fetch(FetchDescriptor<Episode>())
        XCTAssertEqual(episodes.count, Self.downloadCases.count + 2,
                       "migration dropped or duplicated episode rows")

        for (guid, expected) in Self.downloadCases {
            guard let ep = episodes.first(where: { $0.guid == guid }) else {
                return XCTFail("episode \(guid) did not survive the migration")
            }
            XCTAssertEqual(ep.downloadStatus, expected,
                           "\(guid): downloadStatus was not preserved across V4→V5")
        }

        // The downloaded row keeps its path; the others keep their NULL.
        let downloaded = episodes.first { $0.guid == "ep-downloaded" }
        XCTAssertEqual(downloaded?.downloadPath, "ep-downloaded.mp3")
        XCTAssertNil(episodes.first { $0.guid == "ep-pending" }?.downloadPath)
        XCTAssertNil(episodes.first { $0.guid == "ep-none" }?.durationSeconds,
                     "NULL optional preserved")
    }

    /// The new entity must exist and be queryable — and must start EMPTY. An
    /// empty table is the CORRECT post-migration state: no download is in flight
    /// across an app update, which is exactly why V4→V5 needs no backfill.
    func testActiveDownloadIsQueryableAndEmptyAfterMigration() throws {
        try seedV4Store()

        let v5 = try StoreMigration.openOrMigrate(at: storeURL)
        let ctx = v5.mainContext

        let rows = try ctx.fetch(FetchDescriptor<ActiveDownload>())
        XCTAssertTrue(rows.isEmpty,
                      "ActiveDownload must start empty after migration; found \(rows.count) row(s)")

        // And the plain-String predicate this table exists for must actually run
        // against the migrated store (a Codable-enum predicate throws; this must
        // not).
        let downloading = ActiveDownloadState.downloading.rawValue
        let found = try ctx.fetch(
            FetchDescriptor<ActiveDownload>(predicate: #Predicate { $0.stateRaw == downloading })
        )
        XCTAssertTrue(found.isEmpty)
    }

    /// The migrated store must accept writes to the new entity going forward.
    func testMigratedStoreAcceptsActiveDownloadWrites() throws {
        try seedV4Store()

        let v5 = try StoreMigration.openOrMigrate(at: storeURL)
        let ctx = v5.mainContext

        guard let episode = try ctx.fetch(FetchDescriptor<Episode>())
            .first(where: { $0.guid == "ep-none" }) else {
            return XCTFail("seeded episode missing after migration")
        }
        ActiveDownload.setDownloadStatus(.downloading, on: episode, in: ctx)
        try ctx.save()

        let rows = try ctx.fetch(FetchDescriptor<ActiveDownload>())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.state, .downloading)
        XCTAssertEqual(rows.first?.episode?.guid, "ep-none")
        XCTAssertEqual(episode.downloadStatus, .downloading)
    }

    /// Relationships must survive too — a botched entity migration can orphan rows.
    func testRelationshipsSurviveMigration() throws {
        try seedV4Store()

        let v5 = try StoreMigration.openOrMigrate(at: storeURL)
        let ctx = v5.mainContext

        let episodes = try ctx.fetch(FetchDescriptor<Episode>())
        for (guid, _) in Self.downloadCases {
            let ep = episodes.first { $0.guid == guid }
            XCTAssertEqual(ep?.podcast?.feedURL, "https://ex.com/one.xml",
                           "\(guid) lost its podcast relationship")
        }

        let podcasts = try ctx.fetch(FetchDescriptor<Podcast>(sortBy: [SortDescriptor(\.feedURL)]))
        XCTAssertEqual(podcasts.count, 2)
        XCTAssertEqual(podcasts[0].speedOverride, 1.5, "pre-existing override survives")
        XCTAssertEqual(podcasts[0].introSkipSeconds, 30, "V4's introSkipSeconds survives")

        XCTAssertTrue(episodes.first { $0.guid == "ep-played" }?.isPlayed ?? false)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<QueueItem>()).count, 1)
        let bookmarks = try ctx.fetch(FetchDescriptor<Bookmark>())
        XCTAssertEqual(bookmarks.count, 1)
        XCTAssertEqual(bookmarks.first?.note, "good bit")
    }

    /// After migrating, the store must reopen cleanly as V5 (no second migration,
    /// data still present, download states still intact).
    func testMigratedStoreReopensAsV5() throws {
        try seedV4Store()

        try autoreleasepool {
            _ = try StoreMigration.openOrMigrate(at: storeURL)
        }

        let reopened = try StoreMigration.openOrMigrate(at: storeURL)
        let ctx = reopened.mainContext
        let episodes = try ctx.fetch(FetchDescriptor<Episode>())
        XCTAssertEqual(episodes.count, Self.downloadCases.count + 2,
                       "data should persist across reopen")
        XCTAssertEqual(episodes.first { $0.guid == "ep-downloading" }?.downloadStatus,
                       .downloading, "download state survives a reopen too")
        XCTAssertTrue(try ctx.fetch(FetchDescriptor<ActiveDownload>()).isEmpty)
    }
}
