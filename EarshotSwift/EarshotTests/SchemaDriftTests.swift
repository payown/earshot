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
/// `EarshotSchemaV3` is the current schema and the only `VersionedSchema` that
/// references the live types; V1 and V2 are frozen nested snapshots. To make
/// "the live graph drifted from its last frozen snapshot" a CI failure, this test
/// compares the LIVE graph against the FROZEN ``EarshotSchemaV2`` snapshot and
/// asserts the ONLY difference is the single documented, intentional V2→V3 delta:
/// `Podcast.notificationEnabled` went from non-optional `Bool` to optional
/// `Bool?`. Any OTHER difference means a live model changed shape without a new
/// frozen version + migration stage being added.
///
/// IF THIS TEST FAILS with a difference other than the expected delta: a live
/// `@Model` changed shape without the schema being versioned. Do NOT just edit a
/// frozen snapshot to match — that re-creates the exact latent crash this guard
/// exists to prevent. Instead:
///   1. Freeze the current live graph as a nested snapshot in a new
///      `EarshotSchemaV4` (mirroring how V2 is frozen), bumping to `Schema.Version(4,0,0)`.
///   2. Point the live `models` reference (currently `EarshotSchemaV3`) — or a new
///      `EarshotSchemaV5` — at the live types.
///   3. Add a V3→V4 `MigrationStage` to `EarshotMigrationPlan` (lightweight if the
///      change is additive/optional, custom otherwise).
///   4. Update `ModelContainerFactory` / `StoreMigration` to open as the new version.
///   5. Update the `expectedDelta` in this test to describe the new intentional change.
@MainActor
final class SchemaDriftTests: XCTestCase {

    /// The live model graph, kept in lockstep with `EarshotSchemaV3.models`.
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

    func testLiveGraphDiffersFromFrozenV2OnlyByIntentionalDelta() {
        let frozenV2 = attributeMap(Schema(versionedSchema: EarshotSchemaV2.self))
        let live = attributeMap(Schema(Self.liveModels))

        // Same entity + attribute *names* on both sides (V2→V3 added no fields
        // and removed none — it only changed one field's optionality).
        XCTAssertEqual(
            Set(frozenV2.keys), Set(live.keys),
            "An entity or attribute was added/removed in the live graph vs frozen "
                + "EarshotSchemaV2. See this file's header: freeze a new version + "
                + "migration stage."
        )

        // The set of keys whose value (optionality|type) differs between V2 and
        // the live graph must be EXACTLY the documented intentional delta.
        let drifted = Set(frozenV2.keys).filter { key in
            frozenV2[key] != live[key]
        }
        let expectedDelta: Set<String> = ["Podcast.notificationEnabled"]
        XCTAssertEqual(
            drifted, expectedDelta,
            "Live graph drifted from frozen EarshotSchemaV2 in a way that is NOT "
                + "the documented V2→V3 delta (\(expectedDelta)). Drifted keys: "
                + "\(drifted.sorted()). See this file's header for the fix."
        )

        // And spell out the expected delta precisely: V2 non-optional Bool ->
        // live optional Bool.
        XCTAssertEqual(frozenV2["Podcast.notificationEnabled"], "false|Bool")
        XCTAssertEqual(live["Podcast.notificationEnabled"], "true|Optional<Bool>")
    }

    /// Guards the lockstep assumption: the live list this test compares against
    /// must equal what `EarshotSchemaV3` actually registers, by entity name.
    func testLiveListMatchesV3ModelsList() {
        let v3Names = Set(Schema(versionedSchema: EarshotSchemaV3.self).entities.map(\.name))
        let liveNames = Set(Schema(Self.liveModels).entities.map(\.name))
        XCTAssertEqual(v3Names, liveNames)
    }
}
