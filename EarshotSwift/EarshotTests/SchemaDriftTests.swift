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
/// `EarshotSchemaV4` is the current schema and the only `VersionedSchema` that
/// references the live types; V1, V2, and V3 are frozen nested snapshots. To
/// make "the live graph drifted from its last frozen snapshot" a CI failure,
/// this test compares the LIVE graph against the most-recently-frozen
/// ``EarshotSchemaV3`` snapshot and asserts the ONLY difference is the single
/// documented, intentional V3→V4 delta: the new `Podcast.introSkipSeconds: Int?`
/// attribute. Any OTHER difference means a live model changed shape without a
/// new frozen version + migration stage being added.
///
/// IF THIS TEST FAILS with a difference other than the expected delta: a live
/// `@Model` changed shape without the schema being versioned. Do NOT just edit a
/// frozen snapshot to match — that re-creates the exact latent crash this guard
/// exists to prevent. Instead:
///   1. Freeze the current live graph as a nested snapshot in a new
///      `EarshotSchemaV5` (mirroring how V3 is frozen), bumping to `Schema.Version(5,0,0)`.
///   2. Point the live `models` reference (currently `EarshotSchemaV4`) — or a new
///      `EarshotSchemaV6` — at the live types.
///   3. Add a V4→V5 `MigrationStage` to `EarshotMigrationPlan` (lightweight if the
///      change is additive/optional, custom otherwise).
///   4. Update `ModelContainerFactory` / `StoreMigration` to open as the new version.
///   5. Update this test to compare against the newly-frozen snapshot, describing
///      the new intentional delta.
@MainActor
final class SchemaDriftTests: XCTestCase {

    /// The live model graph, kept in lockstep with `EarshotSchemaV4.models`.
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

    func testLiveGraphDiffersFromFrozenV3OnlyByIntentionalAddition() {
        let frozenV3 = attributeMap(Schema(versionedSchema: EarshotSchemaV3.self))
        let live = attributeMap(Schema(Self.liveModels))

        // V3→V4 added exactly one new attribute and removed/renamed nothing.
        let addedKeys = Set(live.keys).subtracting(frozenV3.keys)
        let removedKeys = Set(frozenV3.keys).subtracting(live.keys)
        let expectedAddition = "Podcast.introSkipSeconds"
        XCTAssertEqual(
            addedKeys, [expectedAddition],
            "Live graph added attribute(s) other than the documented V3→V4 "
                + "addition. See this file's header for the fix."
        )
        XCTAssertTrue(
            removedKeys.isEmpty,
            "Live graph removed attribute(s) vs frozen EarshotSchemaV3: "
                + "\(removedKeys.sorted()). See this file's header for the fix."
        )

        // Every attribute present on BOTH sides must be byte-for-byte identical
        // (optionality + type) — V3→V4 is a pure addition, nothing else moved.
        let sharedKeys = Set(frozenV3.keys).intersection(live.keys)
        let drifted = sharedKeys.filter { frozenV3[$0] != live[$0] }
        XCTAssertTrue(
            drifted.isEmpty,
            "Live graph drifted from frozen EarshotSchemaV3 beyond the documented "
                + "V3→V4 addition. Drifted keys: \(drifted.sorted()). See this "
                + "file's header for the fix."
        )

        // And spell out the addition precisely: new optional Int.
        XCTAssertEqual(live[expectedAddition], "true|Optional<Int>")
    }

    /// Guards the lockstep assumption: the live list this test compares against
    /// must equal what `EarshotSchemaV4` actually registers, by entity name.
    func testLiveListMatchesV4ModelsList() {
        let v4Names = Set(Schema(versionedSchema: EarshotSchemaV4.self).entities.map(\.name))
        let liveNames = Set(Schema(Self.liveModels).entities.map(\.name))
        XCTAssertEqual(v4Names, liveNames)
    }
}
