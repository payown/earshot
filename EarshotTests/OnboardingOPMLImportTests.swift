import XCTest
import SwiftData
@testable import Earshot

/// Covers the onboarding OPML-import wiring added to ``OnboardingView``. The view
/// drives the same shared ``OPMLFileImporter`` Settings uses, so onboarding behaves
/// identically. ``OnboardingView`` gates its "Start Listening" button on a non-empty
/// `@Query private var podcasts`, so what matters for onboarding is that a
/// successful import leaves at least one ``Podcast`` in the context — the same
/// SwiftData store the `@Query` reads. These tests assert that contract directly by
/// calling the importer onboarding calls and inspecting the resulting podcasts.
///
/// Feeds are pre-seeded as already-subscribed podcasts so the import dedupes to them
/// and never touches the network (same offline strategy as OPMLFileImporterTests).
@MainActor
final class OnboardingOPMLImportTests: XCTestCase {

    /// Writes an OPML document to a throwaway temp `.opml` file and returns its URL.
    private func writeOPML(_ opml: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("subscriptions.opml")
        try opml.data(using: .utf8)!.write(to: url)
        return url
    }

    /// Seeds the shared store with already-subscribed podcasts for each feed URL,
    /// so the OPML import resolves them offline (no network fetch on subscribe).
    private func seedSubscribed(_ feedURLs: [String]) -> ModelContext {
        let ctx = TestStore.freshContext()
        for feedURL in feedURLs {
            ctx.insert(Podcast(feedURL: feedURL, title: "Seeded \(feedURL)"))
        }
        try? ctx.save()
        return ctx
    }

    private func podcastCount(_ ctx: ModelContext) throws -> Int {
        try ctx.fetchCount(FetchDescriptor<Podcast>())
    }

    /// The onboarding import populates the context, which is what unlocks the
    /// "Start Listening" button (gated on a non-empty `podcasts` query).
    func testOnboardingImportPopulatesContextSoStartListeningUnlocks() async throws {
        let feeds = ["https://a.com/feed", "https://b.com/feed"]
        let ctx = seedSubscribed(feeds)
        // Start "empty" from onboarding's perspective: nothing has been added by the
        // user yet, but the seeded feeds let subscribe resolve offline.
        let before = try podcastCount(ctx)

        let url = try writeOPML("""
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
          <head><title>Test</title></head>
          <body>
            <outline type="rss" text="A" xmlUrl="https://a.com/feed"/>
            <outline type="rss" text="B" xmlUrl="https://b.com/feed"/>
          </body>
        </opml>
        """)

        let count = await OPMLFileImporter.importFile(at: url, context: ctx)
        XCTAssertEqual(count, 2)
        // The query OnboardingView reads is now non-empty, so hasPodcast is true and
        // "Start Listening" is enabled.
        let after = try podcastCount(ctx)
        XCTAssertGreaterThanOrEqual(after, before)
        XCTAssertFalse(try ctx.fetch(FetchDescriptor<Podcast>()).isEmpty)
    }

    /// Importing from onboarding with the shared progress object drives the same
    /// app-wide progress screen Settings uses. We pass it through exactly as the view
    /// does and confirm the import still completes and leaves the store populated.
    func testOnboardingImportDrivesSharedProgressAndPopulates() async throws {
        let feeds = ["https://a.com/feed"]
        let ctx = seedSubscribed(feeds)
        let progress = OPMLImportProgress()

        let url = try writeOPML("""
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
          <head><title>Test</title></head>
          <body>
            <outline type="rss" text="A" xmlUrl="https://a.com/feed"/>
          </body>
        </opml>
        """)

        let count = await OPMLFileImporter.importFile(at: url, context: ctx, progress: progress)
        XCTAssertEqual(count, 1)
        // finish() always runs, so the shared progress object isn't left "importing".
        XCTAssertFalse(progress.isImporting)
        XCTAssertFalse(try ctx.fetch(FetchDescriptor<Podcast>()).isEmpty)
    }

    /// A cancelled / unreadable pick must not crash and must leave "Start Listening"
    /// still gated — no podcasts get added. Onboarding logs the failure and returns.
    func testOnboardingImportOfUnreadableFileLeavesContextEmpty() async throws {
        let ctx = TestStore.freshContext()
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)/nope.opml")

        let count = await OPMLFileImporter.importFile(at: missing, context: ctx)
        XCTAssertNil(count)
        XCTAssertTrue(try ctx.fetch(FetchDescriptor<Podcast>()).isEmpty)
    }
}
