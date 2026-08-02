import Foundation
import SwiftData

/// A recovery condition detected while opening the store at launch, surfaced to
/// the UI (``StoreRecoveryScreen``) instead of ever silently destroying data
/// (issue #529).
enum StoreRecoveryState: Equatable {
    /// The on-disk store was written by a NEWER build than this one. The store is
    /// left completely untouched; the app runs on a temporary in-memory store and
    /// asks the user to update. Resetting here is NOT offered — it would destroy
    /// still-good data.
    case storeNewerThanApp

    /// The store could not be opened as any known schema (genuine corruption).
    /// The app runs on a temporary in-memory store and offers an explicit,
    /// user-consented "Reset local data" action — which backs the files up first.
    case corruptStore
}

/// The result of a launch-time store open: the container the app runs on, plus
/// any recovery condition the UI must surface.
struct StoreLoad {
    let container: ModelContainer
    let recovery: StoreRecoveryState?
}

/// Builds the app's `ModelContainer` from the versioned schema and migration
/// plan. The production path is defense-in-depth so a bad store can never become
/// a permanent dead end — and, since #529, never a cause of silent data loss
/// either (the hard-won lesson from the Flutter "loading -> Something went wrong"
/// migration bug and its SwiftData reincarnation — see issues #355 / #529 and
/// `.claude/rules/database-migrations.md`):
///
///   1. Open the persistent store, migrating V1→V2→V3 as needed (preserves data).
///   2. If the store is NEWER than this build (a downgrade), leave it completely
///      untouched, run on a temporary in-memory store, and ask the user to update
///      the app. Never delete a store this build simply can't read yet.
///   3. If the store is genuinely unreadable (corruption), run on a temporary
///      in-memory store and surface an explicit, user-consented reset — which
///      backs the files up before deleting anything. No silent wipe before
///      `runApp`.
enum ModelContainerFactory {

    /// The persistent store location. This is SwiftData's default path, named
    /// explicitly so the reset-on-failure step can delete the exact files.
    static var storeURL: URL {
        URL.applicationSupportDirectory.appending(path: "default.store")
    }

    /// The production load: opens the shared store, or returns a safe in-memory
    /// container plus the recovery state the UI must surface. Never deletes data.
    @MainActor
    static func makeShared() -> StoreLoad {
        load(at: storeURL)
    }

    /// Opens the store at `url`, classifying any failure into a recovery state
    /// instead of destroying the file. Factored out of ``makeShared()`` so tests
    /// can drive it against a temporary store.
    @MainActor
    static func load(at url: URL) -> StoreLoad {
        // 1. Normal path — open as the current schema (V3) through the migration
        //    plan: a V2 store is lightweight-migrated, and an original (V1) store
        //    is manually export/reimported (see StoreMigration), preserving data.
        do {
            let container = try StoreMigration.openOrMigrate(at: url)
            return StoreLoad(container: container, recovery: nil)
        } catch StoreOpenError.storeNewerThanApp(let underlying) {
            // 2. Downgrade — the store is NEWER than this build. Never touch it;
            //    run in-memory and tell the user to update the app.
            AppLog.data.error(
                "Store is newer than this build; leaving it intact and asking the user to update: \(underlying.localizedDescription, privacy: .public)"
            )
            return StoreLoad(container: inMemoryContainer(), recovery: .storeNewerThanApp)
        } catch {
            // 3. Genuine corruption — run in-memory and surface an explicit,
            //    user-consented reset (which backs up before deleting). No silent
            //    wipe here before `runApp`.
            AppLog.data.error(
                "Store is unreadable; leaving it intact pending user-consented reset: \(error.localizedDescription, privacy: .public)"
            )
            return StoreLoad(container: inMemoryContainer(), recovery: .corruptStore)
        }
    }

    /// An in-memory container the app runs on while a recovery screen is shown.
    /// Registers the real schema so the (empty) app tree renders normally.
    @MainActor
    private static func inMemoryContainer() -> ModelContainer {
        let schema = Schema(versionedSchema: EarshotSchemaV6.self)
        do {
            let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            return try ModelContainer(for: schema, configurations: memory)
        } catch {
            // An in-memory container should never fail to build; if it does,
            // there is nothing left to fall back to.
            fatalError("Failed to build in-memory fallback container: \(error)")
        }
    }

    /// Copies the store and its sidecar files to a timestamped backup directory in
    /// Application Support, returning the backup directory (or `nil` if there was
    /// nothing to copy or the copy failed). A wipe must always be recoverable
    /// (#529), so this is called immediately before any destructive reset.
    @discardableResult
    static func backupStoreFiles(at url: URL) -> URL? {
        let fm = FileManager.default
        let stamp = ISO8601DateFormatter().string(from: .now)
            .replacingOccurrences(of: ":", with: "-")
        let backupDir = url.deletingLastPathComponent()
            .appending(path: "store-backups", directoryHint: .isDirectory)
            .appending(path: stamp, directoryHint: .isDirectory)

        var copiedAny = false
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let source = url.deletingPathExtension()
                .appendingPathExtension("store" + suffix)
            guard fm.fileExists(atPath: source.path) else { continue }
            do {
                if !copiedAny {
                    try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
                }
                try fm.copyItem(at: source, to: backupDir.appending(path: source.lastPathComponent))
                copiedAny = true
            } catch {
                AppLog.data.error(
                    "Failed to back up store file \(source.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        if copiedAny {
            AppLog.data.info("Backed up store to \(backupDir.lastPathComponent, privacy: .public) before reset")
            return backupDir
        }
        return nil
    }

    /// User-consented recovery for a corrupt store: backs the files up, then
    /// deletes them so the next launch starts fresh. Returns the backup location
    /// (if any) for messaging. Never called without explicit user action (#529).
    @discardableResult
    static func resetCorruptStore(at url: URL) -> URL? {
        let backup = backupStoreFiles(at: url)
        removeStoreFiles(at: url)
        AppLog.data.info("Reset local data after backup; a fresh store will be created on next launch")
        return backup
    }

    /// An ephemeral in-memory container for tests and previews.
    static func makeInMemory() throws -> ModelContainer {
        let schema = Schema(versionedSchema: EarshotSchemaV6.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: config)
    }

    /// A container registering only a throwaway model, used by the app when it
    /// is launched purely as the XCTest host. This keeps the host from
    /// registering the real model types — which the unit tests register with
    /// their own in-memory containers — avoiding duplicate registration of the
    /// same `@Model` types across containers in one process.
    static func makeTestHostPlaceholder() -> ModelContainer {
        // Force-try: an in-memory container for a single trivial model cannot fail.
        try! ModelContainer(
            for: TestHostPlaceholder.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    /// Deletes the SQLite store at `url` and its sidecar files. Used by
    /// reset-on-failure and by the manual V1→V2 migration before recreating.
    static func removeStoreFiles(at url: URL) {
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let file = url.deletingPathExtension()
                .appendingPathExtension("store" + suffix)
            try? fm.removeItem(at: file)
        }
    }
}

/// A trivial model used only as the test-host's container schema. Intentionally
/// excluded from ``EarshotSchemaV2``.
@Model
final class TestHostPlaceholder {
    var n: Int
    init(n: Int = 0) { self.n = n }
}
