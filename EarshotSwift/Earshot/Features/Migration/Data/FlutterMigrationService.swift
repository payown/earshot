import Foundation
import SQLite3
import SwiftData

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
    private let subscriptions: SubscriptionRepository
    private let databaseURL: URL?

    init(
        context: ModelContext,
        databaseURL: URL? = FlutterMigrationService.localDatabaseURL,
        subscriptions: SubscriptionRepository? = nil
    ) {
        self.settings = AppSettingsStore(context: context)
        self.subscriptions = subscriptions ?? SubscriptionRepository(context: context)
        self.databaseURL = databaseURL
    }

    // MARK: Completion flag

    var isComplete: Bool {
        settings.bool(SettingsKey.flutterMigrationComplete, default: false)
    }

    func markComplete() {
        settings.setBool(true, for: SettingsKey.flutterMigrationComplete)
    }

    // MARK: Import

    /// Subscribes to every feed found in the exported drift DB. Returns the count
    /// of podcasts successfully subscribed. No-ops (returns 0) when the shared DB
    /// is missing. Per-feed failures are logged and skipped so one bad feed never
    /// aborts the rest.
    @discardableResult
    func importSubscriptions() async -> Int {
        guard let feeds = readFeedURLs(), !feeds.isEmpty else { return 0 }
        var imported = 0
        for url in feeds {
            do {
                _ = try await subscriptions.subscribe(feedURL: url)
                imported += 1
            } catch {
                AppLog.data.error(
                    "Migration: subscribe failed for \(url, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        AppLog.data.info("Migration: imported \(imported, privacy: .public) of \(feeds.count, privacy: .public) feed(s)")
        return imported
    }

    /// Reads non-empty `rss_url` values from the drift `podcasts` table. Returns
    /// nil if the file is missing or the database can't be opened/queried, so
    /// callers can distinguish "no shared data" from "zero podcasts".
    func readFeedURLs() -> [String]? {
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
        let sql = "SELECT rss_url FROM podcasts"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            AppLog.data.error("Migration: could not prepare podcasts query")
            return nil
        }
        defer { sqlite3_finalize(statement) }

        var urls: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let cString = sqlite3_column_text(statement, 0) else { continue }
            let value = String(cString: cString).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { urls.append(value) }
        }
        return urls
    }
}
