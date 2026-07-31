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

    // MARK: onCapSkipped (#632) — the free-tier podcast cap paywall trigger

    /// Builds a minimal flat (non-folder) OPML document from a feed URL list,
    /// matching the shape `OPMLBulkImportTests` uses.
    private func opml(feeds: [String]) -> String {
        let outlines = feeds.map { "<outline type=\"rss\" text=\"\($0)\" xmlUrl=\"\($0)\"/>" }.joined(separator: "\n")
        return "<opml><body>\n\(outlines)\n</body></opml>"
    }

    /// Spy for the `@MainActor @Sendable` `onCapSkipped` callback — mirrors
    /// `OPMLBulkImportTests`' `ProgressRecorder` pattern for capturing state from
    /// a closure of the same shape (both this test class and the closure are
    /// `@MainActor`, so a plain reference type is a safe capture).
    @MainActor
    private final class CapSkippedSpy {
        private(set) var fireCount = 0
        func fire() { fireCount += 1 }
    }

    /// A non-entitled user already at/over the free-tier limit (15 existing
    /// podcasts, cap 10) requesting more feeds gets the whole request trimmed to
    /// zero (`PodcastCapPolicy.allowedNewSubscriptions` clamps at 0, never
    /// negative) — `skippedForCapCount` is the full requested count, and
    /// `onCapSkipped` (the signal `DataSettingsView` uses to present the Earshot
    /// Plus paywall) must fire exactly once, not once per skipped feed. Because
    /// the whole request is trimmed to zero, none of the 3 requested feeds are
    /// ever attempted, so they need not be pre-seeded — this stays fully offline.
    func testOnCapSkippedFiresOnceWhenImportIsFullyTrimmedByCap() async throws {
        let existingFeeds = (0..<15).map { "https://existing\($0).com/feed" }
        let requestedFeeds = (0..<3).map { "https://newcap\($0).com/rss" }
        let ctx = seedSubscribed(existingFeeds)
        let url = try writeOPML(opml(feeds: requestedFeeds))

        let spy = CapSkippedSpy()
        let count = await OPMLFileImporter.importFile(
            at: url, context: ctx, isEntitled: false,
            onCapSkipped: { spy.fire() }
        )

        XCTAssertEqual(count, 0, "already over the cap: zero free slots remain")
        XCTAssertEqual(spy.fireCount, 1, "must fire exactly once, not once per skipped feed")
    }

    /// An entitled (Plus) user's import is never trimmed by the cap, so
    /// `onCapSkipped` must never fire even though every feed is genuinely new.
    func testOnCapSkippedDoesNotFireForEntitledUser() async throws {
        let requestedFeeds = (0..<3).map { "https://plusfeed\($0).com/rss" }
        let ctx = seedSubscribed(requestedFeeds) // pre-seeded so resolution stays offline
        let url = try writeOPML(opml(feeds: requestedFeeds))

        let spy = CapSkippedSpy()
        let count = await OPMLFileImporter.importFile(
            at: url, context: ctx, isEntitled: true,
            onCapSkipped: { spy.fire() }
        )

        XCTAssertEqual(count, 3)
        XCTAssertEqual(spy.fireCount, 0, "an entitled user's import is never trimmed, so the paywall must never show")
    }

    /// A free-tier import that stays comfortably under the cap must not fire
    /// `onCapSkipped` either — the paywall is only for a genuinely trimmed import.
    func testOnCapSkippedDoesNotFireWhenImportStaysUnderCap() async throws {
        let requestedFeeds = (0..<2).map { "https://undercap\($0).com/rss" }
        let ctx = seedSubscribed(requestedFeeds)
        let url = try writeOPML(opml(feeds: requestedFeeds))

        let spy = CapSkippedSpy()
        let count = await OPMLFileImporter.importFile(
            at: url, context: ctx, isEntitled: false,
            onCapSkipped: { spy.fire() }
        )

        XCTAssertEqual(count, 2)
        XCTAssertEqual(spy.fireCount, 0)
    }

    /// `isEntitled == nil` (the default, omitted here) means the cap isn't
    /// enforced at this call site at all — matches every legacy/test call site
    /// that predates #635 — so `onCapSkipped` must never fire regardless of
    /// requested count.
    func testOnCapSkippedDoesNotFireWhenEntitlementIsNil() async throws {
        let requestedFeeds = (0..<12).map { "https://nilentitlement\($0).com/rss" }
        let ctx = seedSubscribed(requestedFeeds)
        let url = try writeOPML(opml(feeds: requestedFeeds))

        let spy = CapSkippedSpy()
        let count = await OPMLFileImporter.importFile(
            at: url, context: ctx,
            onCapSkipped: { spy.fire() }
        )

        XCTAssertEqual(count, 12)
        XCTAssertEqual(spy.fireCount, 0)
    }
}
