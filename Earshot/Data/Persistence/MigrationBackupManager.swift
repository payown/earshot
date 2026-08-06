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
    let byteCount: Int64
    let format: Format
    let successfulTargetOpenCount: Int
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
    static let targetSchemaMajor = 10
    static let initialFreeSpaceMultiplier = 3.25
    static let retainedBackupFreeSpaceMultiplier = 2.25
    #if DEBUG
    nonisolated(unsafe) static var injectedRestoreFailureAfterQuarantine = false
    nonisolated(unsafe) static var injectedQuarantineCleanupFailure = false
    #endif
    private static let manifestName = "manifest.json"
    private static let snapshotName = "default.store"
    private static let restoreJournalName = "restore-transaction.json"
    private static let legacyRetentionName = "migration-retention.json"
    private static let storeSuffixes = ["", "-wal", "-shm", "-journal"]
    private struct Manifest: Codable, Sendable {
        let formatVersion: Int
        let id: UUID
        let createdAt: Date
        let sourceSchemaMajor: Int
        let targetSchemaMajor: Int
        let sourceStoreIdentifier: String
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
    private struct LegacyRetention: Codable, Sendable {
        var successfulTargetOpenCount: Int
    }
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
            if let manifest = try? readManifest(in: directory),
               let descriptor = try? descriptor(for: manifest, in: directory),
               (try? validate(descriptor)) == true {
                return descriptor
            }
            return try? legacyDescriptor(in: directory)
        }
        return candidates.max { $0.createdAt < $1.createdAt }
    }

    /// Manifest-only lookup; restore performs full validation before file changes.
    static func latestRecordedBackup(at storeURL: URL) -> MigrationBackupDescriptor? {
        verifiedBackups(at: storeURL).first
    }
    /// A verified snapshot is a hard prerequisite. The measured V6-to-V10 peak
    /// used 3.015 times the source set in additional blocks: 1.000 snapshot,
    /// 0.987 final-store growth, 1.028 WAL/sidecars, and about 0.001 local store.
    /// 3.25 times preserves a bounded margin before the first snapshot, while a
    /// retained snapshot means only the migration working set still needs to fit.
    static func prepareVerifiedBackup(
        at storeURL: URL,
        targetSchemaMajor: Int = targetSchemaMajor
    ) throws -> MigrationBackupDescriptor {
        try recoverInterruptedRestore(at: storeURL)
        let source = try sourceIdentity(at: storeURL)
        let sourceBytes = try storeSetByteCount(at: storeURL)
        if let retained = verifiedBackups(at: storeURL).first(where: {
            $0.sourceStoreIdentifier == source.identifier
                && $0.sourceSchemaMajor == source.major
                && $0.targetSchemaMajor == targetSchemaMajor
        }), (try? validate(retained)) == true {
            try requireFreeSpace(
                at: storeURL,
                bytes: requiredBytes(
                    for: retained.byteCount,
                    multiplier: retainedBackupFreeSpaceMultiplier
                )
            )
            return retained
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
            let snapshotIdentity = try sourceIdentity(at: snapshotURL)
            guard snapshotIdentity.major == source.major,
                  snapshotIdentity.identifier == source.identifier,
                  try sqliteIntegrityCheck(at: snapshotURL) else {
                throw MigrationBackupError.snapshotInvalid
            }
            let byteCount = try fileByteCount(at: snapshotURL)
            let manifest = Manifest(
                formatVersion: 1,
                id: id,
                createdAt: .now,
                sourceSchemaMajor: source.major,
                targetSchemaMajor: targetSchemaMajor,
                sourceStoreIdentifier: source.identifier,
                byteCount: byteCount,
                successfulTargetOpenCount: 0
            )
            try writeManifest(manifest, in: staging)
            try FileManager.default.moveItem(at: staging, to: completed)
            let descriptor = try descriptor(for: manifest, in: completed)
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
            throw error
        }
    }
    static func ensureResumeSafety(at storeURL: URL) throws {
        let liveSourceIdentifier = try sourceIdentity(at: storeURL).identifier
        if let retained = latestRestorableBackup(at: storeURL),
           retained.sourceStoreIdentifier == liveSourceIdentifier,
           retained.successfulTargetOpenCount == 0 {
            try requireFreeSpace(
                at: storeURL,
                bytes: requiredBytes(
                    for: retained.byteCount,
                    multiplier: retainedBackupFreeSpaceMultiplier
                )
            )
            return
        }
        _ = try prepareVerifiedBackup(at: storeURL)
    }
    static func restore(_ backup: MigrationBackupDescriptor, at storeURL: URL) throws {
        try recoverInterruptedRestore(at: storeURL)
        guard try validate(backup) else { throw MigrationBackupError.snapshotInvalid }
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
            let restored = try sourceIdentity(at: storeURL)
            guard restored.major == backup.sourceSchemaMajor,
                  try sqliteIntegrityCheck(at: storeURL) else {
                throw MigrationBackupError.snapshotInvalid
            }
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
        let backup = (try? readManifest(in: backupDirectory)).flatMap {
            try? descriptor(for: $0, in: backupDirectory)
        } ?? (try? legacyDescriptor(in: backupDirectory))
        let installedIdentity = try? sourceIdentity(at: storeURL)
        if journal.phase == .validating,
           let backup,
           installedIdentity?.major == backup.sourceSchemaMajor,
           installedIdentity?.identifier == backup.sourceStoreIdentifier,
           (try? sqliteIntegrityCheck(at: storeURL)) == true {
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
        guard manifest.formatVersion == 1 else {
            throw MigrationBackupError.snapshotInvalid
        }
        return MigrationBackupDescriptor(
            id: manifest.id,
            directoryURL: directory,
            createdAt: manifest.createdAt,
            sourceSchemaMajor: manifest.sourceSchemaMajor,
            targetSchemaMajor: manifest.targetSchemaMajor,
            sourceStoreIdentifier: manifest.sourceStoreIdentifier,
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
            byteCount: try storeSetByteCount(at: url),
            format: .legacyStoreSet,
            successfulTargetOpenCount: 0
        )
    }
    private static func validate(_ backup: MigrationBackupDescriptor) throws -> Bool {
        let snapshotURL = backup.directoryURL.appending(path: snapshotName)
        guard FileManager.default.fileExists(atPath: snapshotURL.path),
              try sqliteIntegrityCheck(at: snapshotURL) else { return false }
        let identity = try sourceIdentity(at: snapshotURL)
        return identity.major == backup.sourceSchemaMajor
            && identity.identifier == backup.sourceStoreIdentifier
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
            && backup.targetSchemaMajor == retained.targetSchemaMajor {
            try FileManager.default.removeItem(at: backup.directoryURL)
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
    private static func moveLiveStoreSet(at storeURL: URL, to quarantine: URL) throws {
        for fileURL in liveStoreFiles(at: storeURL) {
            try FileManager.default.moveItem(
                at: fileURL,
                to: quarantine.appending(path: fileURL.lastPathComponent)
            )
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
