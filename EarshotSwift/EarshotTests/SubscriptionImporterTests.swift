import XCTest
import SwiftData
@testable import Earshot

/// Captures progress callback values across the actor boundary.
private final class ProgressRecorder: @unchecked Sendable {
    var calls = 0
    var lastCompleted = 0
    var lastTotal = 0
}

@MainActor
final class SubscriptionImporterTests: XCTestCase {

    private func cleanContainer() -> ModelContainer {
        _ = TestStore.freshContext() // wipe the shared in-memory store first
        return TestStore.container
    }

    private func sub(_ url: String, title: String? = "T", author: String? = nil, artwork: String? = nil) -> FlutterSubscription {
        FlutterSubscription(rssURL: url, title: title, author: author, artworkURL: artwork)
    }

    private func podcasts(_ container: ModelContainer) throws -> [Podcast] {
        try ModelContext(container).fetch(FetchDescriptor<Podcast>())
    }

    private func episodeCount(_ container: ModelContainer) throws -> Int {
        try ModelContext(container).fetch(FetchDescriptor<Episode>()).count
    }

    func testCreatesShellsWithNoEpisodesAndReportsProgress() async throws {
        let container = cleanContainer()
        let importer = SubscriptionImporter(modelContainer: container)
        let recorder = ProgressRecorder()

        let count = await importer.importShells(
            [sub("https://a/feed.xml"), sub("https://b/feed.xml"), sub("https://c/feed.xml")]
        ) { completed, total in
            recorder.calls += 1
            recorder.lastCompleted = completed
            recorder.lastTotal = total
        }

        XCTAssertEqual(count, 3)
        XCTAssertEqual(recorder.calls, 3)
        XCTAssertEqual(recorder.lastCompleted, 3)
        XCTAssertEqual(recorder.lastTotal, 3)
        XCTAssertEqual(try podcasts(container).count, 3)
        XCTAssertEqual(try episodeCount(container), 0) // shells: no episodes
    }

    func testShellCarriesMetadataAndLeavesMarkUnseeded() async throws {
        let container = cleanContainer()
        let importer = SubscriptionImporter(modelContainer: container)

        _ = await importer.importShells(
            [sub("https://a/feed.xml", title: "Show A", author: "Host", artwork: "https://art")]
        ) { _, _ in }

        let podcast = try XCTUnwrap(try podcasts(container).first)
        XCTAssertEqual(podcast.title, "Show A")
        XCTAssertEqual(podcast.author, "Host")
        XCTAssertEqual(podcast.artworkURL, "https://art")
        XCTAssertNil(podcast.lastSeenPubDate) // first refresh seeds it
        XCTAssertNil(podcast.refreshedAt)     // drives the "Loading episodes…" state
    }

    func testFallsBackToUntitledWhenTitleMissing() async throws {
        let container = cleanContainer()
        let importer = SubscriptionImporter(modelContainer: container)
        _ = await importer.importShells([sub("https://a/feed.xml", title: nil)]) { _, _ in }
        let podcast = try XCTUnwrap(try podcasts(container).first)
        XCTAssertEqual(podcast.title, "Untitled podcast")
    }

    func testSkipsBlankAndDuplicateFeeds() async throws {
        let container = cleanContainer()
        let importer = SubscriptionImporter(modelContainer: container)

        let count = await importer.importShells(
            [sub("https://a/feed.xml"), sub("   "), sub("https://a/feed.xml")]
        ) { _, _ in }

        XCTAssertEqual(count, 1) // blank skipped, duplicate deduped
        XCTAssertEqual(try podcasts(container).count, 1)
    }
}
