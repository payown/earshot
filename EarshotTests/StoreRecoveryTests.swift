import CoreData
import XCTest
import SwiftData
@testable import Earshot

/// Guards the #529 safety contract: a store this build can't open is NEVER
/// silently deleted. A newer-than-app store is left completely intact; a genuinely
/// unreadable store can only be erased while a verified backup is retained. These
/// run against a real
/// on-disk store in a temp directory, the way a device upgrade/downgrade does.
@MainActor
final class StoreRecoveryTests: XCTestCase {
    nonisolated(unsafe) private var dir: URL!
    nonisolated(unsafe) private var storeURL: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("store-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storeURL = dir.appendingPathComponent("default.store")
    }

    override func tearDownWithError() throws {
        MigrationBackupManager.injectedRestoreFailureAfterQuarantine = false
        MigrationBackupManager.injectedQuarantineCleanupFailure = false
        MigrationBackupManager.injectedEraseFailureAfterMoveCount = nil
        MigrationBackupManager.injectedEraseRollbackFailure = false
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func storeExists() -> Bool {
        FileManager.default.fileExists(atPath: storeURL.path)
    }

    private func v6Container() throws -> ModelContainer {
        let schema = Schema(versionedSchema: EarshotSchemaV6.self)
        return try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(
                schema: schema, url: storeURL, cloudKitDatabase: .none
            )
        )
    }

    private func seedV6RecoveryStore() throws {
        try autoreleasepool {
            let container = try v6Container()
            let podcast = EarshotSchemaV5.Podcast(
                feedURL: "https://backup.example/feed", title: "Backup Fixture"
            )
            let episode = EarshotSchemaV5.Episode(
                guid: "kept", title: "Kept Episode", audioURL: "https://backup.example/1.mp3"
            )
            episode.podcast = podcast
            container.mainContext.insert(podcast)
            container.mainContext.insert(episode)
            try container.mainContext.save()
        }
    }

    private func podcastCount() throws -> Int {
        try autoreleasepool {
            let container = try v6Container()
            return try container.mainContext.fetchCount(FetchDescriptor<EarshotSchemaV5.Podcast>())
        }
    }

    private func episodeCount() throws -> Int {
        try autoreleasepool {
            let container = try v6Container()
            return try container.mainContext.fetchCount(FetchDescriptor<EarshotSchemaV5.Episode>())
        }
    }

    private func addCurrentPodcast() throws {
        try autoreleasepool {
            let container = try v6Container()
            container.mainContext.insert(EarshotSchemaV5.Podcast(
                feedURL: "https://current.example/feed", title: "Current Fixture"
            ))
            try container.mainContext.save()
        }
    }

    /// Writes a store at a schema NEWER than the app's current V4 (an extra
    /// entity), simulating a device whose data came from a later build.
    private func seedNewerStore() throws {
        try autoreleasepool {
            let schema = Schema(versionedSchema: SchemaVFutureFixture.self)
            let container = try ModelContainer(
                for: schema,
                configurations: ModelConfiguration(
                    schema: schema, url: storeURL, cloudKitDatabase: .none
                )
            )
            container.mainContext.insert(FutureOnlyEntity(value: 1))
            try container.mainContext.save()
        }
    }

    // MARK: Newer-than-app classification

    /// The classifier that decides "this store is newer than the app" (and so must
    /// never be deleted). Exercised directly with the CoreData errors a real
    /// downgrade produces, because a genuine version-hash mismatch on an existing
    /// entity can't be fabricated from a single-module test schema — only a real
    /// V(n)→V(n+1) model change (as in the #524 incident) throws it on device.
    func testIndicatesNewerStoreDetectsIncompatibleVersionErrors() {
        let incompatible = NSError(
            domain: NSCocoaErrorDomain,
            code: NSPersistentStoreIncompatibleVersionHashError
        )
        XCTAssertTrue(StoreMigration.indicatesNewerStore(incompatible))

        let missingMapping = NSError(
            domain: NSCocoaErrorDomain,
            code: NSMigrationMissingMappingModelError
        )
        XCTAssertTrue(StoreMigration.indicatesNewerStore(missingMapping))

        // SwiftData wraps the CoreData error — the whole chain must be walked.
        let wrapped = NSError(
            domain: "SwiftDataError",
            code: 1,
            userInfo: [NSUnderlyingErrorKey: incompatible]
        )
        XCTAssertTrue(StoreMigration.indicatesNewerStore(wrapped))

        // Unrelated failures (e.g. genuine corruption) are NOT "newer".
        let corrupt = NSError(domain: NSSQLiteErrorDomain, code: 26)
        XCTAssertFalse(StoreMigration.indicatesNewerStore(corrupt))
    }

    func testOperationalFailuresRemainDistinctFromUnreadableStoreErrors() {
        let outOfSpace = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileWriteOutOfSpaceError
        )
        XCTAssertTrue(StoreMigration.indicatesOperationalFailure(outOfSpace))

        let sqliteFull = NSError(domain: NSSQLiteErrorDomain, code: 13)
        let wrapped = NSError(
            domain: "SwiftDataError",
            code: 1,
            userInfo: [NSUnderlyingErrorKey: sqliteFull]
        )
        XCTAssertTrue(StoreMigration.indicatesOperationalFailure(wrapped))

        let corrupt = NSError(domain: NSSQLiteErrorDomain, code: 11)
        let notADatabase = NSError(domain: NSSQLiteErrorDomain, code: 26)
        XCTAssertFalse(StoreMigration.indicatesOperationalFailure(corrupt))
        XCTAssertFalse(StoreMigration.indicatesOperationalFailure(notADatabase))
    }

    /// A benign forward schema (an added entity) is lightweight-reversible, so it
    /// opens rather than throwing — but the guarantee that still matters is that
    /// the store on disk is never deleted by opening it with an older build.
    func testBenignNewerStoreIsNeverDeleted() throws {
        try seedNewerStore()
        XCTAssertTrue(storeExists())
        let before = try Data(contentsOf: storeURL)

        let load = ModelContainerFactory.load(at: storeURL)
        guard case .recovery(let recovery) = load else {
            return XCTFail("a newer store must return recovery without a container")
        }
        XCTAssertEqual(recovery, .storeNewerThanApp)
        XCTAssertTrue(storeExists(), "opening a newer store must never delete it")
        XCTAssertEqual(try Data(contentsOf: storeURL), before, "downgrade detection must not rewrite the store")
    }

    // MARK: Corrupt store

    func testLoadOnCorruptStoreSurfacesRecoveryAndKeepsStore() throws {
        // Garbage bytes: openable as neither V3 nor V1, and not a version mismatch.
        try Data([0x00, 0x01, 0x02, 0x03, 0xFF]).write(to: storeURL)

        let load = ModelContainerFactory.load(at: storeURL)
        guard case .recovery(let recovery) = load else {
            return XCTFail("corrupt data must return recovery without a container")
        }
        XCTAssertEqual(recovery, .corruptStore)
        XCTAssertTrue(storeExists(), "load() must not wipe without user consent")
    }

    /// The destructive recovery gate revalidates a complete snapshot and keeps
    /// it after every live store file is removed.
    func testEraseLibraryRequiresAndRetainsVerifiedBackup() throws {
        try seedV6RecoveryStore()
        let backup = try MigrationBackupManager.prepareVerifiedBackup(at: storeURL)
        let wal = storeURL.deletingPathExtension().appendingPathExtension("store-wal")
        try Data([0xAA]).write(to: wal)

        let retained = try ModelContainerFactory.eraseLibrary(
            at: storeURL, preserving: backup
        )

        let fm = FileManager.default
        XCTAssertTrue(
            fm.fileExists(atPath: retained.appending(path: "default.store").path),
            "the verified snapshot must remain after erasure"
        )
        XCTAssertFalse(storeExists(), "the original store is removed after backup")
        XCTAssertFalse(fm.fileExists(atPath: wal.path), "sidecars are removed after backup")
        XCTAssertNotNil(MigrationBackupManager.latestRestorableBackup(at: storeURL))
    }

    func testDamagedBackupBlocksErasureWithoutChangingLiveStore() throws {
        try seedV6RecoveryStore()
        let backup = try MigrationBackupManager.prepareVerifiedBackup(at: storeURL)
        let before = try Data(contentsOf: storeURL)
        try Data([0x00, 0x01]).write(
            to: backup.directoryURL.appending(path: "default.store")
        )

        XCTAssertThrowsError(try ModelContainerFactory.eraseLibrary(
            at: storeURL, preserving: backup
        ))

        XCTAssertTrue(storeExists())
        XCTAssertEqual(try Data(contentsOf: storeURL), before)
    }

    func testInterruptedErasureRestoresLiveStoreOnNextLaunch() throws {
        try seedV6RecoveryStore()
        let backup = try MigrationBackupManager.prepareVerifiedBackup(at: storeURL)
        let localURL = StoreMigration.localStoreURL(for: storeURL)
        let localBytes = Data([0xA1, 0xB2, 0xC3])
        try localBytes.write(to: localURL)
        MigrationBackupManager.injectedEraseFailureAfterMoveCount = 1
        MigrationBackupManager.injectedEraseRollbackFailure = true

        XCTAssertThrowsError(try ModelContainerFactory.eraseLibrary(
            at: storeURL, preserving: backup
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: MigrationBackupManager.backupRoot(for: storeURL)
                .appending(path: "erase-transaction.json").path
        ))

        MigrationBackupManager.injectedEraseFailureAfterMoveCount = nil
        MigrationBackupManager.injectedEraseRollbackFailure = false
        try MigrationBackupManager.recoverInterruptedErasure(at: storeURL)

        XCTAssertEqual(try podcastCount(), 1)
        XCTAssertEqual(try episodeCount(), 1)
        XCTAssertEqual(try Data(contentsOf: localURL), localBytes)
        XCTAssertNotNil(MigrationBackupManager.latestRestorableBackup(at: storeURL))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: MigrationBackupManager.backupRoot(for: storeURL)
                .appending(path: "erase-transaction.json").path
        ))
    }

    // MARK: Verified migration backup and restore

    func testVerifiedSnapshotRestoresV6AndQuarantinesPartialSplitFiles() throws {
        try seedV6RecoveryStore()
        let backup = try MigrationBackupManager.prepareVerifiedBackup(at: storeURL)
        XCTAssertEqual(backup.sourceSchemaMajor, 6)
        XCTAssertEqual(backup.targetSchemaMajor, 11)
        XCTAssertEqual(backup.format, .verifiedSnapshot)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: backup.directoryURL.appending(path: "manifest.json").path
            )
        )

        ModelContainerFactory.removeStoreFiles(at: storeURL)
        try Data([0xFF, 0x00]).write(to: storeURL)
        let localURL = StoreMigration.localStoreURL(for: storeURL)
        try Data([0xAA]).write(to: localURL)

        try MigrationBackupManager.restore(backup, at: storeURL)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: localURL.path),
            "a partial local store must not be merged into the restored source"
        )
        XCTAssertEqual(try podcastCount(), 1)
        XCTAssertEqual(try episodeCount(), 1)
        XCTAssertNotNil(MigrationBackupManager.latestRecordedBackup(at: storeURL))
    }

    func testLegacyTimestampedBackupAlreadyOnDeviceCanBeRestored() throws {
        try seedV6RecoveryStore()
        let legacyDirectory = try XCTUnwrap(ModelContainerFactory.backupStoreFiles(at: storeURL))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: legacyDirectory.appending(path: "manifest.json").path
            )
        )
        ModelContainerFactory.removeStoreFiles(at: storeURL)
        try Data([0x00, 0x01, 0xFF]).write(to: storeURL)

        let legacy = try XCTUnwrap(MigrationBackupManager.latestRestorableBackup(at: storeURL))
        XCTAssertEqual(legacy.format, .legacyStoreSet)
        try MigrationBackupManager.restore(legacy, at: storeURL)

        XCTAssertEqual(try episodeCount(), 1)
    }

    func testFailedRestoreRollsBackEveryCurrentStoreFile() throws {
        try seedV6RecoveryStore()
        let backup = try MigrationBackupManager.prepareVerifiedBackup(at: storeURL)

        try addCurrentPodcast()
        let localURL = StoreMigration.localStoreURL(for: storeURL)
        let partialLocal = Data([0xA1, 0xB2, 0xC3])
        try partialLocal.write(to: localURL)

        MigrationBackupManager.injectedRestoreFailureAfterQuarantine = true
        XCTAssertThrowsError(try MigrationBackupManager.restore(backup, at: storeURL))
        MigrationBackupManager.injectedRestoreFailureAfterQuarantine = false

        XCTAssertEqual(try Data(contentsOf: localURL), partialLocal)
        XCTAssertEqual(try podcastCount(), 2,
            "a failed restore must put the complete pre-restore store set back")
        XCTAssertNotNil(MigrationBackupManager.latestRestorableBackup(at: storeURL))
    }

    func testCleanupFailureAfterValidationNeverRollsBackRestoredStore() throws {
        try seedV6RecoveryStore()
        let backup = try MigrationBackupManager.prepareVerifiedBackup(at: storeURL)
        try addCurrentPodcast()
        try Data([0xA1]).write(to: StoreMigration.localStoreURL(for: storeURL))

        MigrationBackupManager.injectedQuarantineCleanupFailure = true
        XCTAssertNoThrow(try MigrationBackupManager.restore(backup, at: storeURL))
        MigrationBackupManager.injectedQuarantineCleanupFailure = false

        let root = MigrationBackupManager.backupRoot(for: storeURL)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appending(path: "restore-transaction.json").path
        ))
        let quarantine = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ).first { $0.lastPathComponent.hasPrefix("restore-quarantine-") })
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(
            at: quarantine, includingPropertiesForKeys: nil
        ).isEmpty, "cleanup must have failed after deleting only part of quarantine")
        XCTAssertEqual(try podcastCount(), 1, "validated backup must remain installed")

        try MigrationBackupManager.recoverInterruptedRestore(at: storeURL)

        XCTAssertEqual(try podcastCount(), 1, "cleanup retry must not restore quarantined files")
        XCTAssertFalse(FileManager.default.fileExists(atPath: quarantine.path))
        XCTAssertNotNil(MigrationBackupManager.latestRestorableBackup(at: storeURL))
    }

    func testIncompleteLegacyBackupIsNeverOffered() throws {
        let directory = MigrationBackupManager.backupRoot(for: storeURL)
            .appending(path: "partial", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data([0x00, 0x01]).write(to: directory.appending(path: "default.store"))
        XCTAssertNil(MigrationBackupManager.latestRestorableBackup(at: storeURL))
    }

    func testVerifiedBackupSurvivesMigrationAndIsRemovedAfterIndependentReopen() throws {
        try seedV6RecoveryStore()
        _ = try MigrationBackupManager.prepareVerifiedBackup(at: storeURL)
        var metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            type: .sqlite, at: storeURL)
        metadata[NSStoreUUIDKey] = UUID().uuidString
        try NSPersistentStoreCoordinator.setMetadata(
            metadata, forPersistentStoreOfType: NSSQLiteStoreType, at: storeURL)
        try MigrationBackupManager.ensureResumeSafety(at: storeURL)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            at: MigrationBackupManager.backupRoot(for: storeURL),
            includingPropertiesForKeys: nil).count, 2)

        MigrationBackupManager.noteSuccessfulTargetOpen(at: storeURL, targetSchemaMajor: 11)
        XCTAssertNotNil(MigrationBackupManager.latestRecordedBackup(at: storeURL))

        MigrationBackupManager.noteSuccessfulTargetOpen(at: storeURL, targetSchemaMajor: 11)
        XCTAssertNil(MigrationBackupManager.latestRecordedBackup(at: storeURL))
    }

    func testLegacyMigrationBackupUsesSameTwoOpenRetentionPolicy() throws {
        try seedV6RecoveryStore()
        let legacyDirectory = try XCTUnwrap(ModelContainerFactory.backupStoreFiles(at: storeURL))

        MigrationBackupManager.noteSuccessfulTargetOpen(at: storeURL, targetSchemaMajor: 11)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: legacyDirectory.appending(path: "migration-retention.json").path
        ))

        MigrationBackupManager.noteSuccessfulTargetOpen(at: storeURL, targetSchemaMajor: 11)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyDirectory.path))
    }

    func testUnreadableResetBackupIsNotRetiredAsAMigrationBackup() throws {
        try Data([0x00, 0x01, 0x02, 0x03, 0xFF]).write(to: storeURL)
        let resetBackup = try XCTUnwrap(ModelContainerFactory.backupStoreFiles(at: storeURL))

        MigrationBackupManager.noteSuccessfulTargetOpen(at: storeURL, targetSchemaMajor: 11)
        MigrationBackupManager.noteSuccessfulTargetOpen(at: storeURL, targetSchemaMajor: 11)

        XCTAssertTrue(FileManager.default.fileExists(atPath: resetBackup.path))
    }
}

// MARK: - Future-schema fixture

/// A model that exists only in the "future" fixture schema, giving the store an
/// entity the app's V4 schema doesn't know — enough to make opening as V4 fail
/// with an incompatible-version error.
@Model
final class FutureOnlyEntity {
    var value: Int
    init(value: Int = 0) { self.value = value }
}

/// A schema newer than ``EarshotSchemaV4``: all of V4 plus one extra entity.
enum SchemaVFutureFixture: VersionedSchema {
    static let versionIdentifier = Schema.Version(99, 0, 0)
    static var models: [any PersistentModel.Type] {
        EarshotSchemaV4.models + [FutureOnlyEntity.self]
    }
}
