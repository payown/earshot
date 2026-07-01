import XCTest
import SwiftData
@testable import Earshot

/// Exercises the V3→V4 SwiftData migration against a real on-disk store, the way
/// a tester's device upgrade actually runs it (#524,
/// `.claude/rules/database-migrations.md` rule 2). A fresh `onCreate` proves
/// nothing about migrations, so this builds a store at the *frozen V3 schema*
/// with realistic `QuickActionConfig` rows (no `isHidden` column exists at V3),
/// then opens it through the production path (`StoreMigration.openOrMigrate`,
/// which runs `EarshotMigrationPlan` to the current V4) and asserts:
///   - the upgrade completes without aborting/throwing,
///   - every pre-existing row survives with its order intact, and
///   - every pre-existing action reads back as ENABLED (nil `isHidden` → visible).
@MainActor
final class StoreMigrationV3toV4Tests: XCTestCase {
    private var dir: URL!
    private var storeURL: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("migration-v3v4-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storeURL = dir.appendingPathComponent("default.store")
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    /// Writes a store at the frozen V3 schema: a podcast/episode for realism plus
    /// the full episode + queue Quick Action sets in a custom order, none hidden
    /// (the `isHidden` column does not exist yet at V3).
    private func seedV3Store() throws {
        try autoreleasepool {
            let schema = Schema(versionedSchema: EarshotSchemaV3.self)
            let v3 = try ModelContainer(
                for: schema,
                configurations: ModelConfiguration(schema: schema, url: storeURL)
            )
            let ctx = v3.mainContext

            let p = EarshotSchemaV3.Podcast(feedURL: "https://ex.com/one.xml", title: "Show One")
            ctx.insert(p)
            let ep = EarshotSchemaV3.Episode(guid: "a", title: "Ep A", audioURL: "https://ex.com/a.mp3")
            ep.podcast = p
            ctx.insert(ep)

            // Custom episode order.
            let episodeKeys = ["share", "playNow", "openShowNotes", "markPlayed",
                               "download", "addToQueueTop", "addToQueueBottom", "viewBookmarks"]
            for (i, key) in episodeKeys.enumerated() {
                ctx.insert(EarshotSchemaV3.QuickActionConfig(
                    contentType: .episode, actionKey: key, sortOrder: i))
            }
            // Default queue order.
            for (i, action) in defaultQueueItemActions.enumerated() {
                ctx.insert(EarshotSchemaV3.QuickActionConfig(
                    contentType: .queueItem, actionKey: action.rawValue, sortOrder: i))
            }

            try ctx.save()
        }
    }

    func testV3StoreMigratesToV4PreservingRowsAsEnabled() throws {
        try seedV3Store()

        // Migrate via the production path (runs EarshotMigrationPlan, V3→V4
        // lightweight). This must NOT abort/throw on the missing-optional path.
        let v4 = try StoreMigration.openOrMigrate(at: storeURL)
        let ctx = v4.mainContext

        // The unrelated data survives.
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Podcast>()).count, 1)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Episode>()).count, 1)

        // Every QuickActionConfig row survives and reads back as ENABLED (nil).
        let configs = try ctx.fetch(FetchDescriptor<QuickActionConfig>())
        XCTAssertEqual(configs.count, 8 + defaultQueueItemActions.count)
        for config in configs {
            XCTAssertNil(config.isHidden, "pre-existing row \(config.actionKey) must read back as visible")
        }

        // The repository reports the persisted order, no hidden actions, and the
        // rotor default (first visible) is the first stored action.
        let repo = QuickActionRepository(context: ctx)
        // The stored V3 order predates `unfollowPodcast` (#528); it loads intact
        // with the newly-added action appended (visible) at the end.
        XCTAssertEqual(
            repo.episodeOrder(),
            [.share, .playNow, .openShowNotes, .markPlayed, .download, .addToQueueTop, .addToQueueBottom, .viewBookmarks, .unfollowPodcast]
        )
        XCTAssertTrue(repo.episodeHidden().isEmpty)
        XCTAssertTrue(repo.queueHidden().isEmpty)
        XCTAssertEqual(
            QuickActionVisibilityLogic.defaultKey(
                ordered: repo.episodeOrder().map(\.rawValue), hidden: repo.episodeHidden()),
            "share"
        )
    }

    /// After migrating, the store must reopen cleanly as V4 with the data intact.
    func testMigratedStoreReopensAsV4() throws {
        try seedV3Store()

        try autoreleasepool {
            _ = try StoreMigration.openOrMigrate(at: storeURL)
        }

        let reopened = try StoreMigration.openOrMigrate(at: storeURL)
        let count = try reopened.mainContext.fetch(FetchDescriptor<QuickActionConfig>()).count
        XCTAssertEqual(count, 8 + defaultQueueItemActions.count, "config rows persist across reopen")
    }
}
