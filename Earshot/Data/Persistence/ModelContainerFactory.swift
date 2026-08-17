import Foundation
import SwiftData

/// A recovery condition detected while opening the store at launch, surfaced to
/// the UI (``StoreRecoveryScreen``) instead of ever silently destroying data
/// (issue #529).
enum StoreRecoveryState: Equatable {
    /// Migration stopped for an operational reason such as low storage. The
    /// library remains intact and retryable, so destructive reset is never offered.
    case migrationFailed

    /// Earshot deliberately did not begin migration because it could not create
    /// or retain the verified safety snapshot and measured working-space margin.
    case backupUnavailable(requiredFreeSpaceBytes: Int64?, availableFreeSpaceBytes: Int64?)

    /// The on-disk store was written by a NEWER build than this one. The store is
    /// left completely untouched and the recovery screen asks the user to update.
    /// Resetting here is NOT offered — it would destroy still-good data.
    case storeNewerThanApp

    /// The store predates V5, Earshot's first public App Store schema. It is
    /// preserved until the user explicitly chooses recovery. Erasure is offered
    /// only when this carries a verified, restorable snapshot.
    case storePredatesSupportedSchema(backup: MigrationBackupDescriptor?)

    /// The store could not be opened as any known schema (genuine corruption).
    /// Destructive recovery remains unavailable unless a previously verified,
    /// restorable snapshot exists.
    case corruptStore

    var isBackupUnavailable: Bool {
        if case .backupUnavailable = self { return true }
        return false
    }

    var recoveryBackup: MigrationBackupDescriptor? {
        if case .storePredatesSupportedSchema(let backup) = self { return backup }
        return nil
    }

    var isUnsupportedSchema: Bool {
        if case .storePredatesSupportedSchema = self { return true }
        return false
    }
}

/// The result of a launch-time store open. Recovery deliberately carries no
/// fallback container: ``StoreRecoveryScreen`` does not use SwiftData, and the
/// app must never construct its data-bound root against a temporary store before
/// installing the real one (#781).
enum StoreLoad {
    case ready(ModelContainer)
    /// The source store was readable, but migration could not complete because
    /// of an operational condition. This is intentionally not recovery: no
    /// destructive reset should be offered for storage or file-operation errors.
    case migrationFailed
    case recovery(StoreRecoveryState)
}

/// Builds the app's `ModelContainer` from the versioned schema and migration
/// plan. The production path is defense-in-depth so a bad store can never become
/// a permanent dead end — and, since #529, never a cause of silent data loss
/// either (the hard-won lesson from the Flutter "loading -> Something went wrong"
/// migration bug and its SwiftData reincarnation — see issues #355 / #529 and
/// `.claude/rules/database-migrations.md`):
///
///   1. Open a V5-or-newer persistent store through the restartable split migration.
///      Pre-V5 stores are preserved and surfaced with explicit recovery.
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

    /// Whether this device already has any file from the primary store set.
    /// A genuine fresh install can skip the preparation UI entirely: creating
    /// an empty V10 store is asynchronous but is not a migration, so briefly
    /// focusing a progress screen would add noise before onboarding (#781).
    static var hasExistingStoreFiles: Bool {
        hasStoreFiles(at: storeURL)
    }

    static func hasStoreFiles(at url: URL) -> Bool {
        let fm = FileManager.default
        let storeURLs = [url, StoreMigration.localStoreURL(for: url)]
        return storeURLs.contains { candidateURL in
            ["", "-wal", "-shm", "-journal"].contains { suffix in
                let file = candidateURL.deletingPathExtension()
                    .appendingPathExtension("store" + suffix)
                return fm.fileExists(atPath: file.path)
            }
        }
    }

    /// The production load: opens the shared store, or returns the recovery state
    /// the UI must surface without constructing a fallback container. Never
    /// deletes data.
    @MainActor
    static func makeShared() -> StoreLoad {
        load(at: storeURL)
    }

    /// Production asynchronous load. The actor-owned migration engine keeps all
    /// synchronous SwiftData/Core Data work off the main actor while preserving
    /// the same failure classification as ``load(at:)``. Progress is consumed by
    /// the launch coordinator through the engine's `AsyncStream`.
    static func makeShared(using engine: StoreMigrationEngine) async -> StoreLoad {
        await makeShared(using: engine, at: storeURL)
    }

    /// Test seam using the same migration/open path against a disposable store.
    static func makeShared(using engine: StoreMigrationEngine, at url: URL) async -> StoreLoad {
        do {
            let container = try await engine.openOrMigrate(at: url)
            MigrationBackupManager.noteSuccessfulTargetOpen(
                at: url, targetSchemaMajor: MigrationBackupManager.targetSchemaMajor
            )
            return .ready(container)
        } catch StoreMigrationFailure.backupUnavailable(let underlying) {
            AppLog.data.error(
                "Store migration did not start because its safety backup or working margin was unavailable: \(underlying.localizedDescription, privacy: .public)"
            )
            return .recovery(.backupUnavailable(
                requiredFreeSpaceBytes: storageAmounts(from: underlying)?.required,
                availableFreeSpaceBytes: storageAmounts(from: underlying)?.available
            ))
        } catch StoreMigrationFailure.operational(let underlying) {
            AppLog.data.error(
                "Store migration could not complete; leaving data intact for retry: \(underlying.localizedDescription, privacy: .public)"
            )
            return .migrationFailed
        } catch StoreOpenError.storeNewerThanApp(let underlying) {
            AppLog.data.error(
                "Store is newer than this build; leaving it intact and asking the user to update: \(underlying.localizedDescription, privacy: .public)"
            )
            return .recovery(.storeNewerThanApp)
        } catch StoreOpenError.storePredatesSupportedSchema(let majorVersion) {
            AppLog.data.error(
                "Store schema V\(majorVersion) predates the supported V5 floor; leaving it intact pending user-consented recovery"
            )
            let backup = await Task.detached {
                MigrationBackupManager.latestRestorableBackup(at: storeURL)
            }.value
            return .recovery(.storePredatesSupportedSchema(backup: backup))
        } catch {
            AppLog.data.error(
                "Store is unreadable; leaving it intact pending user-consented reset: \(error.localizedDescription, privacy: .public)"
            )
            return .recovery(.corruptStore)
        }
    }

    /// Opens the store at `url`, classifying any failure into a recovery state
    /// instead of destroying the file. Factored out of ``makeShared()`` so tests
    /// can drive it against a temporary store.
    @MainActor
    static func load(at url: URL) -> StoreLoad {
        // 1. Normal path — open the current split store or migrate from the
        //    supported V5 floor. StoreMigration classifies unsupported pre-V5
        //    data separately from corruption and newer-than-app downgrades.
        do {
            let container = try StoreMigration.openOrMigrate(at: url)
            MigrationBackupManager.noteSuccessfulTargetOpen(
                at: url, targetSchemaMajor: MigrationBackupManager.targetSchemaMajor
            )
            return .ready(container)
        } catch StoreMigrationFailure.backupUnavailable(let underlying) {
            AppLog.data.error(
                "Store migration did not start because its safety backup or working margin was unavailable: \(underlying.localizedDescription, privacy: .public)"
            )
            return .recovery(.backupUnavailable(
                requiredFreeSpaceBytes: storageAmounts(from: underlying)?.required,
                availableFreeSpaceBytes: storageAmounts(from: underlying)?.available
            ))
        } catch StoreMigrationFailure.operational(let underlying) {
            AppLog.data.error(
                "Store migration could not complete; leaving data intact for retry: \(underlying.localizedDescription, privacy: .public)"
            )
            return .migrationFailed
        } catch StoreOpenError.storeNewerThanApp(let underlying) {
            // 2. Downgrade — the store is NEWER than this build. Never touch it;
            //    show recovery and tell the user to update the app.
            AppLog.data.error(
                "Store is newer than this build; leaving it intact and asking the user to update: \(underlying.localizedDescription, privacy: .public)"
            )
            return .recovery(.storeNewerThanApp)
        } catch StoreOpenError.storePredatesSupportedSchema(let majorVersion) {
            AppLog.data.error(
                "Store schema V\(majorVersion) predates the supported V5 floor; leaving it intact pending user-consented recovery"
            )
            return .recovery(.storePredatesSupportedSchema(
                backup: MigrationBackupManager.latestRestorableBackup(at: url)
            ))
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

    static func storageAmounts(from error: Error) -> (required: Int64, available: Int64)? {
        guard let backupError = error as? MigrationBackupError else { return nil }
        guard case .insufficientStorage(let requiredBytes, let availableBytes) = backupError else {
            return nil
        }
        return (requiredBytes, availableBytes)
    }

    /// Copies legacy store files to a timestamped directory. This exists only so
    /// backups made by older builds remain discoverable; it is intentionally not
    /// a destructive-recovery prerequisite because individual file copies can
    /// fail. New erasure uses a validated snapshot from
    /// ``MigrationBackupManager`` instead.
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

    /// User-consented erasure. The offered snapshot is revalidated immediately
    /// before deletion and retained afterward. A missing, partial, unrelated, or
    /// damaged backup fails closed without removing any store file.
    @discardableResult
    static func eraseLibrary(
        at url: URL,
        preserving backup: MigrationBackupDescriptor
    ) throws -> URL {
        try MigrationBackupManager.eraseLibrary(at: url, preserving: backup)
        AppLog.data.info(
            "Erased the library after revalidating its retained safety backup; a fresh store will be created on next launch"
        )
        return backup.directoryURL
    }

    /// An ephemeral in-memory container for tests and previews.
    static func makeInMemory() throws -> ModelContainer {
        let schema = Schema(versionedSchema: EarshotSchemaV10.self)
        let mirrored = ModelConfiguration(
            "FutureMirrored", schema: Schema(EarshotSchemaV10.mirroredModels),
            isStoredInMemoryOnly: true, cloudKitDatabase: .none
        )
        let local = ModelConfiguration(
            "DeviceLocal", schema: Schema(EarshotSchemaV10.localModels),
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

    /// Removes one specific store family and fails if any member cannot be
    /// removed. Account recovery uses this stricter form so it can never reopen
    /// a previous iCloud account's projection after silently ignoring an I/O
    /// error. Sibling application stores are outside the resolved file set.
    static func removeStoreFilesVerifiably(at url: URL) throws {
        let fm = FileManager.default
        let files = ["", "-wal", "-shm", "-journal"].map { suffix in
            url.deletingPathExtension().appendingPathExtension("store" + suffix)
        }
        for file in files where fm.fileExists(atPath: file.path) {
            try fm.removeItem(at: file)
        }
        guard !files.contains(where: { fm.fileExists(atPath: $0.path) }) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

}

/// A trivial model used only as the test-host's container schema. Intentionally
/// excluded from ``EarshotSchemaV2``.
@Model
final class TestHostPlaceholder {
    var n: Int = 0
    init(n: Int = 0) { self.n = n }
}
