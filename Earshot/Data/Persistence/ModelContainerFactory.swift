import Foundation
import SwiftData

/// A recovery condition detected while opening the store at launch, surfaced to
/// the UI (``StoreRecoveryScreen``) instead of ever silently destroying data
/// (issue #529).
enum StoreRecoveryState: Equatable {
    /// The on-disk store was written by a NEWER build than this one. The store is
    /// left completely untouched and the recovery screen asks the user to update.
    /// Resetting here is NOT offered — it would destroy still-good data.
    case storeNewerThanApp

    /// The store predates V6, Earshot's first public App Store schema. It is
    /// preserved until the user explicitly chooses the backed-up reset path.
    case storePredatesSupportedSchema

    /// The store could not be opened as any known schema (genuine corruption). The
    /// recovery screen offers an explicit, user-consented "Reset local data"
    /// action — which backs the files up first.
    case corruptStore
}

/// The result of a launch-time store open. Recovery deliberately carries no
/// fallback container: ``StoreRecoveryScreen`` does not use SwiftData, and the
/// app must never construct its data-bound root against a temporary store before
/// installing the real one (#781).
enum StoreLoad {
    case ready(ModelContainer)
    case recovery(StoreRecoveryState)
}

/// Builds the app's `ModelContainer` from the versioned schema and migration
/// plan. The production path is defense-in-depth so a bad store can never become
/// a permanent dead end — and, since #529, never a cause of silent data loss
/// either (the hard-won lesson from the Flutter "loading -> Something went wrong"
/// migration bug and its SwiftData reincarnation — see issues #355 / #529 and
/// `.claude/rules/database-migrations.md`):
///
///   1. Open a V6-or-newer persistent store through the restartable split migration.
///      Pre-V6 stores are preserved and surfaced with OPML recovery guidance.
///   2. If the store is NEWER than this build (a downgrade), leave it completely
///      untouched and ask the user to update the app. Never delete a store this
///      build simply can't read yet.
///   3. If the store is genuinely unreadable (corruption), surface an explicit,
///      user-consented reset — which backs the files up before deleting anything.
///      No silent wipe before the root UI appears.
enum ModelContainerFactory {

    /// The persistent store location. This is SwiftData's default path, named
    /// explicitly so the reset-on-failure step can delete the exact files.
    static var storeURL: URL {
        URL.applicationSupportDirectory.appending(path: "default.store")
    }

    /// The production load: opens the shared store, or returns the recovery state
    /// the UI must surface without constructing a fallback container. Never
    /// deletes data.
    @MainActor
    static func makeShared() -> StoreLoad {
        load(at: storeURL)
    }

    /// Opens the store at `url`, classifying any failure into a recovery state
    /// instead of destroying the file. Factored out of ``makeShared()`` so tests
    /// can drive it against a temporary store.
    @MainActor
    static func load(at url: URL) -> StoreLoad {
        // 1. Normal path — open the current split store or migrate from the
        //    supported V6 floor. StoreMigration classifies unsupported pre-V6
        //    data separately from corruption and newer-than-app downgrades.
        do {
            let container = try StoreMigration.openOrMigrate(at: url)
            return .ready(container)
        } catch StoreOpenError.storeNewerThanApp(let underlying) {
            // 2. Downgrade — the store is NEWER than this build. Never touch it;
            //    show recovery and tell the user to update the app.
            AppLog.data.error(
                "Store is newer than this build; leaving it intact and asking the user to update: \(underlying.localizedDescription, privacy: .public)"
            )
            return .recovery(.storeNewerThanApp)
        } catch StoreOpenError.storePredatesSupportedSchema(let majorVersion) {
            AppLog.data.error(
                "Store schema V\(majorVersion) predates the supported V6 floor; leaving it intact pending user-consented reset"
            )
            return .recovery(.storePredatesSupportedSchema)
        } catch {
            // 3. Genuine corruption — surface an explicit, user-consented reset
            //    (which backs up before deleting). No silent wipe here before the
            //    recovery UI appears.
            AppLog.data.error(
                "Store is unreadable; leaving it intact pending user-consented reset: \(error.localizedDescription, privacy: .public)"
            )
            return .recovery(.corruptStore)
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
        _ = backupStoreFiles(at: StoreMigration.localStoreURL(for: url))
        removeStoreFiles(at: url)
        removeStoreFiles(at: StoreMigration.localStoreURL(for: url))
        AppLog.data.info("Reset local data after backup; a fresh store will be created on next launch")
        return backup
    }

    /// An ephemeral in-memory container for tests and previews.
    static func makeInMemory() throws -> ModelContainer {
        let schema = Schema(versionedSchema: EarshotSchemaV9.self)
        let mirrored = ModelConfiguration(
            "FutureMirrored", schema: Schema(EarshotSchemaV9.mirroredModels),
            isStoredInMemoryOnly: true, cloudKitDatabase: .none
        )
        let local = ModelConfiguration(
            "DeviceLocal", schema: Schema(EarshotSchemaV9.localModels),
            isStoredInMemoryOnly: true, cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: mirrored, local)
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
    /// user-consented recovery and restartable local-store reconstruction.
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
