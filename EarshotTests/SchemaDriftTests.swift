import XCTest
import SwiftData
@testable import Earshot

/// Guards the V8 live graph against an unversioned model edit (#425) and audits
/// the exact compatibility rules required before the mirrored configuration may
/// be switched from `.none` to CloudKit in a later phase.
@MainActor
final class SchemaDriftTests: XCTestCase {

    /// The live model graph, kept in lockstep with `EarshotSchemaV6.models`.
    private static let liveModels: [any PersistentModel.Type] = [
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
        EpisodeFolderMembership.self,
        LocalPodcastState.self,
        LocalEpisodeState.self,
        LocalAppSetting.self,
    ]

    /// `entityName.attributeName` -> `isOptional|valueType` for every attribute.
    private func attributeMap(_ schema: Schema) -> [String: String] {
        var result: [String: String] = [:]
        for entity in schema.entities {
            for attr in entity.attributes {
                result["\(entity.name).\(attr.name)"] =
                    "\(attr.isOptional)|\(String(describing: attr.valueType))"
            }
        }
        return result
    }

    /// `entityName` -> sorted `relationshipName` list, for every entity.
    private func relationshipMap(_ schema: Schema) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for entity in schema.entities {
            result[entity.name] = entity.relationships.map(\.name).sorted()
        }
        return result
    }

    func testLiveAttributesMatchV8() {
        let frozenV8 = attributeMap(Schema(versionedSchema: EarshotSchemaV8.self))
        let live = attributeMap(Schema(Self.liveModels))
        XCTAssertEqual(live, frozenV8)
    }

    /// The load-bearing half of the folders-phase-1 design: `Episode` must be
    /// COMPLETELY untouched, so a real library's ~242k episode rows are never
    /// rewritten by the migration. ``EpisodeFolderMembership/episode`` is
    /// deliberately one-way — an `@Relationship(inverse:)` collection on
    /// `Episode` would change `Episode`'s shape and undo exactly that (#701/#751).
    func testEpisodeShapeMatchesV8() {
        let frozenV8 = Schema(versionedSchema: EarshotSchemaV8.self)
        let live = Schema(Self.liveModels)

        let frozenAttrs = attributeMap(frozenV8).filter { $0.key.hasPrefix("Episode.") }
        let liveAttrs = attributeMap(live).filter { $0.key.hasPrefix("Episode.") }
        XCTAssertEqual(liveAttrs, frozenAttrs)
        XCTAssertEqual(relationshipMap(live)["Episode"], relationshipMap(frozenV8)["Episode"])
    }

    /// The V5→V6 relationship delta: `PodcastFolder` gains exactly `parent` and
    /// `children`, and NO other entity's relationships move.
    func testLiveRelationshipsMatchV8() {
        let frozenV8 = relationshipMap(Schema(versionedSchema: EarshotSchemaV8.self))
        let live = relationshipMap(Schema(Self.liveModels))
        XCTAssertEqual(live, frozenV8)
    }

    /// Guards the lockstep assumption: the live list this test compares against
    /// must equal what `EarshotSchemaV6` actually registers, by entity name.
    func testLiveListMatchesV8ModelsList() {
        let v8Names = Set(Schema(versionedSchema: EarshotSchemaV8.self).entities.map(\.name))
        let liveNames = Set(Schema(Self.liveModels).entities.map(\.name))
        XCTAssertEqual(v8Names, liveNames)
    }

}

@MainActor
final class CloudKitSchemaCompatibilityTests: XCTestCase {
    func testV8MirroredSchemaIsCloudKitCompatible() {
        for entity in Schema(EarshotSchemaV8.mirroredModels).entities {
            for attribute in entity.attributes {
                XCTAssertFalse(attribute.options.contains(.unique), "Unique: \(entity.name).\(attribute.name)")
                XCTAssertTrue(attribute.isOptional || attribute.defaultValue != nil,
                              "Missing default: \(entity.name).\(attribute.name)")
            }
            for relationship in entity.relationships {
                XCTAssertTrue(relationship.isOptional, "Required: \(entity.name).\(relationship.name)")
                XCTAssertNotNil(relationship.inverseName, "No inverse: \(entity.name).\(relationship.name)")
                XCTAssertNotEqual(relationship.deleteRule, .deny)
            }
        }
    }

    func testV8LocalSchemaHasNoRelationshipsAndSplitContainerConstructs() throws {
        let local = Schema(EarshotSchemaV8.localModels)
        XCTAssertTrue(local.entities.allSatisfy { $0.relationships.isEmpty })
        let container = try ModelContainerFactory.makeInMemory()
        XCTAssertEqual(container.configurations.count, 2)
        container.mainContext.insert(Podcast(feedURL: "https://example.com/feed", title: "Show"))
        container.mainContext.insert(LocalAppSetting(key: "cache", value: "local"))
        try container.mainContext.save()
    }
}

// MARK: - Sync A1 storage-topology prototype (#769)

/// Test-only model graph proving the proposed split-store topology before any
/// live `@Model` changes. The mirrored side deliberately contains no download
/// path or transfer state. The local side uses natural-key scalars and has no
/// relationships to mirrored models, because SwiftData cannot persist a
/// relationship across model configurations.
@Model
private final class SyncPrototypePodcast {
    var feedURL = ""
    var title = ""
    var author: String?
    var podcastDescription: String?
    var artworkURL: String?
    var websiteURL: String?
    var language: String?
    var category: String?
    var autoQueue = false
    var notificationEnabled: Bool?
    var speedOverride: Double?
    var trimSilenceOverride: Bool?
    var introSkipSeconds: Int?
    var queueAgeLimitDays: Int?
    var inboxMaxEpisodes: Int?
    var inboxAgeLimitHours: Int?
    var inboxExcluded = false
    var inboxIncluded = false
    var createdAt = Date.distantPast
    var lastSeenPubDate: Date?

    @Relationship(deleteRule: .cascade, inverse: \SyncPrototypeEpisode.podcast)
    var episodes: [SyncPrototypeEpisode]?
    @Relationship(deleteRule: .nullify, inverse: \SyncPrototypeListeningSession.podcast)
    var listeningSessions: [SyncPrototypeListeningSession]?
    @Relationship(deleteRule: .nullify, inverse: \SyncPrototypeFolderMembership.podcast)
    var folderMemberships: [SyncPrototypeFolderMembership]?

    init() {}
}

@Model
private final class SyncPrototypeEpisode {
    var guid = ""
    var title = ""
    var episodeDescription: String?
    var audioURL = ""
    var durationSeconds: Int?
    var pubDate: Date?
    var artworkURL: String?
    var episodeNumber: Int?
    var seasonNumber: Int?
    var chapterURL: String?
    var transcriptURL: String?
    var status: EpisodeStatus = EpisodeStatus.newEpisode
    var positionSeconds = 0
    var playedAt: Date?
    var inboxDismissed = false
    var createdAt = Date.distantPast

    var podcast: SyncPrototypePodcast?
    @Relationship(deleteRule: .cascade, inverse: \SyncPrototypeQueueItem.episode)
    var queueItem: SyncPrototypeQueueItem?
    @Relationship(deleteRule: .cascade, inverse: \SyncPrototypeBookmark.episode)
    var bookmarks: [SyncPrototypeBookmark]?
    @Relationship(deleteRule: .cascade, inverse: \SyncPrototypeRecentlyExpired.episode)
    var recentlyExpired: SyncPrototypeRecentlyExpired?
    @Relationship(deleteRule: .nullify, inverse: \SyncPrototypeListeningSession.episode)
    var listeningSessions: [SyncPrototypeListeningSession]?
    @Relationship(deleteRule: .nullify, inverse: \SyncPrototypeEpisodeFolderMembership.episode)
    var folderMemberships: [SyncPrototypeEpisodeFolderMembership]?

    init() {}
}

@Model
private final class SyncPrototypeQueueItem {
    var episode: SyncPrototypeEpisode?
    var position = 0
    var addedAt = Date.distantPast

    init() {}
}

@Model
private final class SyncPrototypeListeningSession {
    var episode: SyncPrototypeEpisode?
    var podcast: SyncPrototypePodcast?
    var durationSeconds = 0
    var speed = 1.0
    var date = Date.distantPast

    init() {}
}

@Model
private final class SyncPrototypeBookmark {
    var episode: SyncPrototypeEpisode?
    var positionSeconds = 0
    var note = ""
    var createdAt = Date.distantPast

    init() {}
}

@Model
private final class SyncPrototypeFolder {
    var name = ""
    var sortOrder = 0
    var queueAgeLimitDays: Int?
    var createdAt = Date.distantPast

    @Relationship(deleteRule: .cascade, inverse: \SyncPrototypeFolderMembership.folder)
    var memberships: [SyncPrototypeFolderMembership]?
    @Relationship(deleteRule: .cascade, inverse: \SyncPrototypeEpisodeFolderMembership.folder)
    var episodeMemberships: [SyncPrototypeEpisodeFolderMembership]?
    @Relationship(deleteRule: .nullify, inverse: \SyncPrototypeFolder.children)
    var parent: SyncPrototypeFolder?
    @Relationship(deleteRule: .nullify)
    var children: [SyncPrototypeFolder]?

    init() {}
}

@Model
private final class SyncPrototypeFolderMembership {
    var folder: SyncPrototypeFolder?
    var podcast: SyncPrototypePodcast?
    var sortOrder = 0

    init() {}
}

@Model
private final class SyncPrototypeRecentlyExpired {
    var episode: SyncPrototypeEpisode?
    var expiredAt = Date.distantPast

    init() {}
}

@Model
private final class SyncPrototypeQuickActionConfig {
    var contentType: QuickActionContentType = QuickActionContentType.episode
    var actionKey = ""
    var sortOrder = 0

    init() {}
}

@Model
private final class SyncPrototypeSetting {
    var key = ""
    var value = ""

    init() {}
}

@Model
private final class SyncPrototypeEpisodeFolderMembership {
    var folder: SyncPrototypeFolder?
    var episode: SyncPrototypeEpisode?
    var sortOrder = 0

    init() {}
}

/// Local feed-refresh bookkeeping, separated from mirrored `Podcast`.
@Model
private final class SyncPrototypeLocalPodcastState {
    var feedURL = ""
    var refreshedAt: Date?

    init() {}
}

/// Local download state, keyed without a relationship into the mirrored store.
/// A raw string makes active-transfer queries store-evaluable and lets V7 retire
/// the redundant relationship-backed `ActiveDownload` table.
@Model
private final class SyncPrototypeLocalEpisodeState {
    var podcastFeedURL = ""
    var episodeGUID = ""
    var downloadStatusRaw = "none"
    var downloadPath: String?

    init() {}
}

@Model
private final class SyncPrototypeLocalSetting {
    var key = ""
    var value = ""

    init() {}
}

/// Minimal on-disk proof for the proposed two-stage transfer. V7 retains the
/// source value and adds a bridge entity in the original store. App-controlled
/// preflight then copies those scalars into the separate local store before the
/// lightweight V8 stage removes the mirrored source and bridge.
private enum SyncSplitPrototypeV6: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [Item.self] }

    @Model
    final class Item {
        var key: String
        var deviceValue: String?

        init(key: String, deviceValue: String? = nil) {
            self.key = key
            self.deviceValue = deviceValue
        }
    }
}

private enum SyncSplitPrototypeV7: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] {
        [SyncSplitPrototypeV6.Item.self, LocalState.self]
    }

    @Model
    final class LocalState {
        var key = ""
        var deviceValue: String?

        init(key: String = "", deviceValue: String? = nil) {
            self.key = key
            self.deviceValue = deviceValue
        }
    }
}

private enum SyncSplitPrototypeV8: VersionedSchema {
    static let versionIdentifier = Schema.Version(3, 0, 0)
    static var models: [any PersistentModel.Type] { [Item.self, LocalState.self] }

    @Model
    final class Item {
        var key = ""

        init(key: String = "") { self.key = key }
    }

    @Model
    final class LocalState {
        var key = ""
        var deviceValue: String?

        init(key: String = "", deviceValue: String? = nil) {
            self.key = key
            self.deviceValue = deviceValue
        }
    }
}

private enum SyncSplitPrototypePlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [SyncSplitPrototypeV6.self, SyncSplitPrototypeV7.self, SyncSplitPrototypeV8.self]
    }

    static var stages: [MigrationStage] { [bridge, finalize] }

    static let bridge = MigrationStage.custom(
        fromVersion: SyncSplitPrototypeV6.self,
        toVersion: SyncSplitPrototypeV7.self,
        willMigrate: nil,
        didMigrate: { context in
            for item in try context.fetch(FetchDescriptor<SyncSplitPrototypeV6.Item>()) {
                guard item.deviceValue != nil else { continue }
                context.insert(SyncSplitPrototypeV7.LocalState(
                    key: item.key,
                    deviceValue: item.deviceValue
                ))
            }
            try context.save()
        }
    )

    static let finalize = MigrationStage.lightweight(
        fromVersion: SyncSplitPrototypeV7.self,
        toVersion: SyncSplitPrototypeV8.self
    )
}

/// The preflight opens only through V7 first. This deliberate pause lets the
/// app copy bridge rows into the separate local store before V8 removes them.
private enum SyncSplitPrototypeBridgePlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [SyncSplitPrototypeV6.self, SyncSplitPrototypeV7.self]
    }

    static var stages: [MigrationStage] { [SyncSplitPrototypePlan.bridge] }
}

@MainActor
final class SyncStorageTopologyTests: XCTestCase {
    private static let mirroredModels: [any PersistentModel.Type] = [
        SyncPrototypePodcast.self,
        SyncPrototypeEpisode.self,
        SyncPrototypeQueueItem.self,
        SyncPrototypeListeningSession.self,
        SyncPrototypeBookmark.self,
        SyncPrototypeFolder.self,
        SyncPrototypeFolderMembership.self,
        SyncPrototypeRecentlyExpired.self,
        SyncPrototypeQuickActionConfig.self,
        SyncPrototypeSetting.self,
        SyncPrototypeEpisodeFolderMembership.self,
    ]

    private static let localModels: [any PersistentModel.Type] = [
        SyncPrototypeLocalPodcastState.self,
        SyncPrototypeLocalEpisodeState.self,
        SyncPrototypeLocalSetting.self,
    ]

    func testFullSchemaConstructsWithSeparateMirroredAndLocalConfigurations() throws {
        let mirroredSchema = Schema(Self.mirroredModels)
        let localSchema = Schema(Self.localModels)
        let fullSchema = Schema(Self.mirroredModels + Self.localModels)
        let mirrored = ModelConfiguration(
            "FutureMirrored",
            schema: mirroredSchema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let local = ModelConfiguration(
            "DeviceLocal",
            schema: localSchema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )

        let container = try ModelContainer(
            for: fullSchema,
            configurations: mirrored, local
        )

        XCTAssertEqual(container.schema.entities.count, 14)
        XCTAssertEqual(container.configurations.count, 2)

        // Saving one row from each side proves SwiftData can route both model
        // groups through the same container without a cross-store relationship.
        let context = ModelContext(container)
        context.insert(SyncPrototypePodcast())
        context.insert(SyncPrototypeLocalEpisodeState())
        try context.save()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SyncPrototypePodcast>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SyncPrototypeLocalEpisodeState>()), 1)
    }

    func testFutureMirroredSchemaHasCloudKitCompatibleShape() {
        let schema = Schema(Self.mirroredModels)
        for entity in schema.entities {
            for attribute in entity.attributes {
                XCTAssertFalse(
                    attribute.options.contains(.unique),
                    "Unique attribute is not CloudKit-compatible: \(entity.name).\(attribute.name)"
                )
                XCTAssertTrue(
                    attribute.isOptional || attribute.defaultValue != nil,
                    "Required attribute needs a schema-visible default: \(entity.name).\(attribute.name)"
                )
            }
            for relationship in entity.relationships {
                XCTAssertTrue(
                    relationship.isOptional,
                    "CloudKit relationship must be optional: \(entity.name).\(relationship.name)"
                )
                XCTAssertNotNil(
                    relationship.inverseName,
                    "CloudKit relationship needs an inverse: \(entity.name).\(relationship.name)"
                )
                XCTAssertNotEqual(
                    relationship.deleteRule,
                    .deny,
                    "CloudKit does not support deny: \(entity.name).\(relationship.name)"
                )
            }
        }
    }

    func testDeviceLocalSchemaContainsNoRelationships() {
        let schema = Schema(Self.localModels)
        XCTAssertTrue(schema.entities.allSatisfy { $0.relationships.isEmpty })
        XCTAssertEqual(
            Set(schema.entities.map(\.name)),
            [
                "SyncPrototypeLocalPodcastState",
                "SyncPrototypeLocalEpisodeState",
                "SyncPrototypeLocalSetting",
            ]
        )
    }

    func testExplicitBridgePreflightMovesValueBeforeFinalSplit() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sync-split-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let mirroredURL = directory.appendingPathComponent("mirrored.store")
        let localURL = directory.appendingPathComponent("local.store")

        try autoreleasepool {
            let v6Schema = Schema(versionedSchema: SyncSplitPrototypeV6.self)
            let v6 = try ModelContainer(
                for: v6Schema,
                configurations: ModelConfiguration(schema: v6Schema, url: mirroredURL)
            )
            v6.mainContext.insert(SyncSplitPrototypeV6.Item(
                key: "episode-key",
                deviceValue: "device-only-path.mp3"
            ))
            try v6.mainContext.save()
        }

        // First open only to the additive bridge in the original store. The
        // custom callback can see both source and bridge because they are still
        // in one configuration.
        let copiedValues: [(key: String, deviceValue: String?)] = try autoreleasepool {
            let v7Schema = Schema(versionedSchema: SyncSplitPrototypeV7.self)
            let bridge = try ModelContainer(
                for: v7Schema,
                migrationPlan: SyncSplitPrototypeBridgePlan.self,
                configurations: ModelConfiguration(schema: v7Schema, url: mirroredURL)
            )
            return try bridge.mainContext
                .fetch(FetchDescriptor<SyncSplitPrototypeV7.LocalState>())
                .map { ($0.key, $0.deviceValue) }
        }
        XCTAssertEqual(copiedValues.count, 1)

        // Populate and validate the separate local store before the source is
        // removed. The operation is scalar and idempotent in production.
        let fullSchema = Schema(versionedSchema: SyncSplitPrototypeV8.self)
        let mirroredSchema = Schema([SyncSplitPrototypeV8.Item.self])
        let localSchema = Schema([SyncSplitPrototypeV8.LocalState.self])
        let stagingMirroredURL = directory.appendingPathComponent("staging-mirrored.store")
        try autoreleasepool {
            let local = try ModelContainer(
                for: fullSchema,
                migrationPlan: SyncSplitPrototypePlan.self,
                configurations:
                    ModelConfiguration(
                        "FutureMirrored",
                        schema: mirroredSchema,
                        url: stagingMirroredURL,
                        cloudKitDatabase: .none
                    ),
                    ModelConfiguration(
                        "DeviceLocal",
                        schema: localSchema,
                        url: localURL,
                        cloudKitDatabase: .none
                    )
            )
            for value in copiedValues {
                local.mainContext.insert(SyncSplitPrototypeV8.LocalState(
                    key: value.key,
                    deviceValue: value.deviceValue
                ))
            }
            try local.mainContext.save()
            XCTAssertEqual(
                try local.mainContext.fetchCount(
                    FetchDescriptor<SyncSplitPrototypeV8.LocalState>()
                ),
                copiedValues.count
            )
        }

        // Only after the local copy is durable do we open the final split graph;
        // this migrates the original store V7→V8 and drops its bridge field/table.
        let container = try ModelContainer(
            for: fullSchema,
            migrationPlan: SyncSplitPrototypePlan.self,
            configurations:
                ModelConfiguration(
                    "FutureMirrored",
                    schema: mirroredSchema,
                    url: mirroredURL,
                    cloudKitDatabase: .none
                ),
                ModelConfiguration(
                    "DeviceLocal",
                    schema: localSchema,
                    url: localURL,
                    cloudKitDatabase: .none
                )
        )

        XCTAssertEqual(
            try container.mainContext.fetch(FetchDescriptor<SyncSplitPrototypeV8.Item>())
                .map(\.key),
            ["episode-key"]
        )
        let localRows = try container.mainContext.fetch(
            FetchDescriptor<SyncSplitPrototypeV8.LocalState>()
        )
        XCTAssertEqual(localRows.count, 1)
        XCTAssertEqual(localRows.first?.key, "episode-key")
        XCTAssertEqual(localRows.first?.deviceValue, "device-only-path.mp3")
    }
}
