import XCTest
import SwiftData
@testable import Earshot

@MainActor
final class QueueImporterTests: XCTestCase {

    /// Seeds a podcast with the given episodes (post-backfill default: unplayed,
    /// inbox-dismissed, not queued) and returns the context.
    private func seedStore(_ specs: [(guid: String, audio: String)]) -> ModelContext {
        let ctx = TestStore.freshContext()
        let podcast = Podcast(feedURL: "https://x/feed.xml", title: "Show")
        ctx.insert(podcast)
        for spec in specs {
            let episode = Episode(
                guid: spec.guid,
                title: "Ep \(spec.guid)",
                audioURL: spec.audio,
                inboxDismissed: true
            )
            episode.podcast = podcast
            ctx.insert(episode)
        }
        try? ctx.save()
        return ctx
    }

    private func queuedGUIDs(_ ctx: ModelContext) -> [String] {
        QueueRepository(context: ctx).queue().map(\.guid)
    }

    func testRestoresQueueInPositionOrder() throws {
        let ctx = seedStore([
            (guid: "a", audio: "https://x/a.mp3"),
            (guid: "b", audio: "https://x/b.mp3"),
            (guid: "c", audio: "https://x/c.mp3"),
        ])

        // Deliberately out of array order; position drives the result.
        let added = try QueueImporter(context: ctx).apply([
            FlutterQueueEntry(guid: "c", audioURL: "https://x/c.mp3", position: 2),
            FlutterQueueEntry(guid: "a", audioURL: "https://x/a.mp3", position: 0),
            FlutterQueueEntry(guid: "b", audioURL: "https://x/b.mp3", position: 1),
        ])

        XCTAssertEqual(added, 3)
        XCTAssertEqual(queuedGUIDs(ctx), ["a", "b", "c"])
    }

    func testQueuedEpisodesAreMarkedInQueue() throws {
        let ctx = seedStore([(guid: "a", audio: "https://x/a.mp3")])
        try QueueImporter(context: ctx).apply([
            FlutterQueueEntry(guid: "a", audioURL: "https://x/a.mp3", position: 0),
        ])
        let episode = try XCTUnwrap(try ctx.fetch(FetchDescriptor<Episode>()).first)
        XCTAssertEqual(episode.status, .inQueue)
        XCTAssertNotNil(episode.queueItem)
    }

    func testMatchesByAudioURLWhenGUIDChanged() throws {
        let ctx = seedStore([(guid: "new-guid", audio: "https://x/a.mp3")])
        let added = try QueueImporter(context: ctx).apply([
            FlutterQueueEntry(guid: "old-guid", audioURL: "https://x/a.mp3", position: 0),
        ])
        XCTAssertEqual(added, 1)
        XCTAssertEqual(queuedGUIDs(ctx), ["new-guid"])
    }

    func testSkipsEntriesThatMatchNothing() throws {
        let ctx = seedStore([(guid: "a", audio: "https://x/a.mp3")])
        let added = try QueueImporter(context: ctx).apply([
            FlutterQueueEntry(guid: "a", audioURL: "https://x/a.mp3", position: 0),
            FlutterQueueEntry(guid: "gone", audioURL: "https://x/gone.mp3", position: 1),
        ])
        XCTAssertEqual(added, 1)
        XCTAssertEqual(queuedGUIDs(ctx), ["a"])
    }

    func testReRunIsIdempotentAndPreservesExistingOrder() throws {
        let ctx = seedStore([
            (guid: "a", audio: "https://x/a.mp3"),
            (guid: "b", audio: "https://x/b.mp3"),
        ])
        let entries = [
            FlutterQueueEntry(guid: "a", audioURL: "https://x/a.mp3", position: 0),
            FlutterQueueEntry(guid: "b", audioURL: "https://x/b.mp3", position: 1),
        ]
        let importer = QueueImporter(context: ctx)
        XCTAssertEqual(try importer.apply(entries), 2)
        // Second run: already queued, nothing added or reordered.
        XCTAssertEqual(try importer.apply(entries), 0)
        XCTAssertEqual(queuedGUIDs(ctx), ["a", "b"])
    }

    func testEmptyInputIsANoOp() throws {
        let ctx = seedStore([(guid: "a", audio: "https://x/a.mp3")])
        XCTAssertEqual(try QueueImporter(context: ctx).apply([]), 0)
        XCTAssertTrue(queuedGUIDs(ctx).isEmpty)
    }
}
