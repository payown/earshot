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

/// An episode's user-state read from the Flutter drift `episodes` table during
/// migration. Identifies the episode by `guid` (preferred) or `audioURL`
/// (fallback) and carries the state the new app can't re-derive from a live RSS
/// feed: whether it was played, whether it was sitting in the inbox, and how far
/// the user had listened. `pubDate` is carried for diagnostics/ordering. Note:
/// `inboxDismissed` here is the *derived* SwiftUI value — true unless the Flutter
/// row was genuinely in the inbox (`status == newEpisode && !inbox_dismissed`),
/// so a queued or expired Flutter episode never resurfaces in the new inbox.
struct FlutterEpisode: Sendable, Equatable {
    let guid: String?
    let audioURL: String?
    let isPlayed: Bool
    let inboxDismissed: Bool
    let pubDate: Date?
    let positionSeconds: Int?
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
/// Scope: subscriptions plus per-episode inbox/played state and playback
/// positions (#426). The feed list is restored first as labeled show shells;
/// once the live RSS feeds are fetched, `readEpisodes()` is matched against the
/// freshly-inserted episodes to restore what can't be re-derived from a feed —
/// played state, inbox membership, and listening positions. Queue order is still
/// not migrated.
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

    /// Records a launch where the import ran but the Flutter database yielded no
    /// subscriptions. Increments the attempt counter and, once the retry budget
    /// is exhausted, marks the migration complete so a genuinely empty install
    /// stops retrying. Below the budget the gate stays open so a transient
    /// first-launch miss recovers on the next launch. Returns true when it gave
    /// up (marked complete) this call (#426).
    @discardableResult
    func recordEmptyImportAttempt() -> Bool {
        let attempts = settings.int(SettingsKey.flutterMigrationAttempts, default: 0) + 1
        settings.setInt(attempts, for: SettingsKey.flutterMigrationAttempts)
        if MigrationGate.shouldGiveUp(attempts: attempts) {
            markComplete()
            AppLog.data.info("Migration: no Flutter data after \(attempts, privacy: .public) attempt(s); marking complete")
            return true
        }
        AppLog.data.info("Migration: no Flutter data on attempt \(attempts, privacy: .public); will retry next launch")
        return false
    }

    /// Reopens the gate for a self-heal re-import: clears the completion flag and
    /// the attempt counter so the import path runs again from scratch (#426).
    func resetForSelfHeal() {
        settings.setBool(false, for: SettingsKey.flutterMigrationComplete)
        settings.setInt(0, for: SettingsKey.flutterMigrationAttempts)
        AppLog.data.info("Migration: self-heal — store empty but Flutter data present; re-running import")
    }

    /// Whether the Flutter database exists and holds at least one subscription.
    /// Used by the self-heal check to confirm a recoverable library is still on
    /// disk before reopening the gate.
    func hasFlutterData() -> Bool {
        guard let subs = readSubscriptions() else { return false }
        return !subs.isEmpty
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

    /// Reads per-episode user state from the drift `episodes` table: identity
    /// (`guid`, `audio_url`), played state, inbox membership, pub date, and
    /// listening position. Returns nil when the file/table is missing or the
    /// query fails, so the caller can no-op rather than wipe state. Rows missing
    /// both identifiers are skipped (nothing to match them against).
    ///
    /// drift stores `DateTime` as Unix epoch seconds and `Bool` as 0/1 integers
    /// (the default, no `storeDateTimeAsText`), and `status` as the enum's String
    /// raw value (`played`, `newEpisode`, `inQueue`, `expired`). The derived
    /// `inboxDismissed` is true unless the row was genuinely in the inbox
    /// (`newEpisode` and not dismissed), so queued/expired episodes never
    /// resurface in the new inbox.
    func readEpisodes() -> [FlutterEpisode]? {
        guard let databaseURL,
              FileManager.default.fileExists(atPath: databaseURL.path)
        else { return nil }

        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            AppLog.data.error("Migration: could not open export DB for episodes")
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        let sql = """
        SELECT guid, audio_url, status, inbox_dismissed, pub_date, position_seconds
        FROM episodes
        """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            AppLog.data.error("Migration: could not prepare episodes query")
            return nil
        }
        defer { sqlite3_finalize(statement) }

        var episodes: [FlutterEpisode] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let guid = Self.column(statement, 0)
            let audioURL = Self.column(statement, 1)
            // No identifier means nothing to match against — skip it.
            if guid == nil && audioURL == nil { continue }

            let status = Self.column(statement, 2)
            let rawDismissed = (Self.intColumn(statement, 3) ?? 0) != 0
            let isPlayed = status == "played"
            // Only a genuinely-in-inbox Flutter row stays in the new inbox.
            let wasInInbox = status == "newEpisode" && !rawDismissed

            episodes.append(FlutterEpisode(
                guid: guid,
                audioURL: audioURL,
                isPlayed: isPlayed,
                inboxDismissed: !wasInInbox,
                pubDate: Self.intColumn(statement, 4).map { Date(timeIntervalSince1970: TimeInterval($0)) },
                positionSeconds: Self.intColumn(statement, 5)
            ))
        }
        return episodes
    }

    /// Trimmed text for a column, or nil when NULL/blank.
    private static func column(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, index) else { return nil }
        let value = String(cString: cString).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Integer value for a column, or nil when the cell is SQL NULL.
    private static func intColumn(_ statement: OpaquePointer?, _ index: Int32) -> Int? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(statement, index))
    }
}
