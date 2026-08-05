import CoreData
import Foundation
import SwiftData

/// Why a terminal store-open failure happened, so ``ModelContainerFactory`` can
/// react safely instead of blindly deleting the store (issue #529).
///
/// - ``storeNewerThanApp``: the on-disk store was written by a NEWER schema than
///   this build knows how to open — a downgrade. The store is intact and must
///   never be destroyed; the user just needs a newer app.
/// - ``storePredatesSupportedSchema``: the store predates the first public
///   schema. It is left intact so the recovery UI can offer a backed-up reset
///   and OPML re-import rather than attempting an unsupported migration.
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

/// Restartable retained-column V9 split migration from the supported V6 floor.
/// Shipped V6 is snapshotted without mutation; an already-staged V7 and the
/// draft device's V8 are also resumable. The original store stays authoritative
/// until the separate device-local copy has been value-checked and marked durable.
enum StoreMigration {
    static let splitCompletionKey = "__earshot_v8_split_complete"
    static let bridgeCompletionKey = "__earshot_v7_bridge_complete"
    static let identityRepairCompletionKey = "__earshot_identity_repair_v1_complete"

    enum InjectedFailurePoint: String, CaseIterable {
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
    #endif

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

    /// Opens the current split V9 store, advances the draft V8 device store, or
    /// upgrades a supported V6/V7 store through a bounded local-state preflight.
    /// Stores older than V6 are rejected without mutation; build 157 was the
    /// first public App Store build and shipped V6, so earlier schemas were
    /// TestFlight-only and are deliberately outside the supported migration floor.
    ///
    /// Throws ``StoreOpenError`` when the source is unsupported or genuinely
    /// unreadable. Once source readability or a durable split marker is proven,
    /// later file and migration errors are ``StoreMigrationFailure/operational``
    /// so they cannot be conflated with corrupt-store recovery.
    static func openOrMigrate(
        at url: URL,
        progress: (StoreMigrationProgress) -> Void = { _ in }
    ) throws -> ModelContainer {
        let localURL = localStoreURL(for: url)

        // A durable marker is written only after the separate local store was
        // value-checked. It therefore authorizes mirrored-store finalization and
        // makes every later launch a direct two-store open.
        if profiled("split-marker-probe", operation: {
            hasSplitCompletionMarker(at: localURL)
        }) {
            progress(.migratingMirroredStore)
            do {
                // No-op for V9; advances either an interrupted V7 cutover or
                // the already-installed draft V8 mirrored store to V9. The
                // draft V8 wrote the full aggregate model metadata into both
                // configuration files, so each file is advanced independently.
                try profiled("resume-mirrored-finalization") {
                    try finalizeMirroredStore(at: url)
                }
                try profiled("resume-local-finalization") {
                    try finalizeLocalStore(at: localURL)
                }
                progress(.openingAndRepairing)
                return try profiled("resume-final-open") {
                    try finishOpeningFinal(mirroredURL: url, localURL: localURL)
                }
            } catch let failure as InjectedMigrationFailure {
                throw failure
            } catch {
                if indicatesNewerStore(error) {
                    throw StoreOpenError.storeNewerThanApp(underlying: error)
                }
                throw StoreMigrationFailure.operational(underlying: error)
            }
        }

        if !FileManager.default.fileExists(atPath: url.path) {
            progress(.openingAndRepairing)
            do {
                let container = try openFinal(mirroredURL: url, localURL: localURL)
                let context = ModelContext(container)
                try LocalAppSettingIdentity.setValue(
                    "1", for: splitCompletionKey, in: context
                )
                // A new empty store has nothing to repair; mark the version complete
                // so the first ordinary reopen does not run a migration-only pass.
                try LocalAppSettingIdentity.setValue(
                    "1", for: identityRepairCompletionKey, in: context
                )
                try context.save()
                return container
            } catch {
                throw StoreMigrationFailure.operational(underlying: error)
            }
        }

        progress(.preparingAndValidating)
        // The original store remains authoritative until the marker above is
        // durable. Back it up before any preflight or finalization work.
        if FileManager.default.fileExists(atPath: url.path) {
            _ = profiled("backup-authoritative-store") {
                ModelContainerFactory.backupStoreFiles(at: url)
            }
        }

        let bridgeSnapshot: BridgeSnapshot
        do {
            bridgeSnapshot = try profiled("v6-local-state-preflight") {
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
        AppLog.data.info("V9 device-local copy validated")
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
        AppLog.data.info("V9 mirrored-store cutover completed")
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
        case 1...5:
            // Build 157 was Earshot's first public App Store build and shipped
            // schema V6. V1–V5 existed only on TestFlight and personal devices,
            // so their migration routes are intentionally removed rather than
            // left partially supported.
            throw StoreOpenError.storePredatesSupportedSchema(majorVersion: major)
        case 6:
            return try snapshotV6WithoutMigration(at: url)
        case 7:
            return try openAndPopulateBridge(at: url)
        case 10...:
            throw CocoaError(.persistentStoreIncompatibleVersionHash)
        default:
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    /// Reads the shipped V6 local-only values without first advancing the
    /// authoritative store to V7. The separate local V9 copy is validated and
    /// marked before the original store is opened as retained-column V9, so a
    /// crash before cutover leaves V6 untouched and a crash after the marker
    /// resumes at finalization.
    private static func snapshotV6WithoutMigration(at url: URL) throws -> BridgeSnapshot {
        let schema = Schema(versionedSchema: EarshotSchemaV6.self)
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
            let full = Schema(versionedSchema: EarshotSchemaV9.self)
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
                // it as V9 here would silently migrate the local file before the
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
            guard major == 9 else { return false }
            let full = Schema(versionedSchema: EarshotSchemaV9.self)
            let container = try ModelContainer(
                for: full,
                configurations: ModelConfiguration(
                    "DeviceLocal", schema: full, url: localURL,
                    cloudKitDatabase: .none
                )
            )
            let context = ModelContext(container)
            return LocalAppSettingIdentity.value(for: splitCompletionKey, in: context) == "1"
        }) ?? false
    }

    private static func openFinal(mirroredURL: URL, localURL: URL) throws -> ModelContainer {
        let full = Schema(versionedSchema: EarshotSchemaV9.self)
        let mirrored = ModelConfiguration(
            "FutureMirrored", schema: Schema(EarshotSchemaV9.mirroredModels),
            url: mirroredURL, cloudKitDatabase: .none
        )
        let local = ModelConfiguration(
            "DeviceLocal", schema: Schema(EarshotSchemaV9.localModels),
            url: localURL, cloudKitDatabase: .none
        )
        return try ModelContainer(for: full, configurations: mirrored, local)
    }

    private static func finalizeMirroredStore(at url: URL) throws {
        try autoreleasepool {
            switch try storeMajorVersion(at: url) {
            case 6:
                // V6 already has the two Episode tombstone columns. Use the
                // supported inferred-lightweight route so they are retained and
                // the otherwise unnecessary staged V6→V7 hop is avoided. Core
                // Data may still copy the table for the remaining relationship
                // graph changes; the aged-store performance test measures that.
                let schema = Schema(versionedSchema: EarshotMirroredSchemaV9.self)
                _ = try ModelContainer(
                    for: schema,
                    configurations: ModelConfiguration(
                        "FutureMirrored", schema: schema, url: url,
                        cloudKitDatabase: .none
                    )
                )
            case 7:
                let schema = Schema(versionedSchema: EarshotMirroredSchemaV9.self)
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
            return
        default:
            throw CocoaError(.persistentStoreIncompatibleVersionHash)
        }
    }

    private static func migrateFullV8Store(
        at url: URL, configurationName: String
    ) throws {
        let schema = Schema(versionedSchema: EarshotSchemaV9.self)
        _ = try ModelContainer(
            for: schema,
            migrationPlan: EarshotV8ToV9MigrationPlan.self,
            configurations: ModelConfiguration(
                configurationName, schema: schema, url: url,
                cloudKitDatabase: .none
            )
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
            NSUserCancelledError,
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
