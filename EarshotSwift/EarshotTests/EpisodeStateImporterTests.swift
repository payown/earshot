import XCTest
import SwiftData
@testable import Earshot

@MainActor
final class EpisodeStateImporterTests: XCTestCase {

    /// Inserts a podcast with the given episodes (defaulting to the post-backfill
    /// state: unplayed, inbox-dismissed) and returns the context.
    private func seedStore(
        _ specs: [(guid: String, audio: String)]
    ) -> ModelContext {
        let ctx = TestStore.freshContext()
        let podcast = Podcast(feedURL: "https://x/feed.xml", title: "Show")
        ctx.insert(podcast)
        for spec in specs {
            let episode = Episode(
                guid: spec.guid,
                title: "Ep \(spec.guid)",
                audioURL: spec.audio,
                inboxDismissed: true // mirrors the migration backfill default
            )
            episode.podcast = podcast
            ctx.insert(episode)
        }
        try? ctx.save()
        return ctx
    }

    private func episode(_ ctx: ModelContext, guid: String) throws -> Episode {
        let all = try ctx.fetch(FetchDescriptor<Episode>())
        return try XCTUnwrap(all.first { $0.guid == guid })
    }

    func testRestoresPlayedAndInboxStateByGUID() throws {
        let ctx = seedStore([
            (guid: "played", audio: "https://x/played.mp3"),
            (guid: "inbox", audio: "https://x/inbox.mp3"),
            (guid: "untouched", audio: "https://x/untouched.mp3"),
        ])

        let count = try EpisodeStateImporter(context: ctx).apply([
            FlutterEpisode(guid: "played", audioURL: "https://x/played.mp3", isPlayed: true, inboxDismissed: true, pubDate: nil, positionSeconds: 300),
            FlutterEpisode(guid: "inbox", audioURL: "https://x/inbox.mp3", isPlayed: false, inboxDismissed: false, pubDate: nil, positionSeconds: nil),
            // No record for "untouched" -> it keeps the backfill default.
        ])

        XCTAssertEqual(count, 2)

        let played = try episode(ctx, guid: "played")
        XCTAssertTrue(played.isPlayed)
        XCTAssertEqual(played.status, .played)
        XCTAssertTrue(played.inboxDismissed)
        XCTAssertEqual(played.positionSeconds, 300)

        let inbox = try episode(ctx, guid: "inbox")
        XCTAssertFalse(inbox.isPlayed)
        XCTAssertEqual(inbox.status, .newEpisode)
        XCTAssertFalse(inbox.inboxDismissed) // restored into the inbox

        let untouched = try episode(ctx, guid: "untouched")
        XCTAssertFalse(untouched.isPlayed)
        XCTAssertTrue(untouched.inboxDismissed) // unchanged
    }

    func testMatchesByAudioURLWhenGUIDDiffers() throws {
        let ctx = seedStore([(guid: "new-guid", audio: "https://x/ep.mp3")])

        let count = try EpisodeStateImporter(context: ctx).apply([
            FlutterEpisode(guid: "old-guid", audioURL: "https://x/ep.mp3", isPlayed: true, inboxDismissed: true, pubDate: nil, positionSeconds: nil),
        ])

        XCTAssertEqual(count, 1)
        XCTAssertTrue(try episode(ctx, guid: "new-guid").isPlayed)
    }

    func testPlayedStateForcesInboxDismissedEvenIfRecordSaysOtherwise() throws {
        let ctx = seedStore([(guid: "g", audio: "https://x/g.mp3")])

        try EpisodeStateImporter(context: ctx).apply([
            FlutterEpisode(guid: "g", audioURL: "https://x/g.mp3", isPlayed: true, inboxDismissed: false, pubDate: nil, positionSeconds: nil),
        ])

        let ep = try episode(ctx, guid: "g")
        XCTAssertTrue(ep.isPlayed)
        XCTAssertTrue(ep.inboxDismissed) // played -> never in the inbox
    }

    func testZeroPositionDoesNotClobberExisting() throws {
        let ctx = seedStore([(guid: "g", audio: "https://x/g.mp3")])
        let seeded = try episode(ctx, guid: "g")
        seeded.positionSeconds = 42
        try? ctx.save()

        try EpisodeStateImporter(context: ctx).apply([
            FlutterEpisode(guid: "g", audioURL: "https://x/g.mp3", isPlayed: false, inboxDismissed: false, pubDate: nil, positionSeconds: 0),
        ])

        XCTAssertEqual(try episode(ctx, guid: "g").positionSeconds, 42)
    }

    func testEmptyInputIsANoOp() throws {
        let ctx = seedStore([(guid: "g", audio: "https://x/g.mp3")])
        XCTAssertEqual(try EpisodeStateImporter(context: ctx).apply([]), 0)
        XCTAssertTrue(try episode(ctx, guid: "g").inboxDismissed) // unchanged
    }
}
