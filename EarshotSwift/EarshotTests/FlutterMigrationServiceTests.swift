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

    // MARK: completion flag

    func testCompletionFlagRoundTrips() {
        let ctx = TestStore.freshContext()
        let service = FlutterMigrationService(context: ctx, databaseURL: nil)
        XCTAssertFalse(service.isComplete)
        service.markComplete()
        XCTAssertTrue(FlutterMigrationService(context: ctx, databaseURL: nil).isComplete)
    }
}
