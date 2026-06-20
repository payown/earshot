import Foundation
import SwiftData

/// Version 1 of the Earshot SwiftData schema. New schema versions are added as
/// additional `VersionedSchema` types and wired into ``EarshotMigrationPlan``
/// so on-device data from prior SwiftUI builds survives upgrades — the store is
/// never deleted and recreated.
enum EarshotSchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)

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

/// The migration plan. Today there is a single schema version; future schema
/// changes add a version here plus a `MigrationStage` (prefer lightweight).
enum EarshotMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [EarshotSchemaV1.self]
    }

    static var stages: [MigrationStage] {
        []
    }
}
