import Foundation
import SwiftData

/// Store open + manual V1 migration (issues #355, #425).
///
/// The current schema is ``EarshotSchemaV3`` and the normal open path runs the
/// ``EarshotMigrationPlan`` (V2→V3 is a SwiftData-native lightweight stage, so it
/// migrates rather than aborts). SwiftData still can't infer the original V1→V2
/// jump (2 entities become 10, with new non-optional attributes), so a store
/// still at the original V1 schema is handled here by a manual export/reimport:
/// read it through ``EarshotSchemaV1``, snapshot it into plain values, replace
/// the store file, and reinsert the data as current (V3) objects. This preserves
/// the tester's subscriptions, episodes, and played state.
enum StoreMigration {

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

    /// Opens the store at `url` as the current schema (V3) using
    /// ``EarshotMigrationPlan`` (so a V2 store is lightweight-migrated forward).
    /// If that fails, the store is treated as an original (V1) store and migrated
    /// manually via export/reimport. Throws if the store can be opened as
    /// neither.
    @MainActor
    static func openOrMigrate(at url: URL) throws -> ModelContainer {
        let schema = Schema(versionedSchema: EarshotSchemaV3.self)

        // Fresh installs, already-V3 stores, and V2 stores (lightweight V2→V3)
        // all open through the migration plan.
        if let container = try? ModelContainer(
            for: schema,
            migrationPlan: EarshotMigrationPlan.self,
            configurations: ModelConfiguration(schema: schema, url: url)
        ) {
            return container
        }

        // Otherwise treat it as an original (V1) store and migrate it manually.
        let snapshots = try readV1(at: url)
        ModelContainerFactory.removeStoreFiles(at: url)
        let container = try ModelContainer(
            for: schema,
            migrationPlan: EarshotMigrationPlan.self,
            configurations: ModelConfiguration(schema: schema, url: url)
        )
        try write(snapshots, into: container.mainContext)
        AppLog.data.info("Migrated \(snapshots.count) podcast(s) from V1 to V3")
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
