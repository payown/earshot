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
/// `EarshotSchemaV6` is the current schema and the only `VersionedSchema` that
/// references the live types; V1…V5 are frozen nested snapshots. To make "the
/// live graph drifted from its last frozen snapshot" a CI failure, this test
/// compares the LIVE graph against the most-recently-frozen ``EarshotSchemaV5``
/// snapshot and asserts the ONLY differences are the documented, intentional
/// V5→V6 deltas (#751, folders phase 1):
///   - the new ``EpisodeFolderMembership`` ENTITY; and
///   - two new OPTIONAL, self-referential relationships on ``PodcastFolder`` —
///     `parent` and `children`.
/// Any OTHER difference means a live model changed shape without a new frozen
/// version + migration stage being added.
///
/// V5→V6 is purely additive and changes NO existing attribute. `Episode` above
/// all is untouched: a new attribute or an inverse relationship on it would put a
/// real library's ~242k episode rows back into the migration's path, which is the
/// one thing that design exists to avoid (#701). So every attribute the two
/// graphs share must be byte-identical, and the only new attribute key allowed is
/// `EpisodeFolderMembership`'s own scalar.
///
/// IF THIS TEST FAILS with a difference other than the expected delta: a live
/// `@Model` changed shape without the schema being versioned. Do NOT just edit a
/// frozen snapshot to match — that re-creates the exact latent crash this guard
/// exists to prevent. Instead:
///   1. Freeze the current live graph as a nested snapshot in a new
///      `EarshotSchemaV7` (mirroring how V5 is frozen), bumping to `Schema.Version(7,0,0)`.
///   2. Point the live `models` reference (currently `EarshotSchemaV6`) — or a new
///      `EarshotSchemaV8` — at the live types.
///   3. Add a V6→V7 `MigrationStage` to `EarshotMigrationPlan` (lightweight if the
///      change is additive/optional, custom otherwise).
///   4. Update `ModelContainerFactory` / `StoreMigration` to open as the new version.
///   5. Update this test to compare against the newly-frozen snapshot, describing
///      the new intentional delta.
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
        ActiveDownload.self,
        EpisodeFolderMembership.self,
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

    func testLiveGraphDiffersFromFrozenV5OnlyByIntentionalAddition() {
        let frozenV5 = attributeMap(Schema(versionedSchema: EarshotSchemaV5.self))
        let live = attributeMap(Schema(Self.liveModels))

        // V5→V6 added one new ENTITY plus two new RELATIONSHIPS. The only new
        // attribute (scalar) key is the new join entity's `sortOrder`; the
        // parent/children additions are relationships, not attributes.
        let addedKeys = Set(live.keys).subtracting(frozenV5.keys)
        let removedKeys = Set(frozenV5.keys).subtracting(live.keys)
        XCTAssertEqual(
            addedKeys, ["EpisodeFolderMembership.sortOrder"],
            "Live graph added attribute(s) other than the documented V5→V6 "
                + "EpisodeFolderMembership entity. See this file's header for the fix."
        )
        XCTAssertTrue(
            removedKeys.isEmpty,
            "Live graph removed attribute(s) vs frozen EarshotSchemaV5: "
                + "\(removedKeys.sorted()). See this file's header for the fix."
        )

        // Every attribute present on BOTH sides must be byte-for-byte identical
        // (optionality + type) — V5→V6 adds an entity and relationships, and
        // reshapes no existing attribute.
        let sharedKeys = Set(frozenV5.keys).intersection(live.keys)
        let drifted = sharedKeys.filter { frozenV5[$0] != live[$0] }
        XCTAssertTrue(
            drifted.isEmpty,
            "Live graph drifted from frozen EarshotSchemaV5 beyond the documented "
                + "V5→V6 addition. Drifted keys: \(drifted.sorted()). See this "
                + "file's header for the fix."
        )
    }

    /// The load-bearing half of the folders-phase-1 design: `Episode` must be
    /// COMPLETELY untouched, so a real library's ~242k episode rows are never
    /// rewritten by the migration. ``EpisodeFolderMembership/episode`` is
    /// deliberately one-way — an `@Relationship(inverse:)` collection on
    /// `Episode` would change `Episode`'s shape and undo exactly that (#701/#751).
    func testEpisodeShapeIsUnchangedFromFrozenV5() {
        let frozenV5 = Schema(versionedSchema: EarshotSchemaV5.self)
        let live = Schema(Self.liveModels)

        let frozenAttrs = attributeMap(frozenV5).filter { $0.key.hasPrefix("Episode.") }
        let liveAttrs = attributeMap(live).filter { $0.key.hasPrefix("Episode.") }
        XCTAssertEqual(
            liveAttrs, frozenAttrs,
            "Episode's attributes drifted from frozen EarshotSchemaV5. V5→V6 must "
                + "not touch Episode at all — see this file's header."
        )

        XCTAssertEqual(
            relationshipMap(live)["Episode"], relationshipMap(frozenV5)["Episode"],
            "Episode gained or lost a relationship vs frozen EarshotSchemaV5. "
                + "EpisodeFolderMembership.episode must stay one-way: an inverse "
                + "here would put 242k episode rows back into the migration's path."
        )
    }

    /// The V5→V6 relationship delta: `PodcastFolder` gains exactly `parent` and
    /// `children`, and NO other entity's relationships move.
    func testOnlyPodcastFolderGainsParentAndChildrenRelationships() {
        let frozenV5 = relationshipMap(Schema(versionedSchema: EarshotSchemaV5.self))
        let live = relationshipMap(Schema(Self.liveModels))

        XCTAssertEqual(
            live["PodcastFolder"],
            ((frozenV5["PodcastFolder"] ?? []) + ["children", "parent"]).sorted(),
            "PodcastFolder's relationships are not exactly its frozen V5 set plus "
                + "parent/children."
        )

        // Every entity that existed at V5 EXCEPT PodcastFolder keeps its exact
        // relationship set.
        for (entity, rels) in frozenV5 where entity != "PodcastFolder" {
            XCTAssertEqual(
                live[entity], rels,
                "\(entity)'s relationships drifted from frozen EarshotSchemaV5."
            )
        }
    }

    /// Guards the lockstep assumption: the live list this test compares against
    /// must equal what `EarshotSchemaV6` actually registers, by entity name.
    func testLiveListMatchesV6ModelsList() {
        let v6Names = Set(Schema(versionedSchema: EarshotSchemaV6.self).entities.map(\.name))
        let liveNames = Set(Schema(Self.liveModels).entities.map(\.name))
        XCTAssertEqual(v6Names, liveNames)
    }

    /// The V5→V6 delta at entity granularity: exactly one new entity, none lost.
    func testLiveGraphAddsOnlyTheEpisodeFolderMembershipEntity() {
        let frozenNames = Set(Schema(versionedSchema: EarshotSchemaV5.self).entities.map(\.name))
        let liveNames = Set(Schema(Self.liveModels).entities.map(\.name))
        XCTAssertEqual(liveNames.subtracting(frozenNames), ["EpisodeFolderMembership"])
        XCTAssertTrue(frozenNames.subtracting(liveNames).isEmpty)
    }
}
