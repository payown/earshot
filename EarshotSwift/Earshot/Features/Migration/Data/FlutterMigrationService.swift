import Foundation
import SQLite3
import SwiftData

/// A subscription read from the Flutter drift database during migration: the feed
/// URL plus display metadata so the imported Library row is labeled immediately,
/// before its episodes are fetched.
struct FlutterSubscription: Sendable, Equatable {
    let rssURL: String
    let title: String?
    let author: String?
    let artworkURL: String?
}

/// One-time import of the user's subscriptions from a previous (Flutter) install
/// that shared this bundle id's container.
///
/// The SwiftUI app now ships under the same bundle id (`media.payown.earshot`) as
/// the old Flutter app, so an over-the-top update keeps the same sandbox and the
/// Flutter drift database is still sitting at `Documents/earshot.db`. We read its
/// `podcasts` table directly via SQLite3 on first launch — no App Group,
/// entitlement, or Flutter-side export writer needed.
///
/// Scope: subscriptions only. Queue order, played state, and playback positions
/// are intentionally not migrated — getting the feed list right is what matters
/// to users, and every other field is re-derived from the live RSS feed on
/// subscribe.
///
/// Safety: if the database is absent or unreadable (the normal case for a fresh
/// install) every method no-ops quietly. Every SQLite call goes through guarded
/// returns — no `fatalError`, no force-unwrap, no crash on a tester's real data.
@MainActor
final class FlutterMigrationService {
    /// The Flutter app's drift database, left in the shared sandbox after an
    /// over-the-top update. drift writes it to the Documents directory
    /// (`getApplicationDocumentsDirectory()`), so we read it from the same place.
    /// `nonisolated` so it can serve as a default argument (evaluated outside the
    /// main actor); it only touches `FileManager`, which is thread-safe.
    nonisolated static var localDatabaseURL: URL? {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("earshot.db")
    }

    private let settings: AppSettingsStore
    private let databaseURL: URL?

    init(
        context: ModelContext,
        databaseURL: URL? = FlutterMigrationService.localDatabaseURL
    ) {
        self.settings = AppSettingsStore(context: context)
        self.databaseURL = databaseURL
    }

    // MARK: Completion flag

    var isComplete: Bool {
        settings.bool(SettingsKey.flutterMigrationComplete, default: false)
    }

    func markComplete() {
        settings.setBool(true, for: SettingsKey.flutterMigrationComplete)
    }

    // MARK: Read

    /// Reads subscriptions (feed URL + display metadata) from the drift `podcasts`
    /// table. Returns nil if the file is missing or the database can't be
    /// opened/queried, so callers can distinguish "no shared data" from "zero
    /// podcasts". Rows with a blank `rss_url` are skipped; NULL/blank metadata
    /// columns (older drift rows) become nil rather than failing.
    func readSubscriptions() -> [FlutterSubscription]? {
        guard let databaseURL,
              FileManager.default.fileExists(atPath: databaseURL.path)
        else { return nil }

        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            AppLog.data.error("Migration: could not open export DB")
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        let sql = "SELECT rss_url, title, author, artwork_url FROM podcasts"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            AppLog.data.error("Migration: could not prepare podcasts query")
            return nil
        }
        defer { sqlite3_finalize(statement) }

        var subs: [FlutterSubscription] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let rss = Self.column(statement, 0) else { continue }
            subs.append(FlutterSubscription(
                rssURL: rss,
                title: Self.column(statement, 1),
                author: Self.column(statement, 2),
                artworkURL: Self.column(statement, 3)
            ))
        }
        return subs
    }

    /// Non-empty feed URLs only. Kept for callers/tests that just need the list.
    func readFeedURLs() -> [String]? {
        readSubscriptions()?.map(\.rssURL)
    }

    /// Trimmed text for a column, or nil when NULL/blank.
    private static func column(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, index) else { return nil }
        let value = String(cString: cString).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
