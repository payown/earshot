import XCTest
import SwiftData
@testable import Earshot

/// Exercises the V5→V6 SwiftData migration against a real on-disk store, the way
/// a tester's device upgrade actually runs it (issue #751, folders phase 1;
/// `.claude/rules/database-migrations.md` rule 4 / the required CI gate). A fresh
/// `onCreate` proves nothing about migrations, so this builds a store at the
/// *frozen V5 schema* with realistic aged data — several folders, folder
/// memberships, a podcast with its nullable fields left unset, episodes and queue
/// items — then opens it through the production path
/// (`StoreMigration.openOrMigrate`) and asserts
/// the upgrade completes without aborting and preserves everything.
///
/// The risk this test exists to catch: V5→V6 adds the ``EpisodeFolderMembership``
/// entity AND two self-referential relationships (`parent`/`children`) to
/// ``PodcastFolder``. If either turned out NOT to be lightweight-inferrable — or
/// perturbed an existing row — folders or their memberships could be lost, or the
/// open could abort outright and trip the reset-on-failure path. So the
/// assertions are on the VALUES that survive, plus proof the new nesting and the
/// new join table actually work on the migrated store.
@MainActor
final class AgedV5StoreMigrationTests: XCTestCase {

    nonisolated(unsafe) private var dir: URL!
    nonisolated(unsafe) private var storeURL: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("migration-v5v6-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storeURL = dir.appendingPathComponent("default.store")
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private let pubA = Date(timeIntervalSince1970: 1_600_000_000)
    private let pubB = Date(timeIntervalSince1970: 1_600_100_000)

    /// Writes a store at the frozen V5 schema with realistic aged data: two
    /// podcasts (one carrying per-podcast overrides, one with its nullable fields
    /// left unset), three folders (one with a `queueAgeLimitDays`), folder
    /// memberships linking podcasts to folders, a couple of episodes, and a queue
    /// item. `EarshotSchemaV5` has NO `EpisodeFolderMembership` entity and its
    /// `PodcastFolder` has NO `parent`/`children` — both arrive at V6.
    private func seedV5Store() throws {
        try autoreleasepool {
            let schema = Schema(versionedSchema: EarshotSchemaV5.self)
            let v5 = try ModelContainer(
                for: schema,
                configurations: ModelConfiguration(schema: schema, url: storeURL)
            )
            let ctx = v5.mainContext

            let p1 = EarshotSchemaV5.Podcast(
                feedURL: "https://ex.com/one.xml",
                title: "Show One",
                author: "Author One",
                notificationEnabled: true,
                speedOverride: 1.5,
                introSkipSeconds: 30
            )
            ctx.insert(p1)

            // Second podcast leaves every nullable field unset, covering an older
            // row's NULL columns across the migration.
            let p2 = EarshotSchemaV5.Podcast(
                feedURL: "https://ex.com/two.xml",
                title: "Show Two"
            )
            ctx.insert(p2)

            // Three flat (non-nesting) folders, as they existed at V5.
            let fNews = EarshotSchemaV5.PodcastFolder(name: "News", sortOrder: 0)
            let fTech = EarshotSchemaV5.PodcastFolder(
                name: "Tech", sortOrder: 1, queueAgeLimitDays: 14
            )
            let fEmpty = EarshotSchemaV5.PodcastFolder(name: "Empty", sortOrder: 2)
            ctx.insert(fNews)
            ctx.insert(fTech)
            ctx.insert(fEmpty)

            // Memberships: p1 in News (order 0), p1 in Tech (order 0), p2 in Tech
            // (order 1). "Empty" deliberately has none.
            ctx.insert(EarshotSchemaV5.FolderMembership(folder: fNews, podcast: p1, sortOrder: 0))
            ctx.insert(EarshotSchemaV5.FolderMembership(folder: fTech, podcast: p1, sortOrder: 0))
            ctx.insert(EarshotSchemaV5.FolderMembership(folder: fTech, podcast: p2, sortOrder: 1))

            let ep1 = EarshotSchemaV5.Episode(
                guid: "ep-1",
                title: "Ep One",
                audioURL: "https://ex.com/ep1.mp3",
                pubDate: pubA,
                createdAt: pubA
            )
            ep1.podcast = p1
            ctx.insert(ep1)

            let queued = EarshotSchemaV5.Episode(
                guid: "ep-queued",
                title: "Queued",
                audioURL: "https://ex.com/queued.mp3",
                pubDate: pubB,
                status: .inQueue,
                createdAt: pubB
            )
            queued.podcast = p2
            ctx.insert(queued)
            ctx.insert(EarshotSchemaV5.QueueItem(episode: queued, position: 0))

            try ctx.save()
        }
    }

    func testV5StoreMigratesToV8AndReopensWithItsGraphIntact() throws {
        try seedV5Store()

        try autoreleasepool {
            let container = try StoreMigration.openOrMigrate(at: storeURL)
            let ctx = container.mainContext
            let folders = try ctx.fetch(
                FetchDescriptor<PodcastFolder>(sortBy: [SortDescriptor(\.sortOrder)])
            )
            XCTAssertEqual(folders.map(\.name), ["News", "Tech", "Empty"])
            XCTAssertEqual(folders[1].queueAgeLimitDays, 14)
            XCTAssertTrue(folders.allSatisfy { $0.parent == nil && ($0.children?.isEmpty ?? true) })

            let memberships = try ctx.fetch(FetchDescriptor<FolderMembership>())
            XCTAssertEqual(memberships.count, 3)
            XCTAssertEqual(Set((folders[1].memberships ?? []).compactMap { $0.podcast?.feedURL }),
                           ["https://ex.com/one.xml", "https://ex.com/two.xml"])

            let podcasts = try ctx.fetch(
                FetchDescriptor<Podcast>(sortBy: [SortDescriptor(\.feedURL)])
            )
            XCTAssertEqual(podcasts.count, 2)
            XCTAssertEqual(podcasts[0].speedOverride, 1.5)
            XCTAssertEqual(podcasts[0].introSkipSeconds, 30)
            XCTAssertNil(podcasts[1].author)
            XCTAssertNil(podcasts[1].speedOverride)

            let episodes = try ctx.fetch(FetchDescriptor<Episode>())
            XCTAssertEqual(episodes.count, 2)
            XCTAssertEqual(episodes.first { $0.guid == "ep-1" }?.podcast?.feedURL,
                           "https://ex.com/one.xml")
            XCTAssertEqual(try ctx.fetch(FetchDescriptor<QueueItem>()).count, 1)
            XCTAssertTrue(try ctx.fetch(FetchDescriptor<EpisodeFolderMembership>()).isEmpty)

            guard let episode = episodes.first(where: { $0.guid == "ep-1" }),
                  let news = folders.first(where: { $0.name == "News" }),
                  let tech = folders.first(where: { $0.name == "Tech" }) else {
                return XCTFail("seeded graph missing after migration")
            }
            ctx.insert(EpisodeFolderMembership(folder: news, episode: episode))
            tech.parent = news
            try ctx.save()
            XCTAssertEqual(tech.parent?.name, "News")
            XCTAssertEqual((news.children ?? []).map(\.name), ["Tech"])
        }

        let reopened = try StoreMigration.openOrMigrate(at: storeURL)
        let ctx = reopened.mainContext
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<PodcastFolder>()).count, 3)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<FolderMembership>()).count, 3)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<EpisodeFolderMembership>()).count, 1)
    }
}
