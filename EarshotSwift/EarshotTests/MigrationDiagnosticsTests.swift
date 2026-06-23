import XCTest
import SQLite3
import SwiftData
@testable import Earshot

/// Robustness coverage for the temporary #430 diagnostics logging on
/// ``FlutterMigrationService``. `logDiagnostics(trigger:)` is read-only and
/// returns nothing, so there is no return value or state change to assert on.
/// What matters for a returning user is that it never crashes or throws against
/// the on-disk shapes a real device can present: a missing file, a nil
/// Documents URL, a zero-byte file, a healthy fixture, and — the prime suspect
/// for the data-loss report — a database whose schema predates the `podcasts`
/// table/columns the diagnostics query. Each case exercises a distinct guarded
/// path in ``FlutterMigrationService/logDiagnostics(trigger:)`` /
/// `logScalar(_:label:sql:trigger:)` and asserts it completes cleanly.
@MainActor
final class MigrationDiagnosticsTests: XCTestCase {

    /// A drift-shaped `podcasts` table with an `is_subscribed` flag, mirroring
    /// the columns the diagnostics scalar queries read.
    private func makeHealthyDB(subscribed: Int, unsubscribed: Int) throws -> URL {
        let url = try freshDBURL()
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(
            sqlite3_exec(db, "PRAGMA user_version = 12", nil, nil, nil),
            SQLITE_OK
        )
        XCTAssertEqual(
            sqlite3_exec(db, "CREATE TABLE podcasts (id INTEGER PRIMARY KEY, rss_url TEXT, is_subscribed INTEGER)", nil, nil, nil),
            SQLITE_OK
        )
        for i in 0..<subscribed {
            XCTAssertEqual(sqlite3_exec(db, "INSERT INTO podcasts (rss_url, is_subscribed) VALUES ('https://s/\(i)', 1)", nil, nil, nil), SQLITE_OK)
        }
        for i in 0..<unsubscribed {
            XCTAssertEqual(sqlite3_exec(db, "INSERT INTO podcasts (rss_url, is_subscribed) VALUES ('https://u/\(i)', 0)", nil, nil, nil), SQLITE_OK)
        }
        return url
    }

    /// A valid SQLite database with NO `podcasts` table — the schema an older
    /// returning user could carry. The COUNT scalars must fail their prepare and
    /// the error branch must log without crashing.
    private func makeDBWithoutPodcasts() throws -> URL {
        let url = try freshDBURL()
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(
            sqlite3_exec(db, "CREATE TABLE something_else (id INTEGER PRIMARY KEY)", nil, nil, nil),
            SQLITE_OK
        )
        return url
    }

    /// An empty 0-byte file at the earshot.db path: exists, but not a SQLite DB,
    /// so `sqlite3_open_v2` succeeds lazily and the first PRAGMA fails — the
    /// open-or-query error branch must log without crashing.
    private func makeZeroByteFile() throws -> URL {
        let url = try freshDBURL()
        try Data().write(to: url)
        return url
    }

    private func freshDBURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("earshot.db")
    }

    // MARK: missing / nil sources

    func testLogDiagnosticsWithMissingFileDoesNotCrash() {
        let ctx = TestStore.freshContext()
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)/nope.db")
        let service = FlutterMigrationService(context: ctx, databaseURL: missing)
        // Reaches the `guard exists` early return; must not throw or crash.
        service.logDiagnostics(trigger: "launch")
    }

    func testLogDiagnosticsWithNilURLDoesNotCrash() {
        let ctx = TestStore.freshContext()
        let service = FlutterMigrationService(context: ctx, databaseURL: nil)
        // Reaches the `guard let databaseURL` early return.
        service.logDiagnostics(trigger: "launch")
    }

    // MARK: zero-byte / corrupt file

    func testLogDiagnosticsWithZeroByteFileDoesNotCrash() throws {
        let ctx = TestStore.freshContext()
        let url = try makeZeroByteFile()
        let service = FlutterMigrationService(context: ctx, databaseURL: url)
        // File exists but isn't a valid DB; the first scalar query fails and the
        // error branch logs. Must not crash.
        service.logDiagnostics(trigger: "manual")
    }

    // MARK: healthy fixture

    func testLogDiagnosticsAgainstHealthyDatabaseDoesNotCrash() throws {
        let ctx = TestStore.freshContext()
        let url = try makeHealthyDB(subscribed: 3, unsubscribed: 2)
        let service = FlutterMigrationService(context: ctx, databaseURL: url)
        // Exercises the full happy path: file size, user_version, and both
        // COUNT scalars all succeed.
        service.logDiagnostics(trigger: "launch")
    }

    // MARK: missing podcasts table (the #430 prime suspect)

    func testLogDiagnosticsWhenPodcastsTableMissingDoesNotCrash() throws {
        let ctx = TestStore.freshContext()
        let url = try makeDBWithoutPodcasts()
        let service = FlutterMigrationService(context: ctx, databaseURL: url)
        // user_version succeeds; both COUNT scalars hit the missing-table error
        // branch in logScalar and log the SQLite code + message. Must not crash.
        service.logDiagnostics(trigger: "launch")
    }

    // MARK: both triggers are accepted

    func testLogDiagnosticsAcceptsBothTriggerTags() throws {
        let ctx = TestStore.freshContext()
        let url = try makeHealthyDB(subscribed: 1, unsubscribed: 0)
        let service = FlutterMigrationService(context: ctx, databaseURL: url)
        service.logDiagnostics(trigger: "launch")
        service.logDiagnostics(trigger: "manual")
    }
}
