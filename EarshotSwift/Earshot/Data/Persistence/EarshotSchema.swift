import Foundation
import SwiftData

/// Version 2 — the current Earshot SwiftData schema (the full model graph).
///
/// The original shipped schema is preserved in ``EarshotSchemaV1`` (only
/// `Podcast` + `Episode`, with `Episode.isPlayed` and no `Episode.createdAt`).
///
/// V1→V2 is **not** a lightweight migration: it turns 2 entities into 10 and
/// adds many non-optional attributes. SwiftData's lightweight migration cannot
/// add a non-optional attribute (it does not honour Swift property defaults as
/// store defaults — verified in `StoreMigrationTests`), so the upgrade is done
/// as a manual export/reimport in ``StoreMigration`` rather than via a
/// `SchemaMigrationPlan`. Future additive changes (V3+) that only add optional
/// fields or new entities can use a lightweight `SchemaMigrationPlan`.
enum EarshotSchemaV2: VersionedSchema {
    static var versionIdentifier = Schema.Version(2, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            Podcast.self,
            Episode.self,
            QueueItem.self,
            ListeningSession.self,
            Bookmark.self,
            PodcastFolder.self,
            FolderMembership.self,
            RecentlyExpired.self,
            QuickActionConfig.self,
            AppSetting.self,
        ]
    }
}
