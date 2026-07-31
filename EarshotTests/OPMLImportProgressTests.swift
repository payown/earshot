import XCTest
import SwiftData
@testable import Earshot

/// Covers ``OPMLImportProgress`` — the shared, main-actor observable that backs the
/// bulk-OPML ``ImportProgressView``. Drives the lifecycle (start → advance → finish)
/// and asserts the state the view renders from, plus that ``OPMLFileImporter`` wires
/// a passed-in progress object through a real import.
@MainActor
final class OPMLImportProgressTests: XCTestCase {

    // MARK: Lifecycle

    func testStartActivatesAndResetsCounters() {
        let progress = OPMLImportProgress()
        XCTAssertFalse(progress.isImporting, "isImporting starts false so the screen is hidden")

        progress.start(total: 10)
        XCTAssertTrue(progress.isImporting, "start() gates the screen on")
        XCTAssertEqual(progress.completed, 0)
        XCTAssertEqual(progress.total, 10)
        XCTAssertNil(progress.currentTitle)
    }

    func testAdvanceUpdatesCountAndTitle() {
        let progress = OPMLImportProgress()
        progress.start(total: 10)

        progress.advance(completed: 3, total: 10, title: "The Daily")
        XCTAssertEqual(progress.completed, 3)
        XCTAssertEqual(progress.total, 10)
        XCTAssertEqual(progress.currentTitle, "The Daily")

        progress.advance(completed: 4, total: 10, title: nil)
        XCTAssertEqual(progress.completed, 4)
        XCTAssertNil(progress.currentTitle, "A nil title (untitled feed) is reflected, not retained")
    }

    func testFinishDeactivatesPresentation() {
        let progress = OPMLImportProgress()
        progress.start(total: 5)
        progress.advance(completed: 5, total: 5, title: "Done")

        progress.finish()
        XCTAssertFalse(progress.isImporting, "finish() flips isImporting false so the screen auto-dismisses")
    }

    func testStartAfterFinishResetsForNextImport() {
        let progress = OPMLImportProgress()
        progress.start(total: 2)
        progress.advance(completed: 2, total: 2, title: "First import")
        progress.finish()

        progress.start(total: 4)
        XCTAssertTrue(progress.isImporting)
        XCTAssertEqual(progress.completed, 0, "counters reset on a fresh start")
        XCTAssertEqual(progress.total, 4)
        XCTAssertNil(progress.currentTitle, "stale title is cleared on a fresh start")
    }

    // MARK: importFile wiring

    /// Seeds already-subscribed podcasts so the import resolves offline (no network),
    /// the same strategy ``OPMLFileImporterTests`` uses.
    private func seedSubscribed(_ feedURLs: [String]) -> ModelContext {
        let ctx = TestStore.freshContext()
        for feedURL in feedURLs {
            ctx.insert(Podcast(feedURL: feedURL, title: "Seeded \(feedURL)"))
        }
        try? ctx.save()
        return ctx
    }

    private func writeOPML(_ opml: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("subscriptions.opml")
        try opml.data(using: .utf8)!.write(to: url)
        return url
    }

    /// `importFile` should activate the progress while importing and deactivate it
    /// when done — proving the screen presents during the import and auto-dismisses.
    func testImportFileDrivesProgressAndFinishes() async throws {
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

        let progress = OPMLImportProgress()
        let count = await OPMLFileImporter.importFile(at: url, context: ctx, progress: progress)

        XCTAssertEqual(count, 2)
        XCTAssertFalse(progress.isImporting, "progress is finished (screen auto-dismissed) after importFile returns")
        XCTAssertEqual(progress.completed, 2, "every feed advanced the count")
        XCTAssertEqual(progress.total, 2)
    }

    /// An unreadable file returns before the bulk path, so the progress is never
    /// activated — the empty progress screen never flashes for a bad file.
    func testUnreadableFileNeverActivatesProgress() async throws {
        let ctx = TestStore.freshContext()
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)/nope.opml")

        let progress = OPMLImportProgress()
        let count = await OPMLFileImporter.importFile(at: missing, context: ctx, progress: progress)

        XCTAssertNil(count)
        XCTAssertFalse(progress.isImporting, "a file that can't be read never presents the progress screen")
    }
}
