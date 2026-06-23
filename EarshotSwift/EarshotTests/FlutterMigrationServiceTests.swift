import XCTest
import SQLite3
import SwiftData
@testable import Earshot

@MainActor
final class FlutterMigrationServiceTests: XCTestCase {

    /// Builds a throwaway SQLite DB mirroring the relevant drift `podcasts`
    /// columns. Returns its file URL.
    private func makeTempDB(rssURLs: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("earshot.db")

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(
            sqlite3_exec(db, "CREATE TABLE podcasts (id INTEGER PRIMARY KEY, rss_url TEXT, title TEXT, author TEXT, artwork_url TEXT)", nil, nil, nil),
            SQLITE_OK
        )
        for rss in rssURLs {
            let escaped = rss.replacingOccurrences(of: "'", with: "''")
            XCTAssertEqual(
                sqlite3_exec(db, "INSERT INTO podcasts (rss_url, title, artwork_url) VALUES ('\(escaped)', 'T', 'art')", nil, nil, nil),
                SQLITE_OK
            )
        }
        return url
    }

    /// Builds a throwaway SQLite DB with a drift-shaped `episodes` table. Each
    /// tuple is (guid, audioURL, status, inboxDismissed, pubDateEpoch,
    /// positionSeconds); nil maps to SQL NULL. drift stores DateTime as epoch
    /// seconds and Bool as 0/1, which the fixture mirrors.
    private func makeEpisodesDB(
        _ rows: [(guid: String?, audio: String?, status: String, dismissed: Int, pub: Int?, position: Int?)]
    ) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("earshot.db")

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(
            sqlite3_exec(db, "CREATE TABLE episodes (id INTEGER PRIMARY KEY, podcast_id INTEGER, guid TEXT, title TEXT, audio_url TEXT, status TEXT, inbox_dismissed INTEGER, pub_date INTEGER, position_seconds INTEGER, played_at INTEGER)", nil, nil, nil),
            SQLITE_OK
        )
        for row in rows {
            let guid = row.guid.map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" } ?? "NULL"
            let audio = row.audio.map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" } ?? "NULL"
            let pub = row.pub.map(String.init) ?? "NULL"
            let position = row.position.map(String.init) ?? "NULL"
            XCTAssertEqual(
                sqlite3_exec(db, "INSERT INTO episodes (guid, audio_url, title, status, inbox_dismissed, pub_date, position_seconds) VALUES (\(guid), \(audio), 'T', '\(row.status)', \(row.dismissed), \(pub), \(position))", nil, nil, nil),
                SQLITE_OK
            )
        }
        return url
    }

    // MARK: readFeedURLs

    func testReadsRssUrlColumnAndSkipsBlankRows() throws {
        let ctx = TestStore.freshContext()
        let dbURL = try makeTempDB(rssURLs: ["https://a/feed.xml", "   ", "https://b/feed.xml"])
        let service = FlutterMigrationService(context: ctx, databaseURL: dbURL)

        XCTAssertEqual(service.readFeedURLs(), ["https://a/feed.xml", "https://b/feed.xml"])
    }

    func testReadFeedURLsReturnsNilWhenFileMissing() {
        let ctx = TestStore.freshContext()
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)/nope.db")
        let service = FlutterMigrationService(context: ctx, databaseURL: missing)

        XCTAssertNil(service.readFeedURLs())
    }

    func testReadFeedURLsReturnsNilWhenURLIsNil() {
        let ctx = TestStore.freshContext()
        let service = FlutterMigrationService(context: ctx, databaseURL: nil)
        XCTAssertNil(service.readFeedURLs())
    }

    func testReadSubscriptionsIncludesMetadata() throws {
        let ctx = TestStore.freshContext()
        let dbURL = try makeTempDB(rssURLs: ["https://a/feed.xml"])
        let service = FlutterMigrationService(context: ctx, databaseURL: dbURL)

        let subs = try XCTUnwrap(service.readSubscriptions())
        XCTAssertEqual(subs.count, 1)
        XCTAssertEqual(subs.first?.rssURL, "https://a/feed.xml")
        XCTAssertEqual(subs.first?.title, "T")
        XCTAssertEqual(subs.first?.artworkURL, "art")
        XCTAssertNil(subs.first?.author) // not set in fixture -> nil, not crash
    }

    // MARK: readEpisodes

    func testReadEpisodesDerivesInboxAndPlayedState() throws {
        let ctx = TestStore.freshContext()
        let dbURL = try makeEpisodesDB([
            (guid: "played", audio: "https://x/played.mp3", status: "played", dismissed: 1, pub: 1_700_000_000, position: 600),
            (guid: "inbox", audio: "https://x/inbox.mp3", status: "newEpisode", dismissed: 0, pub: 1_700_100_000, position: 0),
            (guid: "dismissed", audio: "https://x/dismissed.mp3", status: "newEpisode", dismissed: 1, pub: nil, position: nil),
            (guid: "queued", audio: "https://x/queued.mp3", status: "inQueue", dismissed: 1, pub: nil, position: 120),
        ])
        let service = FlutterMigrationService(context: ctx, databaseURL: dbURL)

        let episodes = try XCTUnwrap(service.readEpisodes())
        XCTAssertEqual(episodes.count, 4)
        let byGUID = Dictionary(uniqueKeysWithValues: episodes.map { ($0.guid ?? "", $0) })

        // Played row: isPlayed, dismissed from inbox, position + pubDate carried.
        let played = try XCTUnwrap(byGUID["played"])
        XCTAssertTrue(played.isPlayed)
        XCTAssertTrue(played.inboxDismissed)
        XCTAssertEqual(played.positionSeconds, 600)
        XCTAssertEqual(played.pubDate, Date(timeIntervalSince1970: 1_700_000_000))

        // Genuine inbox row: not played, NOT dismissed (stays in the inbox).
        let inbox = try XCTUnwrap(byGUID["inbox"])
        XCTAssertFalse(inbox.isPlayed)
        XCTAssertFalse(inbox.inboxDismissed)

        // newEpisode but dismissed in Flutter: stays dismissed.
        let dismissed = try XCTUnwrap(byGUID["dismissed"])
        XCTAssertFalse(dismissed.isPlayed)
        XCTAssertTrue(dismissed.inboxDismissed)
        XCTAssertNil(dismissed.pubDate)      // NULL -> nil, no crash
        XCTAssertNil(dismissed.positionSeconds)

        // Queued (non-inbox) row: never resurfaces in the new inbox.
        let queued = try XCTUnwrap(byGUID["queued"])
        XCTAssertFalse(queued.isPlayed)
        XCTAssertTrue(queued.inboxDismissed)
    }

    func testReadEpisodesReturnsNilWhenFileMissing() {
        let ctx = TestStore.freshContext()
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)/nope.db")
        XCTAssertNil(FlutterMigrationService(context: ctx, databaseURL: missing).readEpisodes())
    }

    func testReadEpisodesReturnsNilWhenTableMissing() throws {
        // A DB that has podcasts but no episodes table: prepare fails -> nil.
        let ctx = TestStore.freshContext()
        let dbURL = try makeTempDB(rssURLs: ["https://a/feed.xml"])
        XCTAssertNil(FlutterMigrationService(context: ctx, databaseURL: dbURL).readEpisodes())
    }

    func testReadEpisodesSkipsRowsWithNoIdentifier() throws {
        let ctx = TestStore.freshContext()
        let dbURL = try makeEpisodesDB([
            (guid: nil, audio: nil, status: "newEpisode", dismissed: 0, pub: nil, position: nil),
            (guid: "keep", audio: nil, status: "newEpisode", dismissed: 0, pub: nil, position: nil),
        ])
        let episodes = try XCTUnwrap(FlutterMigrationService(context: ctx, databaseURL: dbURL).readEpisodes())
        XCTAssertEqual(episodes.map(\.guid), ["keep"])
    }

    // MARK: end-to-end import (#426 acceptance criterion a)

    /// A synthetic earshot.db read through `readEpisodes()` and applied to a
    /// seeded store via `EpisodeStateImporter` restores inbox/played/position
    /// correctly — the full read+overlay path the launch orchestration runs.
    func testSyntheticDatabaseRestoresInboxPlayedAndPositionEndToEnd() throws {
        let ctx = TestStore.freshContext()

        // The post-backfill store: episodes inserted by the refresh, all
        // pre-dismissed and unplayed (the state #426's importer must correct).
        let podcast = Podcast(feedURL: "https://x/feed.xml", title: "Show")
        ctx.insert(podcast)
        for guid in ["played", "inbox", "queued"] {
            let ep = Episode(
                guid: guid,
                title: "Ep \(guid)",
                audioURL: "https://x/\(guid).mp3",
                inboxDismissed: true
            )
            ep.podcast = podcast
            ctx.insert(ep)
        }
        try ctx.save()

        // The user's real Flutter state living in earshot.db.
        let dbURL = try makeEpisodesDB([
            (guid: "played", audio: "https://x/played.mp3", status: "played", dismissed: 1, pub: nil, position: 450),
            (guid: "inbox", audio: "https://x/inbox.mp3", status: "newEpisode", dismissed: 0, pub: nil, position: 0),
            (guid: "queued", audio: "https://x/queued.mp3", status: "inQueue", dismissed: 1, pub: nil, position: 90),
        ])
        let service = FlutterMigrationService(context: ctx, databaseURL: dbURL)

        let flutterEpisodes = try XCTUnwrap(service.readEpisodes())
        let restored = EpisodeStateImporter(context: ctx).apply(flutterEpisodes)
        XCTAssertEqual(restored, 3)

        let all = try ctx.fetch(FetchDescriptor<Episode>())
        let byGUID = Dictionary(uniqueKeysWithValues: all.map { ($0.guid, $0) })

        let played = try XCTUnwrap(byGUID["played"])
        XCTAssertTrue(played.isPlayed)
        XCTAssertTrue(played.inboxDismissed)        // played -> never in inbox
        XCTAssertEqual(played.positionSeconds, 450)

        let inbox = try XCTUnwrap(byGUID["inbox"])
        XCTAssertFalse(inbox.isPlayed)
        XCTAssertFalse(inbox.inboxDismissed)        // restored into the inbox

        let queued = try XCTUnwrap(byGUID["queued"])
        XCTAssertFalse(queued.isPlayed)
        XCTAssertTrue(queued.inboxDismissed)        // non-inbox -> stays out
        XCTAssertEqual(queued.positionSeconds, 90)
    }

    // MARK: completion flag

    func testCompletionFlagRoundTrips() {
        let ctx = TestStore.freshContext()
        let service = FlutterMigrationService(context: ctx, databaseURL: nil)
        XCTAssertFalse(service.isComplete)
        service.markComplete()
        XCTAssertTrue(FlutterMigrationService(context: ctx, databaseURL: nil).isComplete)
    }

    // MARK: empty-import retry gating (#426)

    func testEmptyImportRetriesThenGivesUp() {
        let ctx = TestStore.freshContext()
        let service = FlutterMigrationService(context: ctx, databaseURL: nil)

        // First two attempts: do NOT mark complete, so the next launch retries.
        XCTAssertFalse(service.recordEmptyImportAttempt())
        XCTAssertFalse(service.isComplete)
        XCTAssertFalse(service.recordEmptyImportAttempt())
        XCTAssertFalse(service.isComplete)

        // Third attempt hits the budget: give up and mark complete.
        XCTAssertTrue(service.recordEmptyImportAttempt())
        XCTAssertTrue(service.isComplete)
    }

    // MARK: self-heal helpers (#426)

    func testHasFlutterDataReflectsDatabaseContents() throws {
        let ctx = TestStore.freshContext()
        let withData = try makeTempDB(rssURLs: ["https://a/feed.xml"])
        XCTAssertTrue(FlutterMigrationService(context: ctx, databaseURL: withData).hasFlutterData())

        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)/nope.db")
        XCTAssertFalse(FlutterMigrationService(context: ctx, databaseURL: missing).hasFlutterData())
    }

    func testResetForSelfHealReopensTheGate() {
        let ctx = TestStore.freshContext()
        let service = FlutterMigrationService(context: ctx, databaseURL: nil)
        service.markComplete()
        XCTAssertTrue(service.isComplete)

        service.resetForSelfHeal()
        XCTAssertFalse(service.isComplete)
        // Attempt counter is cleared, so the re-import gets a full retry budget.
        XCTAssertFalse(service.recordEmptyImportAttempt()) // attempt 1 of fresh budget
        XCTAssertFalse(service.isComplete)
    }
}
