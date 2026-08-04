import CoreData
import Foundation
import SwiftData

/// Why a terminal store-open failure happened, so ``ModelContainerFactory`` can
/// react safely instead of blindly deleting the store (issue #529).
///
/// - ``storeNewerThanApp``: the on-disk store was written by a NEWER schema than
///   this build knows how to open — a downgrade. The store is intact and must
///   never be destroyed; the user just needs a newer app.
/// - ``unreadable``: the store could be opened as neither the current schema nor
///   the original (V1) schema — genuine corruption. Only this case is a
///   candidate for a (backed-up, user-consented) reset.
enum StoreOpenError: Error {
    case storeNewerThanApp(underlying: Error)
    case unreadable(underlying: Error)
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
    }
}

/// Restartable retained-column V9 split migration plus the manual V1 import
/// retained for original SwiftUI stores. Shipped V6 is snapshotted without
/// mutation; an already-staged V7 and the draft device's V8 are also resumable.
/// The original store stays authoritative until the separate device-local copy
/// has been value-checked and marked durable.
enum StoreMigration {
    static let splitCompletionKey = "__earshot_v8_split_complete"
    static let bridgeCompletionKey = "__earshot_v7_bridge_complete"
    static let identityRepairCompletionKey = "__earshot_identity_repair_v1_complete"

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

    // Plain snapshots so no managed objects outlive the V1 container.
    struct PodcastSnapshot {
        var feedURL: String
        var title: String
        var artworkURL: String?
        var podcastDescription: String?
        var createdAt: Date
        var episodes: [EpisodeSnapshot]
    }

    struct EpisodeSnapshot {
        var guid: String
        var title: String
        var audioURL: String
        var episodeDescription: String?
        var pubDate: Date?
        var isPlayed: Bool
    }

    /// Opens the current split V9 store, advances the draft V8 device store, or
    /// upgrades an older store through a bounded local-state preflight. If no
    /// versioned schema can open it, the store is treated as original V1 and
    /// migrated manually. On that path the
    /// original store is backed up (``ModelContainerFactory/backupStoreFiles(at:)``)
    /// before it is deleted, so a failed fresh-store rebuild can't lose the
    /// tester's only copy of the data (#529).
    ///
    /// Throws ``StoreOpenError`` if the store can be opened as neither: a store
    /// written by a newer app is ``StoreOpenError/storeNewerThanApp`` (must not
    /// be destroyed), anything else is ``StoreOpenError/unreadable``. The primary
    /// open error is captured (not swallowed) so the two cases can be told apart.
    @MainActor
    static func openOrMigrate(at url: URL) throws -> ModelContainer {
        let localURL = localStoreURL(for: url)

        // A durable marker is written only after the separate local store was
        // value-checked. It therefore authorizes mirrored-store finalization and
        // makes every later launch a direct two-store open.
        if hasSplitCompletionMarker(at: localURL) {
            do {
                // No-op for V9; advances either an interrupted V7 cutover or
                // the already-installed draft V8 mirrored store to V9. The
                // draft V8 wrote the full aggregate model metadata into both
                // configuration files, so each file is advanced independently.
                try finalizeMirroredStore(at: url)
                try finalizeLocalStore(at: localURL)
                return try finishOpeningFinal(mirroredURL: url, localURL: localURL)
            } catch {
                if indicatesNewerStore(error) {
                    throw StoreOpenError.storeNewerThanApp(underlying: error)
                }
                throw StoreOpenError.unreadable(underlying: error)
            }
        }

        if !FileManager.default.fileExists(atPath: url.path) {
            let container = try openFinal(mirroredURL: url, localURL: localURL)
            try LocalAppSettingIdentity.setValue("1", for: splitCompletionKey, in: container.mainContext)
            // A new empty store has nothing to repair; mark the version complete
            // so the first ordinary reopen does not run a migration-only pass.
            try LocalAppSettingIdentity.setValue(
                "1", for: identityRepairCompletionKey, in: container.mainContext
            )
            try container.mainContext.save()
            return container
        }

        // The original store remains authoritative until the marker above is
        // durable. Back it up before any preflight or finalization work.
        if FileManager.default.fileExists(atPath: url.path) {
            _ = ModelContainerFactory.backupStoreFiles(at: url)
        }

        let bridgeSnapshot: BridgeSnapshot
        do {
            bridgeSnapshot = try readBridge(at: url)
            AppLog.data.info("Local-state migration preflight completed")
        } catch {
            if indicatesNewerStore(error) {
                throw StoreOpenError.storeNewerThanApp(underlying: error)
            }
            return try migrateV1Store(at: url, localURL: localURL, primaryError: error)
        }

        // Rebuild is safe here: V6/V7 still contains every source value. A crash
        // or failed validation simply re-enters this path and reconstructs local.
        try rebuildAndValidateLocal(bridgeSnapshot, at: localURL)
        AppLog.data.info("V9 device-local copy validated")
        try finalizeMirroredStore(at: url)
        AppLog.data.info("V9 mirrored-store cutover completed")
        return try finishOpeningFinal(mirroredURL: url, localURL: localURL)
    }

    @MainActor
    private static func migrateV1Store(
        at url: URL, localURL: URL, primaryError: Error
    ) throws -> ModelContainer {
        let snapshots: [PodcastSnapshot]
        do {
            snapshots = try readV1(at: url)
        } catch {
            throw StoreOpenError.unreadable(underlying: primaryError)
        }

        // Back the V1 store up before replacing it (#529): the snapshots only
        // live in memory, so if the fresh-store build or reinsert below throws,
        // the backup is the only remaining copy of the tester's data. A nil
        // return means there was nothing to copy (empty/absent store) or the
        // copy failed — proceed either way, since deleting the old file is still
        // required to build the fresh store.
        if let backupURL = ModelContainerFactory.backupStoreFiles(at: url) {
            AppLog.data.info("Backed up V1 store to \(backupURL.lastPathComponent, privacy: .public) before replacement")
        } else {
            AppLog.data.info("No V1 store backup made before replacement (store may have been empty or absent)")
        }
        ModelContainerFactory.removeStoreFiles(at: url)
        ModelContainerFactory.removeStoreFiles(at: localURL)
        let container = try openFinal(mirroredURL: url, localURL: localURL)
        try write(snapshots, into: container.mainContext)
        // `write` saves its repair results. Persist both completion markers only
        // afterward, in this separate save.
        try LocalAppSettingIdentity.setValue("1", for: splitCompletionKey, in: container.mainContext)
        try LocalAppSettingIdentity.setValue(
            "1", for: identityRepairCompletionKey, in: container.mainContext
        )
        try container.mainContext.save()
        AppLog.data.info("Migrated \(snapshots.count) podcast(s) from V1 to split V9")
        return container
    }

    @MainActor
    private static func readBridge(at url: URL) throws -> BridgeSnapshot {
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            type: .sqlite, at: url
        )
        let identifiers = metadata[NSStoreModelVersionIdentifiersKey] as? [String]
        guard let identifier = identifiers?.first,
              let major = Int(identifier.split(separator: ".").first ?? "") else {
            throw CocoaError(.persistentStoreIncompatibleVersionHash)
        }

        guard (2...6).contains(major) else {
            if major > 9 { throw CocoaError(.persistentStoreIncompatibleVersionHash) }
            guard major == 7 else { throw CocoaError(.fileReadCorruptFile) }
            return try openAndPopulateBridge(at: url)
        }

        if major == 6 {
            return try snapshotV6WithoutMigration(at: url)
        }
        if (2...5).contains(major) {
            let schema = Schema(versionedSchema: EarshotSchemaV7.self)
            return try autoreleasepool {
                let bridge = try ModelContainer(
                    for: schema,
                    migrationPlan: EarshotBridgeMigrationPlan.self,
                    configurations: ModelConfiguration(
                        schema: schema, url: url, cloudKitDatabase: .none
                    )
                )
                return try snapshotBridge(bridge.mainContext)
            }
        }
        return try openAndPopulateBridge(at: url)
    }

    /// Reads the shipped V6 local-only values without first advancing the
    /// authoritative store to V7. The separate local V9 copy is validated and
    /// marked before the original store is opened as retained-column V9, so a
    /// crash before cutover leaves V6 untouched and a crash after the marker
    /// resumes at finalization.
    @MainActor
    private static func snapshotV6WithoutMigration(at url: URL) throws -> BridgeSnapshot {
        let schema = Schema(versionedSchema: EarshotSchemaV6.self)
        return try autoreleasepool {
            let container = try ModelContainer(
                for: schema,
                configurations: ModelConfiguration(
                    schema: schema, url: url, cloudKitDatabase: .none
                )
            )
            let context = container.mainContext

            var podcastRows: [String: PodcastStateSnapshot] = [:]
            for podcast in try context.fetch(FetchDescriptor<EarshotSchemaV5.Podcast>()) {
                guard let refreshedAt = podcast.refreshedAt else { continue }
                let feedURL = FeedURLIdentity.canonical(podcast.feedURL)
                if let existing = podcastRows[feedURL] {
                    podcastRows[feedURL] = PodcastStateSnapshot(
                        feedURL: feedURL,
                        refreshedAt: max(existing.refreshedAt ?? .distantPast, refreshedAt)
                    )
                } else {
                    podcastRows[feedURL] = PodcastStateSnapshot(
                        feedURL: feedURL, refreshedAt: refreshedAt
                    )
                }
            }

            var episodeRows: [String: EpisodeStateSnapshot] = [:]
            let downloaded = try context.fetch(FetchDescriptor<EarshotSchemaV5.Episode>(
                predicate: #Predicate { $0.downloadPath != nil }
            ))
            for episode in downloaded {
                guard let rawFeedURL = episode.podcast?.feedURL,
                      let path = episode.downloadPath, !path.isEmpty else { continue }
                let feedURL = FeedURLIdentity.canonical(rawFeedURL)
                let key = DownloadTaskKey.key(feedURL: feedURL, guid: episode.guid)
                episodeRows[key] = EpisodeStateSnapshot(
                    feedURL: feedURL, guid: episode.guid,
                    statusRaw: DownloadStatus.downloaded.rawValue, path: path
                )
            }
            for transfer in try context.fetch(FetchDescriptor<EarshotSchemaV5.ActiveDownload>()) {
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

            var seenSettings: Set<String> = []
            let settings = try context.fetch(FetchDescriptor<EarshotSchemaV5.AppSetting>())
                .filter {
                    AppSettingScope.isLocal($0.key)
                        && seenSettings.insert($0.key).inserted
                }
                .map { SettingSnapshot(key: $0.key, value: $0.value) }
                .sorted { $0.key < $1.key }

            return BridgeSnapshot(
                podcasts: podcastRows.values.sorted { $0.feedURL < $1.feedURL },
                episodes: episodeRows.values.sorted {
                    ($0.feedURL, $0.guid) < ($1.feedURL, $1.guid)
                },
                settings: settings
            )
        }
    }

    @MainActor
    private static func openAndPopulateBridge(at url: URL) throws -> BridgeSnapshot {
        let schema = Schema(versionedSchema: EarshotSchemaV7.self)
        return try autoreleasepool {
            let bridge = try ModelContainer(
                for: schema,
                configurations: ModelConfiguration(
                    schema: schema, url: url, cloudKitDatabase: .none
                )
            )
            try SyncBridgeBackfill.populate(in: bridge.mainContext)
            return try snapshotBridge(bridge.mainContext)
        }
    }

    @MainActor
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

    @MainActor
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
            let context = container.mainContext
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
            try LocalAppSettingIdentity.setValue("1", for: splitCompletionKey, in: context)
            try context.save()
        }
    }

    @MainActor
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

    @MainActor
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
                let rows = try container.mainContext.fetch(
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
            return LocalAppSettingIdentity.value(
                for: splitCompletionKey, in: container.mainContext
            ) == "1"
        }) ?? false
    }

    @MainActor
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

    @MainActor
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

    @MainActor
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

    @MainActor
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

    @MainActor
    private static func finishOpeningFinal(
        mirroredURL: URL, localURL: URL
    ) throws -> ModelContainer {
        let container = try openFinal(mirroredURL: mirroredURL, localURL: localURL)
        // V7's AppSetting table contained both scopes. The local values are now
        // durably validated in LocalAppSetting, so remove their mirrored copies
        // before any future CloudKit configuration can see them.
        for setting in try container.mainContext.fetch(FetchDescriptor<AppSetting>())
        where AppSettingScope.isLocal(setting.key) {
            container.mainContext.delete(setting)
        }
        try LocalStateStore.hydrate(in: container.mainContext)
        if LocalAppSettingIdentity.value(
            for: identityRepairCompletionKey, in: container.mainContext
        ) != "1" {
            _ = try IdentityRepairService(context: container.mainContext).repairAll()
            // The repair must be durable before the completion marker. If this
            // save succeeds but the marker save is interrupted, the idempotent
            // repair safely runs again on the next launch.
            if container.mainContext.hasChanges { try container.mainContext.save() }
            try LocalAppSettingIdentity.setValue(
                "1", for: identityRepairCompletionKey, in: container.mainContext
            )
            try container.mainContext.save()
        } else if container.mainContext.hasChanges {
            try container.mainContext.save()
        }
        return container
    }

    /// Reads every podcast and its episodes from a V1 store into snapshots, then
    /// releases the V1 container so the store file can be replaced.
    @MainActor
    static func readV1(at url: URL) throws -> [PodcastSnapshot] {
        let schema = Schema(versionedSchema: EarshotSchemaV1.self)
        var result: [PodcastSnapshot] = []
        try autoreleasepool {
            let container = try ModelContainer(
                for: schema,
                configurations: ModelConfiguration(schema: schema, url: url)
            )
            let context = container.mainContext
            let podcasts = try context.fetch(FetchDescriptor<EarshotSchemaV1.Podcast>())
            result = podcasts.map { podcast in
                PodcastSnapshot(
                    feedURL: podcast.feedURL,
                    title: podcast.title,
                    artworkURL: podcast.artworkURL,
                    podcastDescription: podcast.podcastDescription,
                    createdAt: podcast.createdAt,
                    episodes: podcast.episodes.map { episode in
                        EpisodeSnapshot(
                            guid: episode.guid,
                            title: episode.title,
                            audioURL: episode.audioURL,
                            episodeDescription: episode.episodeDescription,
                            pubDate: episode.pubDate,
                            isPlayed: episode.isPlayed
                        )
                    }
                )
            }
        }
        return result
    }

    /// Inserts snapshots as V2 objects, backfilling the new fields.
    @MainActor
    static func write(_ snapshots: [PodcastSnapshot], into context: ModelContext) throws {
        for snapshot in snapshots {
            let resolved = try PodcastIdentityService(context: context).fetchOrCreate(
                feedURL: snapshot.feedURL
            ) { canonicalFeedURL in
                Podcast(
                    feedURL: canonicalFeedURL,
                    title: snapshot.title,
                    podcastDescription: snapshot.podcastDescription,
                    artworkURL: snapshot.artworkURL,
                    createdAt: snapshot.createdAt
                )
            }
            let podcast = resolved.podcast
            if !resolved.inserted {
                // A V1 store can contain semantically identical URL variants.
                // Keep the stable oldest row while allowing the newer snapshot's
                // metadata to fill gaps; user played state is merged per episode.
                if snapshot.createdAt >= podcast.createdAt, !snapshot.title.isEmpty {
                    podcast.title = snapshot.title
                }
                podcast.podcastDescription = snapshot.podcastDescription
                    ?? podcast.podcastDescription
                podcast.artworkURL = snapshot.artworkURL ?? podcast.artworkURL
                podcast.createdAt = min(podcast.createdAt, snapshot.createdAt)
            }
            for snap in snapshot.episodes {
                if let existing = podcast.episodes?.first(where: { $0.guid == snap.guid }) {
                    if snap.isPlayed { existing.isPlayed = true }
                    if (snap.pubDate ?? .distantPast) >= (existing.pubDate ?? .distantPast) {
                        if !snap.title.isEmpty { existing.title = snap.title }
                        if !snap.audioURL.isEmpty { existing.audioURL = snap.audioURL }
                        existing.episodeDescription = snap.episodeDescription
                            ?? existing.episodeDescription
                        existing.pubDate = snap.pubDate ?? existing.pubDate
                    }
                    continue
                }
                let episode = Episode(
                    guid: snap.guid,
                    title: snap.title,
                    audioURL: snap.audioURL,
                    episodeDescription: snap.episodeDescription,
                    pubDate: snap.pubDate,
                    // Best available signal for ordering; the old schema had no
                    // createdAt.
                    createdAt: snap.pubDate ?? .now
                )
                episode.podcast = podcast
                // Map the old stored `isPlayed` into the new status enum;
                // `isPlayed`'s setter keeps `status` and `playedAt` consistent.
                if snap.isPlayed { episode.isPlayed = true }
                context.insert(episode)
            }
        }
        _ = try IdentityRepairService(context: context).repairAll()
        try context.save()
    }
}
