import XCTest
import SQLite3
import SwiftData
@testable import Earshot

/// Covers ``FlutterMigrationService/runManualImport`` — the on-demand import the
/// Settings → Data "Import older data" action calls (#429). The happy path seeds
/// the store to the post-migration shape (shells + episodes already present) so
/// the import is exercised end to end without hitting the network: shell import
/// dedupes to zero, the (unreachable) refresh is caught per-feed, and the
/// episode-state + queue overlays run against the seeded episodes.
@MainActor
final class ManualImportTests: XCTestCase {

    /// Builds a throwaway earshot.db carrying the three tables the manual import
    /// reads: `podcasts`, `episodes`, and `queue_items`. Mirrors the drift shapes
    /// the production read queries expect (epoch DateTime, 0/1 Bool, String
    /// status). `queuePosition` nil inserts the episode but no queue entry.
    private func makeFullDB(
        feedURL: String,
        episodes: [(id: Int, guid: String, audio: String, status: String, dismissed: Int, position: Int?, queuePosition: Int?)]
    ) throws -> URL {
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
        XCTAssertEqual(
            sqlite3_exec(db, "CREATE TABLE episodes (id INTEGER PRIMARY KEY, podcast_id INTEGER, guid TEXT, title TEXT, audio_url TEXT, status TEXT, inbox_dismissed INTEGER, pub_date INTEGER, position_seconds INTEGER, played_at INTEGER)", nil, nil, nil),
            SQLITE_OK
        )
        XCTAssertEqual(
            sqlite3_exec(db, "CREATE TABLE queue_items (id INTEGER PRIMARY KEY, episode_id INTEGER, position INTEGER, added_at INTEGER)", nil, nil, nil),
            SQLITE_OK
        )

        let escapedFeed = feedURL.replacingOccurrences(of: "'", with: "''")
        XCTAssertEqual(
            sqlite3_exec(db, "INSERT INTO podcasts (id, rss_url, title, author, artwork_url) VALUES (1, '\(escapedFeed)', 'Show', 'Host', 'art')", nil, nil, nil),
            SQLITE_OK
        )
        for ep in episodes {
            let position = ep.position.map(String.init) ?? "NULL"
            XCTAssertEqual(
                sqlite3_exec(db, "INSERT INTO episodes (id, podcast_id, guid, title, audio_url, status, inbox_dismissed, position_seconds) VALUES (\(ep.id), 1, '\(ep.guid)', 'T', '\(ep.audio)', '\(ep.status)', \(ep.dismissed), \(position))", nil, nil, nil),
                SQLITE_OK
            )
            if let queuePosition = ep.queuePosition {
                XCTAssertEqual(
                    sqlite3_exec(db, "INSERT INTO queue_items (episode_id, position) VALUES (\(ep.id), \(queuePosition))", nil, nil, nil),
                    SQLITE_OK
                )
            }
        }
        return url
    }

    /// Seeds the shared store to the post-migration shape: one subscribed podcast
    /// whose episodes are already present, all pre-dismissed/unplayed (the state
    /// the overlay must correct). Returns the context.
    @discardableResult
    private func seedStore(
        feedURL: String,
        episodes: [(guid: String, audio: String)]
    ) -> ModelContext {
        let ctx = TestStore.freshContext()
        let podcast = Podcast(feedURL: feedURL, title: "Show")
        // Seed a high-water mark + refreshedAt so refreshAll doesn't take the
        // backfill path on the unreachable feed; the fetch fails and is caught.
        podcast.lastSeenPubDate = Date(timeIntervalSince1970: 1)
        podcast.refreshedAt = Date(timeIntervalSince1970: 1)
        ctx.insert(podcast)
        for spec in episodes {
            let episode = Episode(
                guid: spec.guid,
                title: "Ep \(spec.guid)",
                audioURL: spec.audio,
                inboxDismissed: true
            )
            episode.podcast = podcast
            ctx.insert(episode)
        }
        try? ctx.save()
        return ctx
    }

    private func episodes(_ ctx: ModelContext) throws -> [Episode] {
        try ctx.fetch(FetchDescriptor<Episode>())
    }

    private func podcastCount(_ ctx: ModelContext) throws -> Int {
        try ctx.fetch(FetchDescriptor<Podcast>()).count
    }

    func testHappyPathRestoresStateAndQueueAndRecordsSucceeded() async throws {
        let feed = "https://x/feed.xml"
        let ctx = seedStore(feedURL: feed, episodes: [
            (guid: "played", audio: "https://x/played.mp3"),
            (guid: "inbox", audio: "https://x/inbox.mp3"),
            (guid: "queued", audio: "https://x/queued.mp3"),
        ])
        let dbURL = try makeFullDB(feedURL: feed, episodes: [
            (id: 1, guid: "played", audio: "https://x/played.mp3", status: "played", dismissed: 1, position: 450, queuePosition: nil),
            (id: 2, guid: "inbox", audio: "https://x/inbox.mp3", status: "newEpisode", dismissed: 0, position: 0, queuePosition: nil),
            (id: 3, guid: "queued", audio: "https://x/queued.mp3", status: "inQueue", dismissed: 1, position: 90, queuePosition: 0),
        ])
        let service = FlutterMigrationService(context: ctx, databaseURL: dbURL)

        let ok = await service.runManualImport()
        XCTAssertTrue(ok)
        XCTAssertEqual(service.status, .succeeded)
        XCTAssertNotNil(service.lastAttemptDate)
        XCTAssertTrue(service.isComplete)

        let byGUID = Dictionary(uniqueKeysWithValues: try episodes(ctx).map { ($0.guid, $0) })
        let played = try XCTUnwrap(byGUID["played"])
        XCTAssertTrue(played.isPlayed)
        XCTAssertTrue(played.inboxDismissed)
        XCTAssertEqual(played.positionSeconds, 450)

        let inbox = try XCTUnwrap(byGUID["inbox"])
        XCTAssertFalse(inbox.isPlayed)
        XCTAssertFalse(inbox.inboxDismissed)

        let queued = try XCTUnwrap(byGUID["queued"])
        XCTAssertEqual(queued.status, .inQueue)
        XCTAssertNotNil(queued.queueItem)
    }

    func testReRunIsIdempotentAcrossPodcastsAndQueue() async throws {
        let feed = "https://x/feed.xml"
        let ctx = seedStore(feedURL: feed, episodes: [
            (guid: "queued", audio: "https://x/queued.mp3"),
        ])
        let dbURL = try makeFullDB(feedURL: feed, episodes: [
            (id: 1, guid: "queued", audio: "https://x/queued.mp3", status: "inQueue", dismissed: 1, position: 30, queuePosition: 0),
        ])
        let service = FlutterMigrationService(context: ctx, databaseURL: dbURL)

        let firstRun = await service.runManualImport()
        XCTAssertTrue(firstRun)
        let podcastsAfterFirst = try podcastCount(ctx)
        let queuedAfterFirst = QueueRepository(context: ctx).queue().map(\.guid)
        XCTAssertEqual(podcastsAfterFirst, 1)
        XCTAssertEqual(queuedAfterFirst, ["queued"])

        // Re-run: no duplicate podcast, no duplicate queue entry, still succeeds.
        let secondRun = await service.runManualImport()
        XCTAssertTrue(secondRun)
        XCTAssertEqual(try podcastCount(ctx), 1)
        XCTAssertEqual(QueueRepository(context: ctx).queue().map(\.guid), ["queued"])
        XCTAssertEqual(service.status, .succeeded)
    }

    func testMissingDatabaseIsNoOpSuccess() async throws {
        let ctx = TestStore.freshContext()
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)/nope.db")
        let service = FlutterMigrationService(context: ctx, databaseURL: missing)

        let ok = await service.runManualImport()
        XCTAssertTrue(ok) // a clean install has nothing to import — not a failure
        XCTAssertEqual(service.status, .succeeded)
        XCTAssertNotNil(service.lastAttemptDate)
        XCTAssertEqual(try podcastCount(ctx), 0)
    }

    func testStatusReadsDefaultBeforeAnyRun() throws {
        let ctx = TestStore.freshContext()
        let service = FlutterMigrationService(context: ctx, databaseURL: nil)
        XCTAssertEqual(service.status, .notAttempted)
        XCTAssertNil(service.lastAttemptDate)
    }

    func testStatusHelpersRecordSucceededAndFailed() throws {
        let ctx = TestStore.freshContext()
        let service = FlutterMigrationService(context: ctx, databaseURL: nil)

        service.recordImportAttempt()
        XCTAssertNotNil(service.lastAttemptDate)

        service.recordImportSucceeded()
        XCTAssertEqual(service.status, .succeeded)

        service.recordImportFailed()
        XCTAssertEqual(service.status, .failed)
    }
}
