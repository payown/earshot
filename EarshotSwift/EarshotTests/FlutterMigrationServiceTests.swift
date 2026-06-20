import XCTest
import SQLite3
import SwiftData
@testable import Earshot

/// Feed fetcher stub that returns a fixed feed, optionally failing for specific
/// URLs so we can exercise the import loop's per-feed error tolerance.
private final class StubFeedFetcher: FeedFetching {
    let feed: ParsedFeed
    let failingURLs: Set<String>
    init(feed: ParsedFeed, failingURLs: Set<String> = []) {
        self.feed = feed
        self.failingURLs = failingURLs
    }
    func fetch(_ urlString: String) async throws -> ParsedFeed {
        if failingURLs.contains(urlString) { throw URLError(.badServerResponse) }
        return feed
    }
}

@MainActor
final class FlutterMigrationServiceTests: XCTestCase {

    private var emptyFeed: ParsedFeed {
        ParsedFeed(
            title: "Show", artworkURL: nil, description: nil, author: nil,
            websiteURL: nil, language: nil, category: nil, episodes: []
        )
    }

    /// Builds a throwaway SQLite DB mirroring the drift `podcasts` table (only the
    /// `rss_url` column matters to the import). Returns its file URL.
    private func makeTempDB(rssURLs: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("earshot_export.db")

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(
            sqlite3_exec(db, "CREATE TABLE podcasts (id INTEGER PRIMARY KEY, rss_url TEXT, title TEXT)", nil, nil, nil),
            SQLITE_OK
        )
        for rss in rssURLs {
            let escaped = rss.replacingOccurrences(of: "'", with: "''")
            XCTAssertEqual(
                sqlite3_exec(db, "INSERT INTO podcasts (rss_url, title) VALUES ('\(escaped)', 'T')", nil, nil, nil),
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

    // MARK: importSubscriptions

    func testImportSubscribesEachFeedAndReturnsCount() async throws {
        let ctx = TestStore.freshContext()
        let dbURL = try makeTempDB(rssURLs: ["https://a/feed.xml", "https://b/feed.xml"])
        let repo = SubscriptionRepository(context: ctx, feed: StubFeedFetcher(feed: emptyFeed))
        let service = FlutterMigrationService(context: ctx, databaseURL: dbURL, subscriptions: repo)

        let count = await service.importSubscriptions()

        XCTAssertEqual(count, 2)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Podcast>()).count, 2)
    }

    func testImportToleratesPerFeedFailure() async throws {
        let ctx = TestStore.freshContext()
        let dbURL = try makeTempDB(rssURLs: ["https://a/feed.xml", "https://b/feed.xml"])
        let repo = SubscriptionRepository(
            context: ctx,
            feed: StubFeedFetcher(feed: emptyFeed, failingURLs: ["https://b/feed.xml"])
        )
        let service = FlutterMigrationService(context: ctx, databaseURL: dbURL, subscriptions: repo)

        let count = await service.importSubscriptions()

        XCTAssertEqual(count, 1)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Podcast>()).count, 1)
    }

    func testImportNoOpsWhenNoSharedDB() async {
        let ctx = TestStore.freshContext()
        let service = FlutterMigrationService(context: ctx, databaseURL: nil)
        let count = await service.importSubscriptions()
        XCTAssertEqual(count, 0)
    }

    // MARK: flag + reminder count

    func testCompletionFlagRoundTrips() {
        let ctx = TestStore.freshContext()
        let service = FlutterMigrationService(context: ctx, databaseURL: nil)
        XCTAssertFalse(service.isComplete)
        service.markComplete()
        XCTAssertTrue(FlutterMigrationService(context: ctx, databaseURL: nil).isComplete)
    }

    func testReminderCountIncrements() {
        let ctx = TestStore.freshContext()
        let service = FlutterMigrationService(context: ctx, databaseURL: nil)
        XCTAssertEqual(service.reminderCount, 0)
        service.recordReminderDismissal()
        service.recordReminderDismissal()
        XCTAssertEqual(FlutterMigrationService(context: ctx, databaseURL: nil).reminderCount, 2)
    }
}
