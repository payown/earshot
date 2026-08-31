import CoreData
import Darwin
import Foundation
import SQLite3

struct MigrationBackupDescriptor: Equatable, Sendable, Identifiable {
    enum Format: String, Codable, Sendable {
        case verifiedSnapshot
        case legacyStoreSet
    }
    let id: UUID
    let directoryURL: URL
    let createdAt: Date
    let sourceSchemaMajor: Int
    let targetSchemaMajor: Int
    let sourceStoreIdentifier: String
    let localSourceSchemaMajor: Int?
    let localSourceStoreIdentifier: String?
    let byteCount: Int64
    let format: Format
    let successfulTargetOpenCount: Int

    init(
        id: UUID,
        directoryURL: URL,
        createdAt: Date,
        sourceSchemaMajor: Int,
        targetSchemaMajor: Int,
        sourceStoreIdentifier: String,
        localSourceSchemaMajor: Int? = nil,
        localSourceStoreIdentifier: String? = nil,
        byteCount: Int64,
        format: Format,
        successfulTargetOpenCount: Int
    ) {
        self.id = id
        self.directoryURL = directoryURL
        self.createdAt = createdAt
        self.sourceSchemaMajor = sourceSchemaMajor
        self.targetSchemaMajor = targetSchemaMajor
        self.sourceStoreIdentifier = sourceStoreIdentifier
        self.localSourceSchemaMajor = localSourceSchemaMajor
        self.localSourceStoreIdentifier = localSourceStoreIdentifier
        self.byteCount = byteCount
        self.format = format
        self.successfulTargetOpenCount = successfulTargetOpenCount
    }
}

enum MigrationBackupError: Error, Equatable, Sendable {
    case insufficientStorage(requiredBytes: Int64, availableBytes: Int64)
    case sourceMetadataUnavailable
    case snapshotFailed(code: Int32, message: String)
    case snapshotInvalid
    case restoreFailed(String)
}

/// Creates, catalogs, restores, and retires migration safety snapshots. A
/// manifest is written last so a partial copy is never considered a backup.
enum MigrationBackupManager {
    static let targetSchemaMajor = 12
    static let initialFreeSpaceMultiplier = 4.5
    static let retainedBackupFreeSpaceMultiplier = 3.5
    #if DEBUG
    nonisolated(unsafe) static var injectedRestoreFailureAfterQuarantine = false
    nonisolated(unsafe) static var injectedRestoreFailureAfterPrimaryInstall = false
    nonisolated(unsafe) static var injectedRestoreInterruptionAfterValidationJournal = false
    nonisolated(unsafe) static var injectedQuarantineCleanupFailure = false
    nonisolated(unsafe) static var injectedEraseFailureAfterMoveCount: Int?
    nonisolated(unsafe) static var injectedEraseRollbackFailure = false
    nonisolated(unsafe) static var injectedAvailableBytes: Int64?
    #endif
    private static let manifestName = "manifest.json"
    private static let snapshotName = "default.store"
    private static let localSnapshotName = "default-local.store"
    private static let incompletePrefix = ".incomplete-"
    private static let restoreJournalName = "restore-transaction.json"
    private static let eraseJournalName = "erase-transaction.json"
    private static let legacyRetentionName = "migration-retention.json"
    private static let storeSuffixes = ["", "-wal", "-shm", "-journal"]
    private struct Manifest: Codable, Sendable {
        let formatVersion: Int
        let id: UUID
        let createdAt: Date
        let sourceSchemaMajor: Int
        let targetSchemaMajor: Int
        let sourceStoreIdentifier: String
        let localSourceSchemaMajor: Int?
        let localSourceStoreIdentifier: String?
        let byteCount: Int64
        var successfulTargetOpenCount: Int
    }
    private struct RestoreJournal: Codable, Sendable {
        enum Phase: String, Codable, Sendable {
            case quarantining
            case installing
            case validating
        }
        let backupDirectoryName: String
        let quarantineDirectoryName: String
        let phase: Phase
        let originalFileNames: [String]
    }
    private struct EraseJournal: Codable, Sendable {
        enum Phase: String, Codable, Sendable {
            case moving
            case committed
        }
        let backupDirectoryName: String
        let quarantineDirectoryName: String
        let phase: Phase
    }
    private struct LegacyRetention: Codable, Sendable {
        var successfulTargetOpenCount: Int
    }
    private struct SimulatedRestoreInterruption: Error {}
    static func backupRoot(for storeURL: URL) -> URL {
        storeURL.deletingLastPathComponent()
            .appending(path: "store-backups", directoryHint: .isDirectory)
    }
    /// Returns the newest verified snapshot or restorable pre-manifest backup.
    static func latestRestorableBackup(at storeURL: URL) -> MigrationBackupDescriptor? {
        let root = backupRoot(for: storeURL)
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let candidates = directories.compactMap { directory -> MigrationBackupDescriptor? in
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            else { return nil }
            if FileManager.default.fileExists(
                atPath: directory.appending(path: manifestName).path
            ) {
                guard let manifest = try? readManifest(in: directory),
                      let descriptor = try? descriptor(for: manifest, in: directory),
                      (try? validate(descriptor)) == true else { return nil }
                return descriptor
            }
            return try? legacyDescriptor(in: directory)
        }
        return candidates
            .filter { $0.targetSchemaMajor == targetSchemaMajor }
            .max { $0.createdAt < $1.createdAt }
    }

    /// Manifest-only lookup; restore performs full validation before file changes.
    static func latestRecordedBackup(at storeURL: URL) -> MigrationBackupDescriptor? {
        verifiedBackups(at: storeURL).first { $0.targetSchemaMajor == targetSchemaMajor }
    }

    /// Revalidates the exact backup offered by recovery immediately before any
    /// destructive action. The directory must belong to this store's backup
    /// root, the snapshot must still pass SQLite integrity and identity checks,
    /// and a readable live store must have the same persistent-store identity.
    static func validateForDestructiveRecovery(
        _ backup: MigrationBackupDescriptor,
        at storeURL: URL
    ) throws {
        let expectedRoot = backupRoot(for: storeURL).standardizedFileURL
        guard backup.directoryURL.deletingLastPathComponent().standardizedFileURL
                == expectedRoot,
              try validate(backup) else {
            throw MigrationBackupError.snapshotInvalid
        }
        if let liveIdentity = try? sourceIdentity(at: storeURL),
           liveIdentity.identifier != backup.sourceStoreIdentifier {
            throw MigrationBackupError.snapshotInvalid
        }
        if let backupLocalIdentifier = backup.localSourceStoreIdentifier {
            let localURL = StoreMigration.localStoreURL(for: storeURL)
            guard let liveLocalIdentity = try? sourceIdentity(at: localURL),
                  liveLocalIdentity.identifier == backupLocalIdentifier else {
                throw MigrationBackupError.snapshotInvalid
            }
        }
    }
    /// A verified snapshot is a hard prerequisite. Repeated migrations of the
    /// preserved 405.4 MiB build-161 store measured as high as 4.249x the source in peak
    /// additional blocks under Xcode 26.6. Require 4.5x before creating the
    /// snapshot. A retained snapshot already occupies one source-sized copy, so a
    /// 3.5x free-space requirement covers the remaining migration working set.
    static func prepareVerifiedBackup(
        at storeURL: URL,
        targetSchemaMajor: Int = targetSchemaMajor
    ) throws -> MigrationBackupDescriptor {
        try recoverInterruptedErasure(at: storeURL)
        try recoverInterruptedRestore(at: storeURL)
        try removeInterruptedSnapshotStaging(at: storeURL)
        let source = try sourceIdentity(at: storeURL)
        let localURL = StoreMigration.localStoreURL(for: storeURL)
        let localSource = FileManager.default.fileExists(atPath: localURL.path)
            ? try sourceIdentity(at: localURL)
            : nil
        let sourceBytes = try storeSetByteCount(at: storeURL)
            + (localSource == nil ? 0 : try storeSetByteCount(at: localURL))
        let recorded = verifiedBackups(at: storeURL)
        if let retained = recorded.first(where: {
            resumeBackup($0, matches: source, local: localSource)
        }) {
            guard try validate(retained) else {
                throw MigrationBackupError.snapshotInvalid
            }
            try requireFreeSpace(
                at: storeURL,
                bytes: requiredBytes(
                    for: retained.byteCount,
                    multiplier: retainedBackupFreeSpaceMultiplier
                )
            )
            return retained
        }
        // Never replace the only current-target rollback authority with a
        // snapshot of an intermediate state. Snapshot unchanged sources again
        // so a stale count-zero backup cannot roll back newer edits.
        if recorded.contains(where: {
            $0.targetSchemaMajor == targetSchemaMajor
                && $0.successfulTargetOpenCount == 0
                && $0.sourceStoreIdentifier == source.identifier
                && !backupSourceIsUnchanged($0, primary: source, local: localSource)
        }) {
            throw MigrationBackupError.snapshotInvalid
        }
        // No migration step has begun for these exact source identities. Remove
        // their stale same-target snapshots before the 4.5x gate; a process death
        // is safe because the unchanged live source remains authoritative.
        for stale in recorded where stale.targetSchemaMajor == targetSchemaMajor
            && stale.successfulTargetOpenCount == 0
            && stale.sourceStoreIdentifier == source.identifier
            && backupSourceIsUnchanged(stale, primary: source, local: localSource) {
            try FileManager.default.removeItem(at: stale.directoryURL)
        }
        try requireFreeSpace(
            at: storeURL,
            bytes: requiredBytes(for: sourceBytes, multiplier: initialFreeSpaceMultiplier)
        )
        let root = backupRoot(for: storeURL)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try excludeFromSystemBackup(root)
        let id = UUID()
        let staging = root.appending(
            path: ".incomplete-\(id.uuidString)", directoryHint: .isDirectory
        )
        let completed = root.appending(path: id.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        try excludeFromSystemBackup(staging)
        do {
            let snapshotURL = staging.appending(path: snapshotName)
            try createSQLiteSnapshot(from: storeURL, to: snapshotURL)
            try removeSnapshotSidecars(at: snapshotURL)
            let snapshotIdentity = try sourceIdentity(at: snapshotURL)
            guard snapshotIdentity.major == source.major,
                  snapshotIdentity.identifier == source.identifier,
                  try sqliteIntegrityCheck(at: snapshotURL),
                  snapshotHasNoSidecars(at: snapshotURL) else {
                throw MigrationBackupError.snapshotInvalid
            }
            var byteCount = try fileByteCount(at: snapshotURL)
            if let localSource {
                let localSnapshotURL = staging.appending(path: localSnapshotName)
                try createSQLiteSnapshot(from: localURL, to: localSnapshotURL)
                try removeSnapshotSidecars(at: localSnapshotURL)
                let localSnapshotIdentity = try sourceIdentity(at: localSnapshotURL)
                guard localSnapshotIdentity.major == localSource.major,
                      localSnapshotIdentity.identifier == localSource.identifier,
                      try sqliteIntegrityCheck(at: localSnapshotURL),
                      snapshotHasNoSidecars(at: localSnapshotURL) else {
                    throw MigrationBackupError.snapshotInvalid
                }
                byteCount += try fileByteCount(at: localSnapshotURL)
            }
            let manifest = Manifest(
                formatVersion: localSource == nil ? 1 : 2,
                id: id,
                createdAt: .now,
                sourceSchemaMajor: source.major,
                targetSchemaMajor: targetSchemaMajor,
                sourceStoreIdentifier: source.identifier,
                localSourceSchemaMajor: localSource?.major,
                localSourceStoreIdentifier: localSource?.identifier,
                byteCount: byteCount,
                successfulTargetOpenCount: 0
            )
            try writeManifest(manifest, in: staging)
            try FileManager.default.moveItem(at: staging, to: completed)
            let descriptor = try descriptor(for: manifest, in: completed)
            guard try validate(descriptor) else {
                throw MigrationBackupError.snapshotInvalid
            }
            do {
                try removeRedundantVerifiedBackups(except: descriptor, at: storeURL)
            } catch {
                AppLog.data.error(
                    "Could not remove a redundant migration backup: \(error.localizedDescription, privacy: .public)"
                )
            }
            return descriptor
        } catch {
            try? FileManager.default.removeItem(at: staging)
            try? FileManager.default.removeItem(at: completed)
            throw error
        }
    }
    static func ensureResumeSafety(at storeURL: URL) throws {
        let livePrimary = try sourceIdentity(at: storeURL)
        let localURL = StoreMigration.localStoreURL(for: storeURL)
        let liveLocal = FileManager.default.fileExists(atPath: localURL.path)
            ? try sourceIdentity(at: localURL)
            : nil
        if let retained = verifiedBackups(at: storeURL).first(where: {
            resumeBackup($0, matches: livePrimary, local: liveLocal)
                && (try? validate($0)) == true
        }) {
            try requireFreeSpace(
                at: storeURL,
                bytes: requiredBytes(
                    for: retained.byteCount,
                    multiplier: retainedBackupFreeSpaceMultiplier
                )
            )
            return
        }
        guard livePrimary.major < targetSchemaMajor else {
            throw MigrationBackupError.snapshotInvalid
        }
        if livePrimary.major >= 8 {
            guard liveLocal?.major == livePrimary.major else {
                throw MigrationBackupError.snapshotInvalid
            }
        }
        _ = try prepareVerifiedBackup(at: storeURL)
    }

    private static func resumeBackup(
        _ backup: MigrationBackupDescriptor,
        matches livePrimary: (major: Int, identifier: String),
        local liveLocal: (major: Int, identifier: String)?
    ) -> Bool {
        guard backup.targetSchemaMajor == targetSchemaMajor,
              backup.successfulTargetOpenCount == 0,
              backup.sourceStoreIdentifier == livePrimary.identifier,
              knownPrimaryRoute(from: backup.sourceSchemaMajor)
                .contains(livePrimary.major) else { return false }
        if let backupLocalMajor = backup.localSourceSchemaMajor {
            guard let backupLocalIdentifier = backup.localSourceStoreIdentifier,
                  let liveLocal,
                  liveLocal.identifier == backupLocalIdentifier,
                  knownLocalRoute(from: backupLocalMajor)
                    .contains(liveLocal.major) else { return false }
        } else if let liveLocal,
                  !knownCreatedLocalRoute(from: backup.sourceSchemaMajor)
                    .contains(liveLocal.major) {
            return false
        }
        return !backupSourceIsUnchanged(
            backup, primary: livePrimary, local: liveLocal
        )
    }

    private static func backupSourceIsUnchanged(
        _ backup: MigrationBackupDescriptor,
        primary: (major: Int, identifier: String),
        local: (major: Int, identifier: String)?
    ) -> Bool {
        guard primary.major == backup.sourceSchemaMajor else { return false }
        switch (backup.localSourceSchemaMajor, backup.localSourceStoreIdentifier, local) {
        case (nil, nil, nil):
            return true
        case (let major?, let identifier?, let local?):
            return local.major == major && local.identifier == identifier
        default:
            return false
        }
    }

    private static func knownPrimaryRoute(from sourceMajor: Int) -> Set<Int> {
        switch sourceMajor {
        case 5: [5, 10, 12]
        case 6: [6, 7, 10, 12]
        case 7: [7, 10, 12]
        case 8, 9: [sourceMajor, 10, 12]
        case 10: [10, 12]
        case 11: [11, 12]
        default: []
        }
    }

    private static func knownLocalRoute(from sourceMajor: Int) -> Set<Int> {
        switch sourceMajor {
        case 8, 9: [sourceMajor, 10, 11, 12]
        case 10: [10, 11, 12]
        case 11: [11, 12]
        default: []
        }
    }

    private static func knownCreatedLocalRoute(from sourceMajor: Int) -> Set<Int> {
        (5...7).contains(sourceMajor) ? [12] : []
    }
    static func restore(_ backup: MigrationBackupDescriptor, at storeURL: URL) throws {
        try recoverInterruptedErasure(at: storeURL)
        try recoverInterruptedRestore(at: storeURL)
        guard backup.targetSchemaMajor == targetSchemaMajor,
              try validate(backup) else { throw MigrationBackupError.snapshotInvalid }
        let root = backupRoot(for: storeURL)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let quarantineName = "restore-quarantine-\(UUID().uuidString)"
        let quarantine = root.appending(path: quarantineName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: quarantine, withIntermediateDirectories: false)
        let originalFileNames = liveStoreFiles(at: storeURL)
            .map(\.lastPathComponent)
        var journal = RestoreJournal(
            backupDirectoryName: backup.directoryURL.lastPathComponent,
            quarantineDirectoryName: quarantineName,
            phase: .quarantining,
            originalFileNames: originalFileNames
        )
        let journalURL = root.appending(path: restoreJournalName)
        try writeJSON(journal, to: journalURL)

        do {
            try moveLiveStoreSet(at: storeURL, to: quarantine)
            journal = RestoreJournal(
                backupDirectoryName: journal.backupDirectoryName,
                quarantineDirectoryName: journal.quarantineDirectoryName,
                phase: .installing,
                originalFileNames: journal.originalFileNames
            )
            try writeJSON(journal, to: journalURL)
            #if DEBUG
            if injectedRestoreFailureAfterQuarantine {
                throw MigrationBackupError.restoreFailed("Injected restore failure")
            }
            #endif
            try install(backup, at: storeURL)
            journal = RestoreJournal(
                backupDirectoryName: journal.backupDirectoryName,
                quarantineDirectoryName: journal.quarantineDirectoryName,
                phase: .validating,
                originalFileNames: journal.originalFileNames
            )
            try writeJSON(journal, to: journalURL)
            #if DEBUG
            if injectedRestoreInterruptionAfterValidationJournal {
                throw SimulatedRestoreInterruption()
            }
            #endif
            guard try installedBackupIsValid(backup, at: storeURL) else {
                throw MigrationBackupError.snapshotInvalid
            }
        } catch let interruption as SimulatedRestoreInterruption {
            throw interruption
        } catch {
            do {
                try rollBackRestore(journal, from: quarantine, to: storeURL)
                try FileManager.default.removeItem(at: journalURL)
                throw MigrationBackupError.restoreFailed(error.localizedDescription)
            } catch let rollbackError as MigrationBackupError {
                throw rollbackError
            } catch {
                // Keep the journal and quarantine. The next launch retries the
                // rollback before opening either store.
                throw MigrationBackupError.restoreFailed(
                    "Restore rollback is pending: \(error.localizedDescription)"
                )
            }
        }
        // Validation is the commit point. Cleanup must never enter rollback.
        finishValidatedRestore(quarantine: quarantine, journalURL: journalURL)
    }

    /// Moves every live store file out of the active paths before committing
    /// erasure. A force-quit before the commit marker restores the files on next
    /// launch; a force-quit afterward finishes quarantine cleanup. The verified
    /// snapshot is never moved or deleted.
    static func eraseLibrary(
        at storeURL: URL,
        preserving backup: MigrationBackupDescriptor
    ) throws {
        try recoverInterruptedErasure(at: storeURL)
        try recoverInterruptedRestore(at: storeURL)
        try validateForDestructiveRecovery(backup, at: storeURL)

        let root = backupRoot(for: storeURL)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let quarantineName = "erase-quarantine-\(UUID().uuidString)"
        let quarantine = root.appending(path: quarantineName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: quarantine, withIntermediateDirectories: false)
        let journalURL = root.appending(path: eraseJournalName)
        var journal = EraseJournal(
            backupDirectoryName: backup.directoryURL.lastPathComponent,
            quarantineDirectoryName: quarantineName,
            phase: .moving
        )
        try writeJSON(journal, to: journalURL)

        do {
            #if DEBUG
            let failureAfterMoves = injectedEraseFailureAfterMoveCount
            #else
            let failureAfterMoves: Int? = nil
            #endif
            try moveLiveStoreSet(
                at: storeURL,
                to: quarantine,
                failureAfterMoves: failureAfterMoves
            )
            try validateForDestructiveRecovery(backup, at: storeURL)
            journal = EraseJournal(
                backupDirectoryName: journal.backupDirectoryName,
                quarantineDirectoryName: journal.quarantineDirectoryName,
                phase: .committed
            )
            try writeJSON(journal, to: journalURL)
        } catch {
            do {
                #if DEBUG
                if injectedEraseRollbackFailure {
                    throw MigrationBackupError.restoreFailed(
                        "Injected erase rollback failure"
                    )
                }
                #endif
                try restoreQuarantinedStoreSet(from: quarantine, to: storeURL)
                try FileManager.default.removeItem(at: journalURL)
            } catch {
                // Leave the moving journal in place. Launch recovery retries the
                // rollback before opening either store.
            }
            throw error
        }
        finishCommittedErasure(quarantine: quarantine, journalURL: journalURL)
    }

    /// Completes or rolls back an erasure interrupted by process termination.
    static func recoverInterruptedErasure(at storeURL: URL) throws {
        let root = backupRoot(for: storeURL)
        let journalURL = root.appending(path: eraseJournalName)
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return }
        let journal: EraseJournal = try readJSON(from: journalURL)
        let quarantine = root.appending(
            path: journal.quarantineDirectoryName, directoryHint: .isDirectory
        )
        switch journal.phase {
        case .moving:
            try restoreQuarantinedStoreSet(from: quarantine, to: storeURL)
            try FileManager.default.removeItem(at: journalURL)
        case .committed:
            finishCommittedErasure(quarantine: quarantine, journalURL: journalURL)
        }
    }

    /// Completes a valid interrupted restore or reinstalls its quarantined store.
    static func recoverInterruptedRestore(at storeURL: URL) throws {
        let root = backupRoot(for: storeURL)
        let journalURL = root.appending(path: restoreJournalName)
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return }
        let journal: RestoreJournal = try readJSON(from: journalURL)
        let quarantine = root.appending(
            path: journal.quarantineDirectoryName, directoryHint: .isDirectory
        )
        let backupDirectory = root.appending(
            path: journal.backupDirectoryName, directoryHint: .isDirectory
        )
        let manifestURL = backupDirectory.appending(path: manifestName)
        let backup: MigrationBackupDescriptor?
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            backup = (try? readManifest(in: backupDirectory)).flatMap {
                try? descriptor(for: $0, in: backupDirectory)
            }
        } else {
            backup = try? legacyDescriptor(in: backupDirectory)
        }
        if journal.phase == .validating,
           let backup,
           (try? installedBackupIsValid(backup, at: storeURL)) == true {
            finishValidatedRestore(quarantine: quarantine, journalURL: journalURL)
            return
        }
        try rollBackRestore(journal, from: quarantine, to: storeURL)
        try FileManager.default.removeItem(at: journalURL)
    }
    /// A completed migration is retained through one independent later open.
    /// The first successful target open marks it; the next removes it.
    static func noteSuccessfulTargetOpen(at storeURL: URL, targetSchemaMajor: Int) {
        for descriptor in verifiedBackups(at: storeURL)
        where descriptor.targetSchemaMajor == targetSchemaMajor {
            do {
                var manifest = try readManifest(in: descriptor.directoryURL)
                manifest.successfulTargetOpenCount += 1
                if manifest.successfulTargetOpenCount >= 2 {
                    try FileManager.default.removeItem(at: descriptor.directoryURL)
                } else {
                    try writeManifest(manifest, in: descriptor.directoryURL)
                }
            } catch {
                AppLog.data.error(
                    "Could not update migration backup retention: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        guard targetSchemaMajor == self.targetSchemaMajor else { return }
        noteSuccessfulLegacyTargetOpen(at: storeURL)
    }
    // MARK: - Catalog
    private static func verifiedBackups(at storeURL: URL) -> [MigrationBackupDescriptor] {
        let root = backupRoot(for: storeURL)
        let directories = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        return directories.compactMap { directory in
            guard let manifest = try? readManifest(in: directory) else { return nil }
            return try? descriptor(for: manifest, in: directory)
        }.sorted { $0.createdAt > $1.createdAt }
    }
    private static func descriptor(
        for manifest: Manifest, in directory: URL
    ) throws -> MigrationBackupDescriptor {
        guard [1, 2].contains(manifest.formatVersion),
              (manifest.formatVersion == 1
                ? manifest.localSourceSchemaMajor == nil
                    && manifest.localSourceStoreIdentifier == nil
                : manifest.localSourceSchemaMajor != nil
                    && manifest.localSourceStoreIdentifier != nil) else {
            throw MigrationBackupError.snapshotInvalid
        }
        return MigrationBackupDescriptor(
            id: manifest.id,
            directoryURL: directory,
            createdAt: manifest.createdAt,
            sourceSchemaMajor: manifest.sourceSchemaMajor,
            targetSchemaMajor: manifest.targetSchemaMajor,
            sourceStoreIdentifier: manifest.sourceStoreIdentifier,
            localSourceSchemaMajor: manifest.localSourceSchemaMajor,
            localSourceStoreIdentifier: manifest.localSourceStoreIdentifier,
            byteCount: manifest.byteCount,
            format: .verifiedSnapshot,
            successfulTargetOpenCount: manifest.successfulTargetOpenCount
        )
    }
    private static func legacyDescriptor(in directory: URL) throws -> MigrationBackupDescriptor {
        let url = directory.appending(path: snapshotName)
        guard FileManager.default.fileExists(atPath: url.path),
              try sqliteIntegrityCheck(at: url) else {
            throw MigrationBackupError.snapshotInvalid
        }
        let identity = try sourceIdentity(at: url)
        guard (6...9).contains(identity.major) else {
            throw MigrationBackupError.snapshotInvalid
        }
        let values = try directory.resourceValues(forKeys: [.creationDateKey])
        return MigrationBackupDescriptor(
            id: UUID(),
            directoryURL: directory,
            createdAt: values.creationDate ?? .distantPast,
            sourceSchemaMajor: identity.major,
            targetSchemaMajor: targetSchemaMajor,
            sourceStoreIdentifier: identity.identifier,
            localSourceSchemaMajor: nil,
            localSourceStoreIdentifier: nil,
            byteCount: try storeSetByteCount(at: url),
            format: .legacyStoreSet,
            successfulTargetOpenCount: 0
        )
    }
    private static func validate(_ backup: MigrationBackupDescriptor) throws -> Bool {
        let snapshotURL = backup.directoryURL.appending(path: snapshotName)
        guard FileManager.default.fileExists(atPath: snapshotURL.path),
              try sqliteIntegrityCheck(at: snapshotURL) else { return false }
        if backup.localSourceSchemaMajor != nil,
           !snapshotHasNoSidecars(at: snapshotURL) { return false }
        let identity = try sourceIdentity(at: snapshotURL)
        guard identity.major == backup.sourceSchemaMajor,
              identity.identifier == backup.sourceStoreIdentifier else { return false }
        switch (backup.localSourceSchemaMajor, backup.localSourceStoreIdentifier) {
        case (nil, nil):
            return true
        case (let localMajor?, let localIdentifier?):
            let localSnapshotURL = backup.directoryURL.appending(path: localSnapshotName)
            guard FileManager.default.fileExists(atPath: localSnapshotURL.path) else {
                return false
            }
            guard snapshotHasNoSidecars(at: localSnapshotURL) else { return false }
            let localIdentity = try sourceIdentity(at: localSnapshotURL)
            let localIntegrity = try sqliteIntegrityCheck(at: localSnapshotURL)
            return localIdentity.major == localMajor
                && localIdentity.identifier == localIdentifier
                && localIntegrity
        default:
            return false
        }
    }
    private static func readManifest(in directory: URL) throws -> Manifest {
        try readJSON(from: directory.appending(path: manifestName))
    }
    private static func writeManifest(_ manifest: Manifest, in directory: URL) throws {
        try writeJSON(manifest, to: directory.appending(path: manifestName))
    }
    private static func removeRedundantVerifiedBackups(
        except retained: MigrationBackupDescriptor, at storeURL: URL
    ) throws {
        for backup in verifiedBackups(at: storeURL)
        where backup.id != retained.id
            && backup.sourceStoreIdentifier == retained.sourceStoreIdentifier
            && backup.targetSchemaMajor <= retained.targetSchemaMajor {
            try FileManager.default.removeItem(at: backup.directoryURL)
        }
    }

    private static func removeInterruptedSnapshotStaging(at storeURL: URL) throws {
        let root = backupRoot(for: storeURL)
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        for candidate in try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsSubdirectoryDescendants]
        ) {
            let name = candidate.lastPathComponent
            guard name.hasPrefix(incompletePrefix),
                  UUID(uuidString: String(name.dropFirst(incompletePrefix.count))) != nil,
                  try candidate.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            else { continue }
            try FileManager.default.removeItem(at: candidate)
        }
    }
    /// Gives valid build-163 V6–V9 backups manifest-equivalent retention without
    /// a whole-store integrity check during ordinary launch.
    private static func noteSuccessfulLegacyTargetOpen(at storeURL: URL) {
        let root = backupRoot(for: storeURL)
        let directories = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        for directory in directories {
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  !FileManager.default.fileExists(
                    atPath: directory.appending(path: manifestName).path
                  ) else { continue }
            let snapshotURL = directory.appending(path: snapshotName)
            guard let source = try? sourceIdentity(at: snapshotURL),
                  (6..<targetSchemaMajor).contains(source.major) else { continue }
            let retentionURL = directory.appending(path: legacyRetentionName)
            var retention: LegacyRetention = (try? readJSON(from: retentionURL))
                ?? LegacyRetention(successfulTargetOpenCount: 0)
            retention.successfulTargetOpenCount += 1
            do {
                if retention.successfulTargetOpenCount >= 2 {
                    try FileManager.default.removeItem(at: directory)
                } else {
                    try writeJSON(retention, to: retentionURL)
                }
            } catch {
                AppLog.data.error(
                    "Could not update legacy migration backup retention: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }
    // MARK: - Restore transaction
    private static func finishValidatedRestore(quarantine: URL, journalURL: URL) {
        do {
            #if DEBUG
            if injectedQuarantineCleanupFailure {
                let files = try FileManager.default.contentsOfDirectory(
                    at: quarantine, includingPropertiesForKeys: nil
                )
                if let first = files.first { try FileManager.default.removeItem(at: first) }
                throw MigrationBackupError.restoreFailed("Injected quarantine cleanup failure")
            }
            #endif
            if FileManager.default.fileExists(atPath: quarantine.path) {
                try FileManager.default.removeItem(at: quarantine)
            }
            try FileManager.default.removeItem(at: journalURL)
        } catch {
            AppLog.data.error(
                "Validated restore cleanup will be retried: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
    private static func finishCommittedErasure(quarantine: URL, journalURL: URL) {
        do {
            if FileManager.default.fileExists(atPath: quarantine.path) {
                try FileManager.default.removeItem(at: quarantine)
            }
            try FileManager.default.removeItem(at: journalURL)
        } catch {
            AppLog.data.error(
                "Committed library-erasure cleanup will be retried: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
    private static func moveLiveStoreSet(
        at storeURL: URL,
        to quarantine: URL,
        failureAfterMoves: Int? = nil
    ) throws {
        var moved = 0
        for fileURL in liveStoreFiles(at: storeURL) {
            try FileManager.default.moveItem(
                at: fileURL,
                to: quarantine.appending(path: fileURL.lastPathComponent)
            )
            moved += 1
            if moved == failureAfterMoves {
                throw MigrationBackupError.restoreFailed(
                    "Injected erase failure after \(moved) move(s)"
                )
            }
        }
    }
    private static func restoreQuarantinedStoreSet(
        from quarantine: URL, to storeURL: URL
    ) throws {
        guard FileManager.default.fileExists(atPath: quarantine.path) else { return }
        for fileURL in try FileManager.default.contentsOfDirectory(
            at: quarantine, includingPropertiesForKeys: nil
        ) {
            let destination = storeURL.deletingLastPathComponent()
                .appending(path: fileURL.lastPathComponent)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: fileURL, to: destination)
        }
        try FileManager.default.removeItem(at: quarantine)
    }
    private static func rollBackRestore(
        _ journal: RestoreJournal, from quarantine: URL, to storeURL: URL
    ) throws {
        let originals = Set(journal.originalFileNames)
        for fileURL in liveStoreFiles(at: storeURL)
        where !originals.contains(fileURL.lastPathComponent) {
            try FileManager.default.removeItem(at: fileURL)
        }
        // Each old file is replaced independently. This is idempotent across a
        // force-quit at any point: already-restored originals remain at the live
        // path and every file still in quarantine is moved back on the next run.
        try restoreQuarantinedStoreSet(from: quarantine, to: storeURL)
    }
    private static func install(
        _ backup: MigrationBackupDescriptor, at storeURL: URL
    ) throws {
        let source = backup.directoryURL.appending(path: snapshotName)
        try cloneOrCopy(from: source, to: storeURL)
        #if DEBUG
        if injectedRestoreFailureAfterPrimaryInstall {
            throw MigrationBackupError.restoreFailed(
                "Injected restore failure after primary install"
            )
        }
        #endif
        if backup.localSourceSchemaMajor != nil {
            let localSource = backup.directoryURL.appending(path: localSnapshotName)
            try cloneOrCopy(
                from: localSource,
                to: StoreMigration.localStoreURL(for: storeURL)
            )
        }
        guard backup.format == .legacyStoreSet else { return }
        for suffix in ["-wal", "-shm", "-journal"] {
            let sidecar = source.deletingPathExtension()
                .appendingPathExtension("store" + suffix)
            guard FileManager.default.fileExists(atPath: sidecar.path) else { continue }
            let destination = storeURL.deletingPathExtension()
                .appendingPathExtension("store" + suffix)
            try cloneOrCopy(from: sidecar, to: destination)
        }
    }

    private static func installedBackupIsValid(
        _ backup: MigrationBackupDescriptor, at storeURL: URL
    ) throws -> Bool {
        let primary = try sourceIdentity(at: storeURL)
        guard primary.major == backup.sourceSchemaMajor,
              primary.identifier == backup.sourceStoreIdentifier,
              try sqliteIntegrityCheck(at: storeURL) else { return false }
        switch (backup.localSourceSchemaMajor, backup.localSourceStoreIdentifier) {
        case (nil, nil):
            return true
        case (let localMajor?, let localIdentifier?):
            let localURL = StoreMigration.localStoreURL(for: storeURL)
            guard FileManager.default.fileExists(atPath: localURL.path) else { return false }
            let local = try sourceIdentity(at: localURL)
            let localIntegrity = try sqliteIntegrityCheck(at: localURL)
            return local.major == localMajor
                && local.identifier == localIdentifier
                && localIntegrity
        default:
            return false
        }
    }
    private static func cloneOrCopy(from source: URL, to destination: URL) throws {
        if clonefile(source.path, destination.path, 0) == 0 { return }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }
    // MARK: - Snapshot and validation
    private static func createSQLiteSnapshot(from sourceURL: URL, to destinationURL: URL) throws {
        var source: OpaquePointer?
        var destination: OpaquePointer?
        let sourceResult = sqlite3_open_v2(
            sourceURL.path, &source, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil
        )
        guard sourceResult == SQLITE_OK, let source else {
            throw sqliteError(database: source, code: sourceResult)
        }
        defer { sqlite3_close(source) }
        let destinationResult = sqlite3_open_v2(
            destinationURL.path,
            &destination,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard destinationResult == SQLITE_OK, let destination else {
            throw sqliteError(database: destination, code: destinationResult)
        }
        defer { sqlite3_close(destination) }
        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
            throw sqliteError(database: destination, code: sqlite3_errcode(destination))
        }
        var result: Int32
        repeat {
            result = sqlite3_backup_step(backup, 1_024)
            if result == SQLITE_BUSY || result == SQLITE_LOCKED {
                sqlite3_sleep(10)
            }
        } while result == SQLITE_OK || result == SQLITE_BUSY || result == SQLITE_LOCKED
        let finishResult = sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE, finishResult == SQLITE_OK else {
            throw sqliteError(
                database: destination,
                code: finishResult == SQLITE_OK ? result : finishResult
            )
        }
        let journalResult = sqlite3_exec(
            destination, "PRAGMA journal_mode=DELETE", nil, nil, nil
        )
        guard journalResult == SQLITE_OK else {
            throw sqliteError(database: destination, code: journalResult)
        }
    }

    private static func snapshotHasNoSidecars(at url: URL) -> Bool {
        storeFiles(at: url).dropFirst().allSatisfy {
            !FileManager.default.fileExists(atPath: $0.path)
        }
    }

    private static func removeSnapshotSidecars(at url: URL) throws {
        for sidecar in storeFiles(at: url).dropFirst()
        where FileManager.default.fileExists(atPath: sidecar.path) {
            try FileManager.default.removeItem(at: sidecar)
        }
    }
    private static func sqliteIntegrityCheck(at url: URL) throws -> Bool {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(
            url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil
        )
        guard result == SQLITE_OK, let database else {
            throw sqliteError(database: database, code: result)
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA integrity_check", -1, &statement, nil)
                == SQLITE_OK,
              let statement else {
            throw sqliteError(database: database, code: sqlite3_errcode(database))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 0) else { return false }
        return String(cString: text) == "ok"
    }
    private static func sqliteError(
        database: OpaquePointer?, code: Int32
    ) -> MigrationBackupError {
        let message = database.map { String(cString: sqlite3_errmsg($0)) }
            ?? String(cString: sqlite3_errstr(code))
        return .snapshotFailed(code: code, message: message)
    }
    private static func sourceIdentity(at url: URL) throws -> (major: Int, identifier: String) {
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            type: .sqlite, at: url
        )
        guard let identifier = (metadata[NSStoreModelVersionIdentifiersKey] as? [String])?.first,
              let major = Int(identifier.split(separator: ".").first ?? "") else {
            throw MigrationBackupError.sourceMetadataUnavailable
        }
        guard let storeIdentifier = (metadata[NSStoreUUIDKey] as? String)
                ?? (metadata[NSStoreUUIDKey] as? UUID)?.uuidString else {
            throw MigrationBackupError.sourceMetadataUnavailable
        }
        return (major, storeIdentifier)
    }
    // MARK: - Storage accounting
    private static func requiredBytes(for sourceBytes: Int64, multiplier: Double) -> Int64 {
        Int64((Double(sourceBytes) * multiplier).rounded(.up))
    }
    private static func requireFreeSpace(at url: URL, bytes required: Int64) throws {
        let available = try availableBytes(at: url.deletingLastPathComponent())
        guard available >= required else {
            throw MigrationBackupError.insufficientStorage(
                requiredBytes: required, availableBytes: available
            )
        }
    }
    static func availableBytes(at url: URL) throws -> Int64 {
        #if DEBUG
        if let injectedAvailableBytes { return injectedAvailableBytes }
        #endif
        var statistics = statfs()
        guard statfs(url.path, &statistics) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        return Int64(statistics.f_bavail) * Int64(statistics.f_bsize)
    }
    private static func storeSetByteCount(at url: URL) throws -> Int64 {
        try storeFiles(at: url).reduce(into: Int64(0)) { total, fileURL in
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
            total += try fileByteCount(at: fileURL)
        }
    }
    private static func fileByteCount(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }
    private static func storeFiles(at url: URL) -> [URL] {
        storeSuffixes.map { suffix in
            url.deletingPathExtension().appendingPathExtension("store" + suffix)
        }
    }
    private static func liveStoreFiles(at storeURL: URL) -> [URL] {
        [storeURL, StoreMigration.localStoreURL(for: storeURL)]
            .flatMap { storeFiles(at: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
    private static func excludeFromSystemBackup(_ url: URL) throws {
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutableURL.setResourceValues(values)
    }
    // MARK: - JSON
    private static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: url, options: .atomic)
    }
    private static func readJSON<T: Decodable>(from url: URL) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: Data(contentsOf: url))
    }
}
