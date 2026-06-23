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

/// One entry of the user's play queue read from the Flutter drift `queue_items`
/// table during migration, joined to `episodes` for the identity columns the new
/// store matches on. `position` is the Flutter ordering key; the restore re-adds
/// entries in ascending `position` so the queue keeps its order. Identified by
/// `guid` (preferred) or `audioURL` (fallback), the same as ``FlutterEpisode``.
struct FlutterQueueEntry: Sendable, Equatable {
    let guid: String?
    let audioURL: String?
    let position: Int
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

    private let context: ModelContext
    private let settings: AppSettingsStore
    private let databaseURL: URL?

    init(
        context: ModelContext,
        databaseURL: URL? = FlutterMigrationService.localDatabaseURL
    ) {
        self.context = context
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

    /// Whether the per-episode state overlay (played / inbox / position) and
    /// queue-order restore have completed successfully for this install. False
    /// until ``markEpisodeStateRestored()`` runs, so a migration that imported
    /// shells but failed (or predates) the overlay reads as "state still missing"
    /// and self-heals a local re-restore (#426).
    var episodeStateRestored: Bool {
        settings.bool(SettingsKey.flutterEpisodeStateRestored, default: false)
    }

    /// Records that the state overlay + queue restore finished without error, so
    /// the self-heal gate stops re-running them.
    func markEpisodeStateRestored() {
        settings.setBool(true, for: SettingsKey.flutterEpisodeStateRestored)
    }

    // MARK: Import status (#429)

    /// The outcome of the most recent import attempt, surfaced in Settings → Data.
    /// Defaults to ``MigrationStatus/notAttempted`` before any run.
    var status: MigrationStatus {
        settings.migrationStatus()
    }

    /// The timestamp of the most recent import attempt, or nil before any run.
    var lastAttemptDate: Date? {
        settings.migrationLastAttemptDate()
    }

    /// Stamps the start of an import attempt: records "now" as the last-attempt
    /// date so Settings → Data can show when the import last ran, even while it's
    /// in flight. The status is written separately on completion / failure.
    func recordImportAttempt(now: Date = .now) {
        settings.setMigrationLastAttemptDate(now)
    }

    /// Marks the most recent import run as having succeeded — shells imported and
    /// the state/queue overlay finished without throwing.
    func recordImportSucceeded() {
        settings.setMigrationStatus(.succeeded)
    }

    /// Marks the most recent import run as having failed — an import error or the
    /// state/queue overlay threw.
    func recordImportFailed() {
        settings.setMigrationStatus(.failed)
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
        settings.setBool(false, for: SettingsKey.flutterEpisodeStateRestored)
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

    /// Reads the user's play-queue order from the drift `queue_items` table,
    /// joined to `episodes` for the identity columns (`guid`, `audio_url`) the new
    /// store matches on, ordered by the Flutter `position`. Returns nil when the
    /// file/tables are missing or the query fails, so the caller no-ops rather
    /// than wiping the queue. Rows missing both identifiers are skipped (nothing
    /// to match them against) (#426).
    func readQueue() -> [FlutterQueueEntry]? {
        guard let databaseURL,
              FileManager.default.fileExists(atPath: databaseURL.path)
        else { return nil }

        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            AppLog.data.error("Migration: could not open export DB for queue")
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        let sql = """
        SELECT e.guid, e.audio_url, q.position
        FROM queue_items q
        JOIN episodes e ON e.id = q.episode_id
        ORDER BY q.position
        """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            AppLog.data.error("Migration: could not prepare queue query")
            return nil
        }
        defer { sqlite3_finalize(statement) }

        var entries: [FlutterQueueEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let guid = Self.column(statement, 0)
            let audioURL = Self.column(statement, 1)
            // No identifier means nothing to match against — skip it.
            if guid == nil && audioURL == nil { continue }
            entries.append(FlutterQueueEntry(
                guid: guid,
                audioURL: audioURL,
                position: Self.intColumn(statement, 2) ?? 0
            ))
        }
        return entries
    }

    // MARK: On-demand import (#429)

    /// Runs the full Flutter→SwiftUI import on demand, for the Settings → Data
    /// "Import older data" action. Reopens the migration gate and replays the same
    /// sequence the launch path runs: read subscriptions → import deduped show
    /// shells → mark complete → refresh every feed → overlay played/inbox/position
    /// state and queue order → mark the overlay restored. Stamps the attempt date
    /// up front and the status (succeeded / failed) on the way out, so the sheet
    /// can reflect the result.
    ///
    /// Idempotent and safe to call when already migrated: ``SubscriptionImporter``
    /// dedupes by feedURL and ``QueueImporter`` skips already-queued episodes, so a
    /// re-run adds no duplicate podcasts or queue entries. Returns true on success.
    ///
    /// If the Flutter database is missing or empty this is treated as a no-op
    /// success — there is simply nothing to import — so the user isn't shown a
    /// failure for a clean install. Any thrown error (refresh / overlay) records
    /// `.failed` and returns false rather than crashing.
    @MainActor
    @discardableResult
    func runManualImport(
        onProgress: (@MainActor @Sendable (_ completed: Int, _ total: Int) -> Void)? = nil
    ) async -> Bool {
        recordImportAttempt()

        // Temporary instrumentation for the returning-user data-loss report
        // (#430): snapshot earshot.db's on-disk state on every manual import.
        // Remove once diagnosed.
        logDiagnostics(trigger: "manual")

        // Reopen the gate so a previously-completed migration can re-run cleanly.
        resetForSelfHeal()

        guard let subs = readSubscriptions(), !subs.isEmpty else {
            // Nothing on disk to import. Not a failure — a clean install legitimately
            // has no older data. Record success so the UI shows "up to date".
            AppLog.data.info("Manual import: no Flutter data found; nothing to import")
            markComplete()
            recordImportSucceeded()
            return true
        }

        // Phase 1: deduped show shells (no episodes) on a background context.
        let importer = SubscriptionImporter(modelContainer: context.container)
        _ = await importer.importShells(subs) { completed, total in
            onProgress?(completed, total)
        }
        markComplete()

        // Phase 2: fill episodes, then overlay the user's per-episode state and
        // queue order. A thrown error here leaves the gate open for a later retry
        // and records the failure for the UI.
        do {
            _ = await SubscriptionRepository(context: context).refreshAll()
            if let flutterEpisodes = readEpisodes() {
                try EpisodeStateImporter(context: context).apply(flutterEpisodes)
            }
            if let flutterQueue = readQueue() {
                try QueueImporter(context: context).apply(flutterQueue)
            }
            markEpisodeStateRestored()
            recordImportSucceeded()
            AppLog.data.info("Manual import: completed successfully")
            return true
        } catch {
            recordImportFailed()
            AppLog.data.error("Manual import: failed during overlay: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: Diagnostics (#430 — build 120 returning-user data-loss investigation)

    /// Emits a one-shot, read-only snapshot of the Flutter database's on-disk
    /// state to the `migration` log channel so a returning-user "no data after
    /// upgrade" report can be diagnosed from Console.app on device, without a
    /// special build. Logs, in order:
    ///   1. whether `earshot.db` exists and its file size,
    ///   2. the drift schema version (`PRAGMA user_version`),
    ///   3. how many `podcasts` rows have `is_subscribed = 1` (and the total, to
    ///      tell an empty table apart from a missing/renamed column),
    ///   4. the SQLite result code + message on any failure.
    ///
    /// Temporary instrumentation: remove once #430 is diagnosed. Best-effort and
    /// side-effect free — every step is guarded, it never throws, mutates, or
    /// touches migration logic. Called on every run, automatic or manual, with a
    /// `trigger` tag (`"launch"` / `"manual"`) so the two paths are
    /// distinguishable in the log.
    func logDiagnostics(trigger: String) {
        guard let databaseURL else {
            AppLog.migration.error("Diagnostics [\(trigger, privacy: .public)]: no Documents directory; databaseURL is nil")
            return
        }

        let path = databaseURL.path
        let exists = FileManager.default.fileExists(atPath: path)
        let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int ?? 0
        AppLog.migration.info("Diagnostics [\(trigger, privacy: .public)]: earshot.db exists=\(exists, privacy: .public) size=\(size, privacy: .public) bytes path=\(path, privacy: .public)")

        guard exists else { return }

        var db: OpaquePointer?
        let openResult = sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil)
        guard openResult == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            AppLog.migration.error("Diagnostics [\(trigger, privacy: .public)]: open failed code=\(openResult, privacy: .public) msg=\(msg, privacy: .public)")
            sqlite3_close(db)
            return
        }
        defer { sqlite3_close(db) }

        logScalar(db, label: "user_version", sql: "PRAGMA user_version", trigger: trigger)
        logScalar(db, label: "podcasts is_subscribed=1 count", sql: "SELECT COUNT(*) FROM podcasts WHERE is_subscribed = 1", trigger: trigger)
        logScalar(db, label: "podcasts total count", sql: "SELECT COUNT(*) FROM podcasts", trigger: trigger)
    }

    /// Runs one single-value integer query for ``logDiagnostics(trigger:)`` and
    /// logs the result, or the SQLite error code + message when the statement
    /// can't be prepared or stepped (e.g. a missing table or column — the prime
    /// suspect for a returning user whose schema predates a queried column).
    private func logScalar(_ db: OpaquePointer?, label: String, sql: String, trigger: String) {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW
        else {
            let code = sqlite3_errcode(db)
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            AppLog.migration.error("Diagnostics [\(trigger, privacy: .public)]: \(label, privacy: .public) failed code=\(code, privacy: .public) msg=\(msg, privacy: .public)")
            return
        }
        let value = Int(sqlite3_column_int64(statement, 0))
        AppLog.migration.info("Diagnostics [\(trigger, privacy: .public)]: \(label, privacy: .public)=\(value, privacy: .public)")
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
