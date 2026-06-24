import XCTest
import SwiftData
@testable import Earshot

/// Covers ``OPMLFileImporter`` — the shared "import an OPML file at a URL" helper
/// used by the Settings in-app picker, the share-sheet / "Open in Earshot" path
/// (`onOpenURL`), and onboarding. Drives it against a temp `.opml` file on disk so
/// the read + import path is exercised without a live file picker.
///
/// The OPML feeds are pre-seeded as already-subscribed podcasts so the import
/// dedupes to them and never touches the network: `SubscriptionRepository.subscribe`
/// returns the existing podcast for a known feed URL, and `importOPML` counts each
/// resolved feed as imported. (Same offline strategy as ManualImportTests.)
@MainActor
final class OPMLFileImporterTests: XCTestCase {

    /// Writes an OPML document to a throwaway temp `.opml` file and returns its URL.
    private func writeOPML(_ opml: String, ext: String = "opml") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("subscriptions.\(ext)")
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

    func testImportsFeedsFromOPMLFileAndReturnsCount() async throws {
        let feeds = ["https://a.com/feed", "https://b.com/feed"]
        let ctx = seedSubscribed(feeds)
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
    }

    func testRoundTripExportThenImportIsLosslessForFeedURLs() async throws {
        let feeds = ["https://a.com/feed", "https://b.com/feed"]
        let ctx = seedSubscribed(feeds)
        // Export from the same shape Settings exports, then re-import the file.
        let opml = OPMLDocument.export(feeds.map { (title: "Show", feedURL: $0) })
        let url = try writeOPML(opml)

        let count = await OPMLFileImporter.importFile(at: url, context: ctx)
        XCTAssertEqual(count, 2)
    }

    func testUnreadableFileReturnsNil() async throws {
        let ctx = TestStore.freshContext()
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)/nope.opml")

        let count = await OPMLFileImporter.importFile(at: missing, context: ctx)
        XCTAssertNil(count)
    }

    func testEmptyOPMLImportsNothing() async throws {
        let ctx = TestStore.freshContext()
        let url = try writeOPML("""
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0"><head/><body></body></opml>
        """)

        let count = await OPMLFileImporter.importFile(at: url, context: ctx)
        XCTAssertEqual(count, 0)
    }
}
