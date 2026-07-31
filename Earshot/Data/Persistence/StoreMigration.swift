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

/// Store open + manual V1 migration (issues #355, #425).
///
/// The current schema is ``EarshotSchemaV5`` and the normal open path runs the
/// ``EarshotMigrationPlan``, which registers four stages: V1→V2 (a `.custom`
/// no-op marker), then V2→V3, V3→V4 and V4→V5 (all SwiftData-native lightweight
/// stages, so a V2, V3 or V4 store migrates rather than aborts). V4→V5 adds the
/// ``ActiveDownload`` entity and nothing else (#701) — `Episode` is untouched, so
/// a large library's episode rows are never rewritten by it.
///
/// SwiftData still can't infer the original V1→V2 jump (2 entities become 10,
/// with new non-optional attributes), so a store still at the original V1 schema
/// is handled here by a manual export/reimport: read it through
/// ``EarshotSchemaV1``, snapshot it into plain values, replace the store file,
/// and reinsert the data as current (V5) objects. This preserves the tester's
/// subscriptions, episodes, and played state.
enum StoreMigration {

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

    /// Opens the store at `url` as the current schema (V5) using
    /// ``EarshotMigrationPlan`` (so a V2 or V3 store is lightweight-migrated
    /// forward). If that fails, the store is treated as an original (V1) store
    /// and migrated manually via export/reimport. On the manual V1 path the
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
        let schema = Schema(versionedSchema: EarshotSchemaV5.self)

        // Fresh installs, already-V5 stores, and V2/V3/V4 stores (lightweight)
        // all open through the migration plan. Capture the failure so a
        // newer-than-app store can be distinguished from real corruption below,
        // rather than silently falling through to the (destructive) V1 path.
        let primaryError: Error
        do {
            return try ModelContainer(
                for: schema,
                migrationPlan: EarshotMigrationPlan.self,
                configurations: ModelConfiguration(schema: schema, url: url)
            )
        } catch {
            primaryError = error
        }

        // A store newer than this build never gets the V1 treatment (a V1 read
        // would fail and mislead) and must never be deleted — surface it.
        if indicatesNewerStore(primaryError) {
            throw StoreOpenError.storeNewerThanApp(underlying: primaryError)
        }

        // Otherwise try to treat it as an original (V1) store and migrate it
        // manually. If it reads as V1, migrate; if not, it is genuinely
        // unreadable — report that WITHOUT touching the file.
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
        let container = try ModelContainer(
            for: schema,
            migrationPlan: EarshotMigrationPlan.self,
            configurations: ModelConfiguration(schema: schema, url: url)
        )
        try write(snapshots, into: container.mainContext)
        AppLog.data.info("Migrated \(snapshots.count) podcast(s) from V1 to V5")
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
            let podcast = Podcast(
                feedURL: snapshot.feedURL,
                title: snapshot.title,
                podcastDescription: snapshot.podcastDescription,
                artworkURL: snapshot.artworkURL,
                createdAt: snapshot.createdAt
            )
            context.insert(podcast)
            for snap in snapshot.episodes {
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
        try context.save()
    }
}
