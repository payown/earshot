import XCTest
import SwiftData
@testable import Earshot

/// Future-proofing guard for the schema-drift crash class (#425).
///
/// The crash architecture was: a `VersionedSchema` stamped `N.0.0` that points at
/// LIVE `@Model` types silently changes shape whenever a live model gains a
/// field — no version bump, no migration — so SwiftData later opens a store
/// stamped `N.0.0` whose on-disk shape no longer matches the code's `N.0.0`
/// shape and aborts the open (NSCocoaErrorDomain 134110, often uncatchable).
///
/// `EarshotSchemaV5` is the current schema and the only `VersionedSchema` that
/// references the live types; V1, V2, V3, and V4 are frozen nested snapshots. To
/// make "the live graph drifted from its last frozen snapshot" a CI failure,
/// this test compares the LIVE graph against the most-recently-frozen
/// ``EarshotSchemaV4`` snapshot and asserts the ONLY difference is the single
/// documented, intentional V4→V5 delta: the new ``ActiveDownload`` ENTITY (#701).
/// Any OTHER difference means a live model changed shape without a new frozen
/// version + migration stage being added.
///
/// V4→V5 adds an entity and changes NO existing one. `Episode` above all is
/// untouched: a new attribute or an inverse relationship on it would put a real
/// library's ~242k episode rows back into the migration's path, which is the one
/// thing that design exists to avoid. So every attribute the two graphs share
/// must be byte-identical, and the only new attribute keys allowed are
/// `ActiveDownload`'s own.
///
/// IF THIS TEST FAILS with a difference other than the expected delta: a live
/// `@Model` changed shape without the schema being versioned. Do NOT just edit a
/// frozen snapshot to match — that re-creates the exact latent crash this guard
/// exists to prevent. Instead:
///   1. Freeze the current live graph as a nested snapshot in a new
///      `EarshotSchemaV6` (mirroring how V4 is frozen), bumping to `Schema.Version(6,0,0)`.
///   2. Point the live `models` reference (currently `EarshotSchemaV5`) — or a new
///      `EarshotSchemaV7` — at the live types.
///   3. Add a V5→V6 `MigrationStage` to `EarshotMigrationPlan` (lightweight if the
///      change is additive/optional, custom otherwise).
///   4. Update `ModelContainerFactory` / `StoreMigration` to open as the new version.
///   5. Update this test to compare against the newly-frozen snapshot, describing
///      the new intentional delta.
@MainActor
final class SchemaDriftTests: XCTestCase {

    /// The live model graph, kept in lockstep with `EarshotSchemaV5.models`.
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
        ActiveDownload.self,
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

    func testLiveGraphDiffersFromFrozenV4OnlyByIntentionalAddition() {
        let frozenV4 = attributeMap(Schema(versionedSchema: EarshotSchemaV4.self))
        let live = attributeMap(Schema(Self.liveModels))

        // V4→V5 added exactly one new ENTITY and removed/renamed nothing. The
        // only new attribute keys are that entity's own.
        let addedKeys = Set(live.keys).subtracting(frozenV4.keys)
        let removedKeys = Set(frozenV4.keys).subtracting(live.keys)
        XCTAssertEqual(
            addedKeys, ["ActiveDownload.stateRaw"],
            "Live graph added attribute(s) other than the documented V4→V5 "
                + "ActiveDownload entity. See this file's header for the fix."
        )
        XCTAssertTrue(
            removedKeys.isEmpty,
            "Live graph removed attribute(s) vs frozen EarshotSchemaV4: "
                + "\(removedKeys.sorted()). See this file's header for the fix."
        )

        // Every attribute present on BOTH sides must be byte-for-byte identical
        // (optionality + type) — V4→V5 adds an entity, nothing else moved.
        let sharedKeys = Set(frozenV4.keys).intersection(live.keys)
        let drifted = sharedKeys.filter { frozenV4[$0] != live[$0] }
        XCTAssertTrue(
            drifted.isEmpty,
            "Live graph drifted from frozen EarshotSchemaV4 beyond the documented "
                + "V4→V5 addition. Drifted keys: \(drifted.sorted()). See this "
                + "file's header for the fix."
        )
    }

    /// The load-bearing half of the V4→V5 design: `Episode` must be COMPLETELY
    /// untouched, so a real library's ~242k episode rows are never rewritten by
    /// the migration. `ActiveDownload.episode` is deliberately one-way — an
    /// `@Relationship(inverse:)` collection on `Episode` would change `Episode`'s
    /// shape and undo exactly that (#701).
    func testEpisodeShapeIsUnchangedFromFrozenV4() {
        let frozenV4 = Schema(versionedSchema: EarshotSchemaV4.self)
        let live = Schema(Self.liveModels)

        let frozenAttrs = attributeMap(frozenV4).filter { $0.key.hasPrefix("Episode.") }
        let liveAttrs = attributeMap(live).filter { $0.key.hasPrefix("Episode.") }
        XCTAssertEqual(
            liveAttrs, frozenAttrs,
            "Episode's attributes drifted from frozen EarshotSchemaV4. V4→V5 must "
                + "not touch Episode at all — see this file's header."
        )

        XCTAssertEqual(
            relationshipMap(live)["Episode"], relationshipMap(frozenV4)["Episode"],
            "Episode gained or lost a relationship vs frozen EarshotSchemaV4. "
                + "ActiveDownload.episode must stay one-way: an inverse here would "
                + "put 242k episode rows back into the migration's path (#701)."
        )
    }

    /// Guards the lockstep assumption: the live list this test compares against
    /// must equal what `EarshotSchemaV5` actually registers, by entity name.
    func testLiveListMatchesV5ModelsList() {
        let v5Names = Set(Schema(versionedSchema: EarshotSchemaV5.self).entities.map(\.name))
        let liveNames = Set(Schema(Self.liveModels).entities.map(\.name))
        XCTAssertEqual(v5Names, liveNames)
    }

    /// The V4→V5 delta at entity granularity: exactly one new entity, none lost.
    func testLiveGraphAddsOnlyTheActiveDownloadEntity() {
        let frozenNames = Set(Schema(versionedSchema: EarshotSchemaV4.self).entities.map(\.name))
        let liveNames = Set(Schema(Self.liveModels).entities.map(\.name))
        XCTAssertEqual(liveNames.subtracting(frozenNames), ["ActiveDownload"])
        XCTAssertTrue(frozenNames.subtracting(liveNames).isEmpty)
    }
}
