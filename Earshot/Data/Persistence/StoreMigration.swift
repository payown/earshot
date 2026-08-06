import CoreData
import Foundation
import SwiftData

/// Why a terminal store-open failure happened, so ``ModelContainerFactory`` can
/// react safely instead of blindly deleting the store (issue #529).
///
/// - ``storeNewerThanApp``: the on-disk store was written by a NEWER schema than
///   this build knows how to open — a downgrade. The store is intact and must
///   never be destroyed; the user just needs a newer app.
/// - ``storePredatesSupportedSchema``: the store predates the supported public
///   V5 floor. It is left intact so verified backup recovery remains available
///   rather than attempting an unsupported migration.
/// - ``unreadable``: the store could be opened as neither the current schema nor
///   a supported versioned schema — genuine corruption. Only this case is a
///   candidate for a (backed-up, user-consented) reset.
enum StoreOpenError: Error {
    case storeNewerThanApp(underlying: Error)
    case storePredatesSupportedSchema(majorVersion: Int)
    case unreadable(underlying: Error)
}

/// A migration could not complete for an operational reason after the source
/// store was proven readable. This must never be treated as permission to offer
/// corrupt-store recovery: retrying after storage or file-system conditions
/// improve is the safe outcome.
enum StoreMigrationFailure: Error {
    case operational(underlying: Error)
    /// Migration was deliberately not started because Earshot could not create
    /// and retain the verified safety snapshot or its required working margin.
    case backupUnavailable(underlying: Error)
}

/// Coarse, durable migration boundaries suitable for user-facing progress. The
/// engine intentionally reports stages rather than percentages because Core Data
/// migration and SQLite vacuum work do not expose truthful row-level progress.
enum StoreMigrationProgress: Int, CaseIterable, Sendable, Equatable {
    /// Preflight, authoritative-store backup, local-state reconstruction, and
    /// validation of the separately configured local store.
    case preparingAndValidating

    /// Migration of the authoritative mirrored store to the final schema.
    case migratingMirroredStore

    /// Final two-store open, local-state hydration, saves, and identity repair.
    case openingAndRepairing

    var announcement: String {
        switch self {
        case .preparingAndValidating:
            return "Preparing Earshot. Step 1 of 3. Preparing your library data."
        case .migratingMirroredStore:
            return "Preparing Earshot. Step 2 of 3. Reorganizing your episodes."
        case .openingAndRepairing:
            return "Preparing Earshot. Step 3 of 3. Finishing preparation."
        }
    }

    var heartbeat: String {
        "Earshot is still preparing your library. Step \(rawValue + 1) of 3."
    }

    var statusValue: String {
        switch self {
        case .preparingAndValidating:
            return "Step 1 of 3. Preparing your library data."
        case .migratingMirroredStore:
            return "Step 2 of 3. Reorganizing your episodes."
        case .openingAndRepairing:
            return "Step 3 of 3. Finishing preparation."
        }
    }
}

/// Off-main execution boundary for the synchronous SwiftData migration work.
/// A main-actor observer can consume ``progressUpdates`` with `for await`; the
/// persistence engine has no dependency on UI or accessibility APIs.
actor StoreMigrationEngine {
    nonisolated let progressUpdates: AsyncStream<StoreMigrationProgress>
    private let progressContinuation: AsyncStream<StoreMigrationProgress>.Continuation

    init() {
        let stream = AsyncStream<StoreMigrationProgress>.makeStream()
        progressUpdates = stream.stream
        progressContinuation = stream.continuation
    }

    func openOrMigrate(at url: URL) throws -> ModelContainer {
        defer { progressContinuation.finish() }
        return try StoreMigration.openOrMigrate(at: url) { progress in
            progressContinuation.yield(progress)
        }
    }
}

enum SyncBridgeBackfill {
    static func populate(in context: ModelContext) throws {
        let marker = StoreMigration.bridgeCompletionKey
        let existingMarkers = try context.fetch(
            FetchDescriptor<EarshotSchemaV7.LocalAppSetting>(
                predicate: #Predicate { $0.key == marker }
            )
        )
        if !existingMarkers.isEmpty { return }

        let podcasts = try context.fetch(FetchDescriptor<EarshotSchemaV5.Podcast>())
        var podcastRows: [String: EarshotSchemaV7.LocalPodcastState] = [:]
        for podcast in podcasts {
            guard let refreshedAt = podcast.refreshedAt else { continue }
            let key = FeedURLIdentity.canonical(podcast.feedURL)
            if let existing = podcastRows[key] {
                existing.refreshedAt = max(existing.refreshedAt ?? .distantPast, refreshedAt)
            } else {
                let row = EarshotSchemaV7.LocalPodcastState(feedURL: key, refreshedAt: refreshedAt)
                context.insert(row)
                podcastRows[key] = row
            }
        }

        var episodeRows: [String: EarshotSchemaV7.LocalEpisodeState] = [:]
        let downloaded = try context.fetch(
            FetchDescriptor<EarshotSchemaV5.Episode>(
                predicate: #Predicate { $0.downloadPath != nil }
            )
        )
        for episode in downloaded {
            guard let feedURL = episode.podcast?.feedURL,
                  let path = episode.downloadPath, !path.isEmpty else { continue }
            let feed = FeedURLIdentity.canonical(feedURL)
            let key = DownloadTaskKey.key(feedURL: feed, guid: episode.guid)
            let row = EarshotSchemaV7.LocalEpisodeState(
                podcastFeedURL: feed,
                episodeGUID: episode.guid,
                downloadStatusRaw: DownloadStatus.downloaded.rawValue,
                downloadPath: path
            )
            context.insert(row)
            episodeRows[key] = row
        }

        let active = try context.fetch(FetchDescriptor<EarshotSchemaV5.ActiveDownload>())
        for transfer in active {
            guard let episode = transfer.episode,
                  let feedURL = episode.podcast?.feedURL,
                  ActiveDownloadState(rawValue: transfer.stateRaw) != nil else { continue }
            let feed = FeedURLIdentity.canonical(feedURL)
            let key = DownloadTaskKey.key(feedURL: feed, guid: episode.guid)
            if episodeRows[key] == nil {
                let row = EarshotSchemaV7.LocalEpisodeState(
                    podcastFeedURL: feed,
                    episodeGUID: episode.guid,
                    downloadStatusRaw: transfer.stateRaw
                )
                context.insert(row)
                episodeRows[key] = row
            }
        }

        var localSettings: Set<String> = []
        for setting in try context.fetch(FetchDescriptor<EarshotSchemaV5.AppSetting>())
        where AppSettingScope.isLocal(setting.key) && localSettings.insert(setting.key).inserted {
            context.insert(EarshotSchemaV7.LocalAppSetting(key: setting.key, value: setting.value))
        }
        context.insert(EarshotSchemaV7.LocalAppSetting(key: marker, value: "1"))
        try context.save()
        try StoreMigration.failIfInjected(at: .afterBridgeMarker)
    }
}

/// Restartable retained-column V10 split migration from the supported V5 floor.
/// App Store V5 and TestFlight V6 are snapshotted without mutation; an
/// already-staged V7 and the draft device's V8 are also resumable. The original
/// store stays authoritative until the separate device-local copy has been
/// value-checked and marked durable.
enum StoreMigration {
    static let splitCompletionKey = "__earshot_v8_split_complete"
    static let bridgeCompletionKey = "__earshot_v7_bridge_complete"
    static let identityRepairCompletionKey = "__earshot_identity_repair_v1_complete"

    enum InjectedFailurePoint: String, CaseIterable {
        case beforeCompletedFinalOpen
        case beforeFreshStoreMarkers
        case afterFreshV9MirroredFinalization
        case afterBridgeMarker
        case beforeSplitMarker
        case afterSplitMarker
        case beforeIdentityRepairMarker
        case afterIdentityRepairMarker
    }

    struct InjectedMigrationFailure: Error, Equatable {
        let point: InjectedFailurePoint
    }

    #if DEBUG
    nonisolated(unsafe) static var injectedFailurePoint: InjectedFailurePoint?
    /// Test-only escape hatch used exclusively by the real constrained-volume
    /// ENOSPC test to prove what Core Data does without Earshot's new hard gate.
    nonisolated(unsafe) static var bypassSafetyBackupForENOSPCTest = false
    #endif

    private static var enforcesSafetyBackup: Bool {
        #if DEBUG
        !bypassSafetyBackupForENOSPCTest
        #else
        true
        #endif
    }

    /// Test-only force-quit simulation. The thrown error deliberately arrives
    /// only after the preceding save has returned, matching a process death at
    /// the durable boundary rather than a failed transaction.
    static func failIfInjected(at point: InjectedFailurePoint) throws {
        #if DEBUG
        if injectedFailurePoint == point {
            throw InjectedMigrationFailure(point: point)
        }
        #endif
    }

    /// Emits opt-in stage timings for the migration scale/profile test. Normal
    /// launches do not print these diagnostics.
    private static func profiled<T>(
        _ stage: String, operation: () throws -> T
    ) rethrows -> T {
        let start = DispatchTime.now().uptimeNanoseconds
        defer {
            if ProcessInfo.processInfo.environment["RUN_SYNC_MIGRATION_SCALE"] != nil {
                let milliseconds = Double(
                    DispatchTime.now().uptimeNanoseconds - start
                ) / 1_000_000
                print(String(format:
                    "SYNCMIGRATION_STAGE|%@|milliseconds|%.1f", stage, milliseconds
                ))
            }
        }
        return try operation()
    }

    struct PodcastStateSnapshot: Equatable {
        let feedURL: String
        let refreshedAt: Date?
    }

    struct EpisodeStateSnapshot: Equatable {
        let feedURL: String
        let guid: String
        let statusRaw: String
        let path: String?
    }

    struct SettingSnapshot: Equatable {
        let key: String
        let value: String
    }

    struct BridgeSnapshot: Equatable {
        let podcasts: [PodcastStateSnapshot]
        let episodes: [EpisodeStateSnapshot]
        let settings: [SettingSnapshot]
    }

    static func localStoreURL(for mirroredURL: URL) -> URL {
        mirroredURL.deletingLastPathComponent().appending(path: "earshot-local.store")
    }

    /// True when `error` (or anything in its underlying-error chain) indicates
    /// the store was written by a newer schema than this build can open. SwiftData
    /// wraps the underlying CoreData error, so the whole chain is walked.
    /// `NSPersistentStoreIncompatibleVersionHashError` is the version-hash
    /// mismatch a downgrade produces; `NSMigrationMissingMappingModelError` is a
    /// required-but-unmapped forward migration. Either means "intact store, wrong
    /// (older) app" — never destroy it.
    static func indicatesNewerStore(_ error: Error) -> Bool {
        let incompatibleCodes: Set<Int> = [
            NSPersistentStoreIncompatibleVersionHashError,
            NSMigrationMissingMappingModelError,
        ]
        var current: NSError? = error as NSError
        while let ns = current {
            if ns.domain == NSCocoaErrorDomain && incompatibleCodes.contains(ns.code) {
                return true
            }
            current = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    /// Opens the current split V10 store, advances draft V8/build-162 V9 stores, or
    /// upgrades a supported V5/V6/V7 store through a bounded local-state preflight.
    /// V5 is the evidence-backed production floor: public App Store build 155
    /// created V5, while TestFlight build 161 created V6. Earlier SwiftData
    /// schemas were TestFlight-only and remain outside the supported floor.
    ///
    /// Throws ``StoreOpenError`` when the source is unsupported or genuinely
    /// unreadable. Once source readability or a durable split marker is proven,
    /// later file and migration errors are ``StoreMigrationFailure/operational``
    /// so they cannot be conflated with corrupt-store recovery.
    static func openOrMigrate(
        at url: URL,
        progress: (StoreMigrationProgress) -> Void = { _ in }
    ) throws -> ModelContainer {
        do {
            try MigrationBackupManager.recoverInterruptedErasure(at: url)
            try MigrationBackupManager.recoverInterruptedRestore(at: url)
        } catch {
            throw StoreMigrationFailure.operational(underlying: error)
        }
        let localURL = localStoreURL(for: url)

        // A settled V10 launch needs one final two-store open and the bounded
        // projection of device-local rows. Read-only metadata classification
        // comes first so an older store can never be opened as V10 without the
        // migration safety gate below.
        if FileManager.default.fileExists(atPath: url.path),
           FileManager.default.fileExists(atPath: localURL.path),
           (try? storeMajorVersion(at: url)) == MigrationBackupManager.targetSchemaMajor,
           (try? storeMajorVersion(at: localURL)) == MigrationBackupManager.targetSchemaMajor {
            do {
                let container = try profiled("completed-final-open") {
                    try failIfInjected(at: .beforeCompletedFinalOpen)
                    return try openFinal(mirroredURL: url, localURL: localURL)
                }
                let context = ModelContext(container)
                let splitComplete = LocalAppSettingIdentity.value(
                    for: splitCompletionKey, in: context
                ) == "1"
                let repairComplete = LocalAppSettingIdentity.value(
                    for: identityRepairCompletionKey, in: context
                ) == "1"
                if splitComplete, repairComplete {
                    try profiled("completed-local-state-projection") {
                        try LocalStateStore.hydrate(in: context, repairing: false)
                    }
                    return container
                }
                if !splitComplete {
                    if try isProvenEmptyUnmarkedStore(in: context) {
                        do {
                            try markFreshStoreComplete(in: context)
                        } catch let failure as InjectedMigrationFailure {
                            throw failure
                        } catch {
                            throw StoreMigrationFailure.operational(underlying: error)
                        }
                        return container
                    }
                    throw StoreOpenError.unreadable(
                        underlying: CocoaError(.persistentStoreIncompatibleVersionHash)
                    )
                }
                // A split marker with no repair marker is an interrupted real
                // migration. Fall through to the established resume path.
            } catch let failure as InjectedMigrationFailure
                where failure.point == .beforeFreshStoreMarkers {
                throw failure
            } catch let failure as StoreMigrationFailure {
                throw failure
            } catch let error as StoreOpenError {
                throw error
            } catch {
                if indicatesNewerStore(error) {
                    throw StoreOpenError.storeNewerThanApp(underlying: error)
                }
                if hasSplitCompletionMarker(at: localURL) {
                    throw StoreMigrationFailure.operational(underlying: error)
                }
                throw StoreOpenError.unreadable(underlying: error)
            }
        }

        // A process death inside the initial two-configuration open can leave
        // only one empty V9 or V10 file. Prove the existing configuration empty,
        // advance it when needed, then create and verify the missing companion.
        let mirroredExists = FileManager.default.fileExists(atPath: url.path)
        let localExists = FileManager.default.fileExists(atPath: localURL.path)
        if mirroredExists != localExists {
            let existingURL = mirroredExists ? url : localURL
            if let existingMajor = try? storeMajorVersion(at: existingURL),
               [9, MigrationBackupManager.targetSchemaMajor].contains(existingMajor) {
                do {
                    let existingIsEmpty = if mirroredExists {
                        try isProvenEmptyMirroredStore(at: url, major: existingMajor)
                    } else {
                        try isProvenEmptyLocalStore(at: localURL, major: existingMajor)
                    }
                    guard existingIsEmpty else {
                        throw StoreOpenError.unreadable(
                            underlying: CocoaError(.persistentStoreIncompatibleVersionHash)
                        )
                    }
                    if existingMajor == 9 {
                        if mirroredExists {
                            try finalizeMirroredStore(at: url)
                        } else {
                            try finalizeLocalStore(at: localURL)
                        }
                    }
                    let container = try openFinal(mirroredURL: url, localURL: localURL)
                    let context = ModelContext(container)
                    guard try isProvenEmptyUnmarkedStore(in: context) else {
                        throw StoreOpenError.unreadable(
                            underlying: CocoaError(.persistentStoreIncompatibleVersionHash)
                        )
                    }
                    try markFreshStoreComplete(in: context)
                    return container
                } catch let failure as InjectedMigrationFailure {
                    throw failure
                } catch let failure as StoreMigrationFailure {
                    throw failure
                } catch let error as StoreOpenError {
                    throw error
                } catch {
                    throw StoreMigrationFailure.operational(underlying: error)
                }
            }
        }

        // A durable marker is written only after the separate local store was
        // value-checked. It therefore authorizes mirrored-store finalization and
        // makes every later launch a direct two-store open.
        if profiled("split-marker-probe", operation: {
            hasSplitCompletionMarker(at: localURL)
        }) {
            do {
                let mirroredMajor = try storeMajorVersion(at: url)
                let localMajor = try storeMajorVersion(at: localURL)
                let requiresResume = mirroredMajor < MigrationBackupManager.targetSchemaMajor
                    || localMajor < MigrationBackupManager.targetSchemaMajor
                    || !hasIdentityRepairCompletionMarker(at: localURL)
                if requiresResume {
                    progress(.migratingMirroredStore)
                }
                if enforcesSafetyBackup && requiresResume {
                    do {
                        try MigrationBackupManager.ensureResumeSafety(at: url)
                    } catch {
                        throw classifyBackupPreparationFailure(error)
                    }
                }
                // No-op for V10; advances either an interrupted V7 cutover, the
                // already-installed draft V8 store, or build-162 V9. The
                // draft V8 wrote the full aggregate model metadata into both
                // configuration files, so each file is advanced independently.
                try profiled("resume-mirrored-finalization") {
                    try finalizeMirroredStore(at: url)
                }
                try profiled("resume-local-finalization") {
                    try finalizeLocalStore(at: localURL)
                }
                if requiresResume {
                    progress(.openingAndRepairing)
                }
                return try profiled("resume-final-open") {
                    try finishOpeningFinal(mirroredURL: url, localURL: localURL)
                }
            } catch let failure as InjectedMigrationFailure {
                throw failure
            } catch let failure as StoreMigrationFailure {
                throw failure
            } catch {
                if indicatesNewerStore(error) {
                    throw StoreOpenError.storeNewerThanApp(underlying: error)
                }
                throw StoreMigrationFailure.operational(underlying: error)
            }
        }

        // Build 162 could be killed after creating both fresh V9 files but
        // before saving the split marker (#784). V9 is otherwise never valid
        // without that marker, so advance it only after proving every entity in
        // both stores is empty under the exact frozen V9 schema.
        let unmarkedMirroredMajor = try? storeMajorVersion(at: url)
        let unmarkedLocalMajor = try? storeMajorVersion(at: localURL)
        if let unmarkedMirroredMajor, let unmarkedLocalMajor,
           [9, 10].contains(unmarkedMirroredMajor),
           [9, 10].contains(unmarkedLocalMajor),
           unmarkedMirroredMajor == 9 || unmarkedLocalMajor == 9 {
            do {
                guard try isProvenEmptyMirroredStore(
                    at: url, major: unmarkedMirroredMajor
                ), try isProvenEmptyLocalStore(
                    at: localURL, major: unmarkedLocalMajor
                ) else {
                    throw StoreOpenError.unreadable(
                        underlying: CocoaError(.persistentStoreIncompatibleVersionHash)
                    )
                }
                if unmarkedMirroredMajor == 9 {
                    try finalizeMirroredStore(at: url)
                }
                try failIfInjected(at: .afterFreshV9MirroredFinalization)
                if unmarkedLocalMajor == 9 {
                    try finalizeLocalStore(at: localURL)
                }
                let container = try openFinal(mirroredURL: url, localURL: localURL)
                let context = ModelContext(container)
                guard try isProvenEmptyUnmarkedStore(in: context) else {
                    throw StoreOpenError.unreadable(
                        underlying: CocoaError(.persistentStoreIncompatibleVersionHash)
                    )
                }
                try markFreshStoreComplete(in: context)
                return container
            } catch let failure as InjectedMigrationFailure {
                throw failure
            } catch let error as StoreOpenError {
                throw error
            } catch {
                throw StoreMigrationFailure.operational(underlying: error)
            }
        }

        if !ModelContainerFactory.hasStoreFiles(at: url) {
            do {
                let container = try openFinal(mirroredURL: url, localURL: localURL)
                let context = ModelContext(container)
                try markFreshStoreComplete(in: context)
                return container
            } catch let failure as InjectedMigrationFailure {
                throw failure
            } catch {
                throw StoreMigrationFailure.operational(underlying: error)
            }
        }

        // SQLite can leave WAL/SHM/journal residue without either database file.
        // That is not a source store and must never trigger migration UI, a disk
        // gate, or a backup attempt. Preserve the residue for explicit recovery.
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw StoreOpenError.unreadable(
                underlying: CocoaError(.fileNoSuchFile)
            )
        }

        progress(.preparingAndValidating)
        // The original store remains authoritative until the marker above is
        // durable. A transactionally consistent, validated snapshot and the
        // measured migration working margin are hard prerequisites; no source
        // read that can migrate or write occurs until this succeeds.
        if enforcesSafetyBackup {
            do {
                _ = try profiled("backup-authoritative-store") {
                    try MigrationBackupManager.prepareVerifiedBackup(at: url)
                }
            } catch {
                throw classifyBackupPreparationFailure(error)
            }
        }

        let bridgeSnapshot: BridgeSnapshot
        do {
            bridgeSnapshot = try profiled("pre-split-local-state-preflight") {
                try readBridge(at: url)
            }
            AppLog.data.info("Local-state migration preflight completed")
        } catch let failure as InjectedMigrationFailure {
            throw failure
        } catch let error as StoreOpenError {
            throw error
        } catch {
            if indicatesNewerStore(error) {
                throw StoreOpenError.storeNewerThanApp(underlying: error)
            }
            if indicatesOperationalFailure(error) {
                throw StoreMigrationFailure.operational(underlying: error)
            }
            throw StoreOpenError.unreadable(underlying: error)
        }

        // Rebuild is safe here: V6/V7 still contains every source value. A crash
        // or failed validation simply re-enters this path and reconstructs local.
        do {
            try profiled("local-store-rebuild-and-validation") {
                try rebuildAndValidateLocal(bridgeSnapshot, at: localURL)
            }
        } catch let failure as InjectedMigrationFailure {
            throw failure
        } catch {
            throw StoreMigrationFailure.operational(underlying: error)
        }
        AppLog.data.info("V10 device-local copy validated")
        progress(.migratingMirroredStore)
        do {
            try profiled("mirrored-store-migration") {
                try finalizeMirroredStore(at: url)
            }
        } catch {
            if indicatesNewerStore(error) {
                throw StoreOpenError.storeNewerThanApp(underlying: error)
            }
            throw StoreMigrationFailure.operational(underlying: error)
        }
        AppLog.data.info("V10 mirrored-store cutover completed")
        progress(.openingAndRepairing)
        do {
            return try profiled("final-open-hydrate-and-repair") {
                try finishOpeningFinal(mirroredURL: url, localURL: localURL)
            }
        } catch let failure as InjectedMigrationFailure {
            throw failure
        } catch {
            throw StoreMigrationFailure.operational(underlying: error)
        }
    }

    private static func readBridge(at url: URL) throws -> BridgeSnapshot {
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            type: .sqlite, at: url
        )
        let identifiers = metadata[NSStoreModelVersionIdentifiersKey] as? [String]
        guard let identifier = identifiers?.first,
              let major = Int(identifier.split(separator: ".").first ?? "") else {
            throw CocoaError(.persistentStoreIncompatibleVersionHash)
        }

        switch major {
        case 1...4:
            throw StoreOpenError.storePredatesSupportedSchema(majorVersion: major)
        case 5:
            return try snapshotPreSplitWithoutMigration(
                at: url, version: EarshotSchemaV5.self
            )
        case 6:
            return try snapshotPreSplitWithoutMigration(
                at: url, version: EarshotSchemaV6.self
            )
        case 7:
            return try openAndPopulateBridge(at: url)
        case 10...:
            throw CocoaError(.persistentStoreIncompatibleVersionHash)
        default:
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    /// Reads build 155 V5 or build 161 V6 local-only values without advancing
    /// the authoritative store. The separate local V10 copy is validated and
    /// marked before the original is migrated to retained-column V10, so a crash
    /// before cutover leaves the source untouched and a crash after the marker
    /// resumes at finalization.
    private static func snapshotPreSplitWithoutMigration(
        at url: URL, version: any VersionedSchema.Type
    ) throws -> BridgeSnapshot {
        let schema = Schema(versionedSchema: version)
        return try autoreleasepool {
            let container = try profiled("v6-preflight-container-open") {
                try ModelContainer(
                    for: schema,
                    configurations: ModelConfiguration(
                        schema: schema, url: url, cloudKitDatabase: .none
                    )
                )
            }
            let context = ModelContext(container)

            let podcastRows: [String: PodcastStateSnapshot] = try profiled(
                "v6-preflight-podcast-scan"
            ) {
                var rows: [String: PodcastStateSnapshot] = [:]
                for podcast in try context.fetch(FetchDescriptor<EarshotSchemaV5.Podcast>()) {
                    guard let refreshedAt = podcast.refreshedAt else { continue }
                    let feedURL = FeedURLIdentity.canonical(podcast.feedURL)
                    if let existing = rows[feedURL] {
                        rows[feedURL] = PodcastStateSnapshot(
                            feedURL: feedURL,
                            refreshedAt: max(existing.refreshedAt ?? .distantPast, refreshedAt)
                        )
                    } else {
                        rows[feedURL] = PodcastStateSnapshot(
                            feedURL: feedURL, refreshedAt: refreshedAt
                        )
                    }
                }
                return rows
            }

            var episodeRows: [String: EpisodeStateSnapshot] = try profiled(
                "v6-preflight-downloaded-scan"
            ) {
                var rows: [String: EpisodeStateSnapshot] = [:]
                let downloaded = try context.fetch(FetchDescriptor<EarshotSchemaV5.Episode>(
                    predicate: #Predicate { $0.downloadPath != nil }
                ))
                let downloadedGroups = Dictionary(grouping: downloaded) { episode in
                    let feedURL = episode.podcast.map {
                        FeedURLIdentity.canonical($0.feedURL)
                    }
                    return DownloadTaskKey.key(feedURL: feedURL, guid: episode.guid)
                }
                for group in downloadedGroups.values {
                    guard let episode = DownloadPaths.preferredExistingDownload(
                        from: group,
                        storedValue: \EarshotSchemaV5.Episode.downloadPath,
                        stableID: { String(describing: $0.persistentModelID) }
                    ) else { continue }
                    guard let rawFeedURL = episode.podcast?.feedURL,
                          let path = episode.downloadPath, !path.isEmpty else { continue }
                    let feedURL = FeedURLIdentity.canonical(rawFeedURL)
                    let key = DownloadTaskKey.key(feedURL: feedURL, guid: episode.guid)
                    rows[key] = EpisodeStateSnapshot(
                        feedURL: feedURL, guid: episode.guid,
                        statusRaw: DownloadStatus.downloaded.rawValue, path: path
                    )
                }
                return rows
            }
            try profiled("v6-preflight-active-transfer-scan") {
                for transfer in try context.fetch(
                    FetchDescriptor<EarshotSchemaV5.ActiveDownload>()
                ) {
                    guard let episode = transfer.episode,
                          let rawFeedURL = episode.podcast?.feedURL,
                          ActiveDownloadState(rawValue: transfer.stateRaw) != nil else { continue }
                    let feedURL = FeedURLIdentity.canonical(rawFeedURL)
                    let key = DownloadTaskKey.key(feedURL: feedURL, guid: episode.guid)
                    if episodeRows[key] == nil {
                        episodeRows[key] = EpisodeStateSnapshot(
                            feedURL: feedURL, guid: episode.guid,
                            statusRaw: transfer.stateRaw, path: nil
                        )
                    }
                }
            }

            let settings = try profiled("v6-preflight-settings-scan") {
                var seenSettings: Set<String> = []
                return try context.fetch(FetchDescriptor<EarshotSchemaV5.AppSetting>())
                    .filter {
                        AppSettingScope.isLocal($0.key)
                            && seenSettings.insert($0.key).inserted
                    }
                    .map { SettingSnapshot(key: $0.key, value: $0.value) }
                    .sorted { $0.key < $1.key }
            }

            return BridgeSnapshot(
                podcasts: podcastRows.values.sorted { $0.feedURL < $1.feedURL },
                episodes: episodeRows.values.sorted {
                    ($0.feedURL, $0.guid) < ($1.feedURL, $1.guid)
                },
                settings: settings
            )
        }
    }

    private static func openAndPopulateBridge(at url: URL) throws -> BridgeSnapshot {
        let schema = Schema(versionedSchema: EarshotSchemaV7.self)
        return try autoreleasepool {
            let bridge = try ModelContainer(
                for: schema,
                configurations: ModelConfiguration(
                    schema: schema, url: url, cloudKitDatabase: .none
                )
            )
            let context = ModelContext(bridge)
            try SyncBridgeBackfill.populate(in: context)
            return try snapshotBridge(context)
        }
    }

    private static func snapshotBridge(_ context: ModelContext) throws -> BridgeSnapshot {
        BridgeSnapshot(
            podcasts: try context.fetch(FetchDescriptor<EarshotSchemaV7.LocalPodcastState>())
                .map { PodcastStateSnapshot(feedURL: $0.feedURL, refreshedAt: $0.refreshedAt) }
                .sorted { $0.feedURL < $1.feedURL },
            episodes: try context.fetch(FetchDescriptor<EarshotSchemaV7.LocalEpisodeState>())
                .map { EpisodeStateSnapshot(feedURL: $0.podcastFeedURL, guid: $0.episodeGUID, statusRaw: $0.downloadStatusRaw, path: $0.downloadPath) }
                .sorted { ($0.feedURL, $0.guid) < ($1.feedURL, $1.guid) },
            settings: try context.fetch(FetchDescriptor<EarshotSchemaV7.LocalAppSetting>())
                .filter { $0.key != bridgeCompletionKey }
                .map { SettingSnapshot(key: $0.key, value: $0.value) }
                .sorted { $0.key < $1.key }
        )
    }

    private static func rebuildAndValidateLocal(
        _ expected: BridgeSnapshot, at localURL: URL
    ) throws {
        ModelContainerFactory.removeStoreFiles(at: localURL)
        try autoreleasepool {
            // SwiftData writes aggregate version metadata into each configured
            // file. Open the local URL as the sole full-schema configuration so
            // it gets the same metadata as the later two-store container without
            // creating and prematurely unlinking an empty staging database.
            let full = Schema(versionedSchema: EarshotSchemaV10.self)
            let container = try ModelContainer(
                for: full,
                configurations: ModelConfiguration(
                    "DeviceLocal", schema: full, url: localURL,
                    cloudKitDatabase: .none
                )
            )
            let context = ModelContext(container)
            for row in expected.podcasts {
                context.insert(LocalPodcastState(feedURL: row.feedURL, refreshedAt: row.refreshedAt))
            }
            for row in expected.episodes {
                context.insert(LocalEpisodeState(
                    podcastFeedURL: row.feedURL,
                    episodeGUID: row.guid,
                    downloadStatus: DownloadStatus(rawValue: row.statusRaw) ?? .none,
                    downloadPath: row.path
                ))
            }
            for row in expected.settings {
                context.insert(LocalAppSetting(key: row.key, value: row.value))
            }
            try context.save()
            guard try localSnapshot(in: context) == expected else {
                throw CocoaError(.fileWriteUnknown)
            }
            try failIfInjected(at: .beforeSplitMarker)
            try LocalAppSettingIdentity.setValue("1", for: splitCompletionKey, in: context)
            try context.save()
            try failIfInjected(at: .afterSplitMarker)
        }
    }

    private static func localSnapshot(in context: ModelContext) throws -> BridgeSnapshot {
        BridgeSnapshot(
            podcasts: try context.fetch(FetchDescriptor<LocalPodcastState>())
                .map { PodcastStateSnapshot(feedURL: $0.feedURL, refreshedAt: $0.refreshedAt) }
                .sorted { $0.feedURL < $1.feedURL },
            episodes: try context.fetch(FetchDescriptor<LocalEpisodeState>())
                .map { EpisodeStateSnapshot(feedURL: $0.podcastFeedURL, guid: $0.episodeGUID, statusRaw: $0.downloadStatusRaw, path: $0.downloadPath) }
                .sorted { ($0.feedURL, $0.guid) < ($1.feedURL, $1.guid) },
            settings: try context.fetch(FetchDescriptor<LocalAppSetting>())
                .filter { $0.key != splitCompletionKey }
                .map { SettingSnapshot(key: $0.key, value: $0.value) }
                .sorted { $0.key < $1.key }
        )
    }

    private static func hasSplitCompletionMarker(at localURL: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: localURL.path) else { return false }
        return (try? autoreleasepool {
            let major = try storeMajorVersion(at: localURL)
            if major == 8 {
                // Read the draft marker with the exact frozen V8 graph. Opening
                // it as a newer schema here would silently migrate the local file before the
                // explicit two-file forward route has begun.
                let full = Schema(versionedSchema: EarshotSchemaV8.self)
                let container = try ModelContainer(
                    for: full,
                    configurations: ModelConfiguration(
                        "DeviceLocal", schema: full, url: localURL,
                        cloudKitDatabase: .none
                    )
                )
                let key = splitCompletionKey
                let context = ModelContext(container)
                let rows = try context.fetch(
                    FetchDescriptor<EarshotSchemaV8.LocalAppSetting>(
                        predicate: #Predicate { $0.key == key }
                    )
                )
                return rows.contains { $0.value == "1" }
            }
            if major == 9 {
                let full = Schema(versionedSchema: EarshotSchemaV9.self)
                let container = try ModelContainer(
                    for: full,
                    configurations: ModelConfiguration(
                        "DeviceLocal", schema: full, url: localURL,
                        cloudKitDatabase: .none
                    )
                )
                let key = splitCompletionKey
                let context = ModelContext(container)
                let rows = try context.fetch(
                    FetchDescriptor<EarshotSchemaV9.LocalAppSetting>(
                        predicate: #Predicate { $0.key == key }
                    )
                )
                return rows.contains { $0.value == "1" }
            }
            guard major == 10 else { return false }
            let full = Schema(versionedSchema: EarshotSchemaV10.self)
            let container = try ModelContainer(
                for: full,
                configurations: ModelConfiguration(
                    "DeviceLocal", schema: full, url: localURL,
                    cloudKitDatabase: .none
                )
            )
            return LocalAppSettingIdentity.value(
                for: splitCompletionKey, in: ModelContext(container)
            ) == "1"
        }) ?? false
    }

    private static func hasIdentityRepairCompletionMarker(at localURL: URL) -> Bool {
        guard (try? storeMajorVersion(at: localURL)) == 10 else { return false }
        return (try? autoreleasepool {
            let full = Schema(versionedSchema: EarshotSchemaV10.self)
            let container = try ModelContainer(
                for: full,
                configurations: ModelConfiguration(
                    "DeviceLocal", schema: full, url: localURL,
                    cloudKitDatabase: .none
                )
            )
            return LocalAppSettingIdentity.value(
                for: identityRepairCompletionKey, in: ModelContext(container)
            ) == "1"
        }) ?? false
    }

    private static func openFinal(mirroredURL: URL, localURL: URL) throws -> ModelContainer {
        let full = Schema(versionedSchema: EarshotSchemaV10.self)
        let mirrored = ModelConfiguration(
            "FutureMirrored", schema: Schema(EarshotSchemaV10.mirroredModels),
            url: mirroredURL, cloudKitDatabase: .none
        )
        let local = ModelConfiguration(
            "DeviceLocal", schema: Schema(EarshotSchemaV10.localModels),
            url: localURL, cloudKitDatabase: .none
        )
        return try ModelContainer(for: full, configurations: mirrored, local)
    }

    private static func markFreshStoreComplete(in context: ModelContext) throws {
        try failIfInjected(at: .beforeFreshStoreMarkers)
        try LocalAppSettingIdentity.setValue("1", for: splitCompletionKey, in: context)
        // A new empty store has nothing to repair. Commit both markers together
        // so a force quit can leave only the fully unmarked empty-store shape.
        try LocalAppSettingIdentity.setValue(
            "1", for: identityRepairCompletionKey, in: context
        )
        try context.save()
    }

    /// A force quit can occur after SwiftData creates both V10 files but before
    /// the fresh-store markers are committed. Resume only when every user and
    /// device-local entity is empty; any nonempty unmarked V10 store is routed
    /// to nondestructive recovery instead of being mistaken for a fresh install.
    private static func isProvenEmptyUnmarkedStore(in context: ModelContext) throws -> Bool {
        guard LocalAppSettingIdentity.value(for: splitCompletionKey, in: context) == nil,
              LocalAppSettingIdentity.value(
                for: identityRepairCompletionKey, in: context
              ) == nil else { return false }
        return try context.fetchCount(FetchDescriptor<Podcast>()) == 0
            && context.fetchCount(FetchDescriptor<Episode>()) == 0
            && context.fetchCount(FetchDescriptor<QueueItem>()) == 0
            && context.fetchCount(FetchDescriptor<ListeningSession>()) == 0
            && context.fetchCount(FetchDescriptor<Bookmark>()) == 0
            && context.fetchCount(FetchDescriptor<PodcastFolder>()) == 0
            && context.fetchCount(FetchDescriptor<FolderMembership>()) == 0
            && context.fetchCount(FetchDescriptor<RecentlyExpired>()) == 0
            && context.fetchCount(FetchDescriptor<QuickActionConfig>()) == 0
            && context.fetchCount(FetchDescriptor<AppSetting>()) == 0
            && context.fetchCount(FetchDescriptor<EpisodeFolderMembership>()) == 0
            && context.fetchCount(FetchDescriptor<LocalPodcastState>()) == 0
            && context.fetchCount(FetchDescriptor<LocalEpisodeState>()) == 0
            && context.fetchCount(FetchDescriptor<LocalAppSetting>()) == 0
    }

    private static func isProvenEmptyMirroredStore(at url: URL, major: Int) throws -> Bool {
        return try autoreleasepool {
            switch major {
            case 9:
                let schema = Schema(versionedSchema: EarshotSchemaV9.self)
                let container = try ModelContainer(
                    for: schema,
                    configurations: ModelConfiguration(
                        "FutureMirrored", schema: Schema(EarshotSchemaV9.mirroredModels),
                        url: url, cloudKitDatabase: .none
                    )
                )
                let context = ModelContext(container)
                return try context.fetchCount(FetchDescriptor<EarshotSchemaV9.Podcast>()) == 0
                    && context.fetchCount(FetchDescriptor<EarshotSchemaV9.Episode>()) == 0
                    && context.fetchCount(FetchDescriptor<EarshotSchemaV9.QueueItem>()) == 0
                    && context.fetchCount(
                        FetchDescriptor<EarshotSchemaV9.ListeningSession>()
                    ) == 0
                    && context.fetchCount(FetchDescriptor<EarshotSchemaV9.Bookmark>()) == 0
                    && context.fetchCount(FetchDescriptor<EarshotSchemaV9.PodcastFolder>()) == 0
                    && context.fetchCount(
                        FetchDescriptor<EarshotSchemaV9.FolderMembership>()
                    ) == 0
                    && context.fetchCount(FetchDescriptor<EarshotSchemaV9.RecentlyExpired>()) == 0
                    && context.fetchCount(
                        FetchDescriptor<EarshotSchemaV9.QuickActionConfig>()
                    ) == 0
                    && context.fetchCount(FetchDescriptor<EarshotSchemaV9.AppSetting>()) == 0
                    && context.fetchCount(
                        FetchDescriptor<EarshotSchemaV9.EpisodeFolderMembership>()
                    ) == 0
            case 10:
                let schema = Schema(versionedSchema: EarshotMirroredSchemaV10.self)
                let container = try ModelContainer(
                    for: schema,
                    configurations: ModelConfiguration(
                        "FutureMirrored", schema: schema, url: url,
                        cloudKitDatabase: .none
                    )
                )
                let context = ModelContext(container)
                return try context.fetchCount(FetchDescriptor<Podcast>()) == 0
                    && context.fetchCount(FetchDescriptor<Episode>()) == 0
                    && context.fetchCount(FetchDescriptor<QueueItem>()) == 0
                    && context.fetchCount(FetchDescriptor<ListeningSession>()) == 0
                    && context.fetchCount(FetchDescriptor<Bookmark>()) == 0
                    && context.fetchCount(FetchDescriptor<PodcastFolder>()) == 0
                    && context.fetchCount(FetchDescriptor<FolderMembership>()) == 0
                    && context.fetchCount(FetchDescriptor<RecentlyExpired>()) == 0
                    && context.fetchCount(FetchDescriptor<QuickActionConfig>()) == 0
                    && context.fetchCount(FetchDescriptor<AppSetting>()) == 0
                    && context.fetchCount(FetchDescriptor<EpisodeFolderMembership>()) == 0
            default:
                return false
            }
        }
    }

    private static func isProvenEmptyLocalStore(at url: URL, major: Int) throws -> Bool {
        try autoreleasepool {
            switch major {
            case 9:
                let schema = Schema(versionedSchema: EarshotSchemaV9.self)
                let container = try ModelContainer(
                    for: schema,
                    configurations: ModelConfiguration(
                        "DeviceLocal", schema: Schema(EarshotSchemaV9.localModels),
                        url: url, cloudKitDatabase: .none
                    )
                )
                let context = ModelContext(container)
                return try context.fetchCount(
                    FetchDescriptor<EarshotSchemaV9.LocalPodcastState>()
                ) == 0 && context.fetchCount(
                    FetchDescriptor<EarshotSchemaV9.LocalEpisodeState>()
                ) == 0 && context.fetchCount(
                    FetchDescriptor<EarshotSchemaV9.LocalAppSetting>()
                ) == 0
            case 10:
                let schema = Schema(versionedSchema: EarshotSchemaV10.self)
                let container = try ModelContainer(
                    for: schema,
                    configurations: ModelConfiguration(
                        "DeviceLocal", schema: Schema(EarshotSchemaV10.localModels),
                        url: url, cloudKitDatabase: .none
                    )
                )
                let context = ModelContext(container)
                return try context.fetchCount(FetchDescriptor<LocalPodcastState>()) == 0
                    && context.fetchCount(FetchDescriptor<LocalEpisodeState>()) == 0
                    && context.fetchCount(FetchDescriptor<LocalAppSetting>()) == 0
            default:
                return false
            }
        }
    }

    private static func finalizeMirroredStore(at url: URL) throws {
        try autoreleasepool {
            switch try storeMajorVersion(at: url) {
            case 5:
                // V5 differs from V6 only by the additive episode-folder join
                // and optional folder hierarchy. Let Core Data infer that
                // lightweight addition together with the same retained-column
                // V10 cutover proven for V6. A combined SwiftData staged plan is
                // invalid for this configuration-specific store because its
                // full-graph version checksums do not match the mirrored subset.
                let schema = Schema(versionedSchema: EarshotMirroredSchemaV10.self)
                _ = try ModelContainer(
                    for: schema,
                    configurations: ModelConfiguration(
                        "FutureMirrored", schema: schema, url: url,
                        cloudKitDatabase: .none
                    )
                )
            case 6:
                // V6 already has the two Episode tombstone columns. Use the
                // supported inferred-lightweight route so they are retained and
                // the otherwise unnecessary staged V6→V7 hop is avoided. Core
                // Data may still copy the table for the remaining relationship
                // graph changes; the aged-store performance test measures that.
                let schema = Schema(versionedSchema: EarshotMirroredSchemaV10.self)
                _ = try ModelContainer(
                    for: schema,
                    configurations: ModelConfiguration(
                        "FutureMirrored", schema: schema, url: url,
                        cloudKitDatabase: .none
                    )
                )
            case 7:
                let schema = Schema(versionedSchema: EarshotMirroredSchemaV10.self)
                _ = try ModelContainer(
                    for: schema,
                    migrationPlan: EarshotFinalMigrationPlan.self,
                    configurations: ModelConfiguration(
                        "FutureMirrored", schema: schema, url: url,
                        cloudKitDatabase: .none
                    )
                )
            case 8:
                try migrateFullV8Store(at: url, configurationName: "FutureMirrored")
            case 9:
                try migrateMirroredV9Store(at: url)
            case 10:
                return
            default:
                throw CocoaError(.persistentStoreIncompatibleVersionHash)
            }
        }
    }

    private static func finalizeLocalStore(at url: URL) throws {
        switch try storeMajorVersion(at: url) {
        case 8:
            try migrateFullV8Store(at: url, configurationName: "DeviceLocal")
        case 9:
            try migrateFullV9Store(at: url, configurationName: "DeviceLocal")
        case 10:
            return
        default:
            throw CocoaError(.persistentStoreIncompatibleVersionHash)
        }
    }

    private static func migrateFullV8Store(
        at url: URL, configurationName: String
    ) throws {
        let schema = Schema(versionedSchema: EarshotSchemaV10.self)
        _ = try ModelContainer(
            for: schema,
            migrationPlan: EarshotV8ToV10MigrationPlan.self,
            configurations: ModelConfiguration(
                configurationName, schema: schema, url: url,
                cloudKitDatabase: .none
            )
        )
    }

    private static func migrateFullV9Store(
        at url: URL, configurationName: String
    ) throws {
        let schema = Schema(versionedSchema: EarshotSchemaV10.self)
        _ = try ModelContainer(
            for: schema,
            migrationPlan: EarshotV9ToV10MigrationPlan.self,
            configurations: ModelConfiguration(
                configurationName, schema: schema, url: url,
                cloudKitDatabase: .none
            )
        )
    }

    private static func migrateMirroredV9Store(at url: URL) throws {
        // Required-to-optional nullability has the same Core Data entity
        // checksum, so a staged plan rejects V9/V10 as duplicate versions and
        // Core Data already considers the physical schema compatible. Use its
        // supported metadata API to record the completed V10 transition; the
        // final V10 open immediately afterward performs the compatibility
        // check without opening this large store twice. No table copy or
        // Episode backfill is involved.
        var metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            type: .sqlite, at: url
        )
        metadata[NSStoreModelVersionIdentifiersKey] = ["10.0.0"]
        try NSPersistentStoreCoordinator.setMetadata(
            metadata, forPersistentStoreOfType: NSSQLiteStoreType,
            at: url, options: nil
        )
    }

    private static func storeMajorVersion(at url: URL) throws -> Int {
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            type: .sqlite, at: url
        )
        let identifiers = metadata[NSStoreModelVersionIdentifiersKey] as? [String]
        guard let identifier = identifiers?.first,
              let major = Int(identifier.split(separator: ".").first ?? "") else {
            throw CocoaError(.persistentStoreIncompatibleVersionHash)
        }
        return major
    }

    /// Keeps the safety gate from turning corruption into a misleading storage
    /// error. Only failures that can be resolved by freeing space or retrying
    /// are presented as backup-unavailable; malformed source data stays on the
    /// existing unreadable-store recovery path.
    private static func classifyBackupPreparationFailure(_ error: Error) -> Error {
        if let backupError = error as? MigrationBackupError {
            switch backupError {
            case .insufficientStorage, .restoreFailed:
                return StoreMigrationFailure.backupUnavailable(underlying: backupError)
            case .sourceMetadataUnavailable, .snapshotInvalid:
                return StoreOpenError.unreadable(underlying: backupError)
            case .snapshotFailed(let code, _):
                let sqliteError = NSError(domain: NSSQLiteErrorDomain, code: Int(code))
                if indicatesOperationalFailure(sqliteError) {
                    return StoreMigrationFailure.backupUnavailable(underlying: backupError)
                }
                return StoreOpenError.unreadable(underlying: backupError)
            }
        }
        if indicatesNewerStore(error) {
            return StoreOpenError.storeNewerThanApp(underlying: error)
        }
        if indicatesOperationalFailure(error) {
            return StoreMigrationFailure.backupUnavailable(underlying: error)
        }
        return StoreOpenError.unreadable(underlying: error)
    }

    /// Recognizes transient file-system/database conditions while leaving actual
    /// SQLite corruption (`SQLITE_CORRUPT`/`SQLITE_NOTADB`) on the recovery path.
    /// The full underlying-error chain is inspected because SwiftData and Core
    /// Data commonly wrap the actionable POSIX or SQLite error.
    static func indicatesOperationalFailure(_ error: Error) -> Bool {
        let cocoaCodes: Set<Int> = [
            NSFileReadUnknownError,
            NSFileReadNoPermissionError,
            NSFileReadTooLargeError,
            NSFileWriteUnknownError,
            NSFileWriteNoPermissionError,
            NSFileWriteInvalidFileNameError,
            NSFileWriteFileExistsError,
            NSFileWriteInapplicableStringEncodingError,
            NSFileWriteUnsupportedSchemeError,
            NSFileWriteOutOfSpaceError,
            NSFileWriteVolumeReadOnlyError,
        ]
        let posixCodes = Set([EACCES, EAGAIN, EBUSY, EDQUOT, EINTR, EIO, EMFILE,
                              ENFILE, ENOSPC, ETIMEDOUT].map(Int.init))
        // Primary SQLite result codes. Extended result codes retain the primary
        // code in their low byte.
        let sqliteCodes: Set<Int> = [5, 6, 8, 9, 10, 13, 14, 15]

        var current: NSError? = error as NSError
        while let ns = current {
            if ns.domain == NSCocoaErrorDomain && cocoaCodes.contains(ns.code) {
                return true
            }
            if ns.domain == NSPOSIXErrorDomain && posixCodes.contains(ns.code) {
                return true
            }
            if ns.domain == NSSQLiteErrorDomain && sqliteCodes.contains(ns.code & 0xFF) {
                return true
            }
            current = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    private static func finishOpeningFinal(
        mirroredURL: URL, localURL: URL
    ) throws -> ModelContainer {
        let container = try profiled("final-two-store-open") {
            try openFinal(mirroredURL: mirroredURL, localURL: localURL)
        }
        let context = ModelContext(container)
        // V7's AppSetting table contained both scopes. The local values are now
        // durably validated in LocalAppSetting, so remove their mirrored copies
        // before any future CloudKit configuration can see them.
        try profiled("final-local-setting-cleanup") {
            for setting in try context.fetch(FetchDescriptor<AppSetting>())
            where AppSettingScope.isLocal(setting.key) {
                context.delete(setting)
            }
        }
        try profiled("final-local-state-hydration") {
            try LocalStateStore.hydrate(in: context)
        }
        if LocalAppSettingIdentity.value(
            for: identityRepairCompletionKey, in: context
        ) != "1" {
            _ = try profiled("final-identity-repair") {
                try IdentityRepairService(context: context).repairAll()
            }
            // The repair must be durable before the completion marker. If this
            // save succeeds but the marker save is interrupted, the idempotent
            // repair safely runs again on the next launch.
            if context.hasChanges {
                try profiled("final-repair-and-hydration-save") {
                    try context.save()
                }
            }
            try failIfInjected(at: .beforeIdentityRepairMarker)
            try profiled("final-identity-marker-save") {
                try LocalAppSettingIdentity.setValue(
                    "1", for: identityRepairCompletionKey, in: context
                )
                try context.save()
            }
            try failIfInjected(at: .afterIdentityRepairMarker)
        } else if context.hasChanges {
            try context.save()
        }
        return container
    }

}
