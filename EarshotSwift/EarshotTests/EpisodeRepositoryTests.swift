import XCTest
import SwiftData
@testable import Earshot

/// Covers `EpisodeRepository.markAllPlayed(in:)`, the batched "Mark all as
/// played" operation backing #640. The issue is explicitly about performance on
/// very large podcasts (1000+ episodes), so the primary fixture here is
/// oversized on purpose -- the point is proving ONE batched save fires
/// regardless of episode count, not one save per mutated row.
@MainActor
final class EpisodeRepositoryTests: XCTestCase {

    // MARK: Fixtures

    private func makePodcast(_ ctx: ModelContext, _ title: String) -> Podcast {
        let p = Podcast(feedURL: "https://x/\(title).xml", title: title)
        ctx.insert(p)
        return p
    }

    private func makeEpisode(_ ctx: ModelContext, _ guid: String, podcast: Podcast) -> Episode {
        let e = Episode(guid: guid, title: "Ep \(guid)", audioURL: "https://x/\(guid).mp3")
        e.podcast = podcast
        ctx.insert(e)
        return e
    }

    // MARK: Large-list batching (the issue's explicit ask)

    func testMarkAllPlayedBatchesSaveExactlyOnceForLargeList() {
        let ctx = TestStore.freshContext()
        let p = makePodcast(ctx, "A")

        let unplayedCount = 1200
        let alreadyPlayedCount = 300
        let fixedPlayedAt = Date(timeIntervalSince1970: 1_000_000)

        let unplayed = (0..<unplayedCount).map { makeEpisode(ctx, "u\($0)", podcast: p) }
        let alreadyPlayed = (0..<alreadyPlayedCount).map { i -> Episode in
            let e = makeEpisode(ctx, "p\(i)", podcast: p)
            e.isPlayed = true
            e.playedAt = fixedPlayedAt // distinct from `.now` so overwrites are detectable
            return e
        }

        var saveCount = 0
        let repo = EpisodeRepository(context: ctx, onSave: { saveCount += 1 })

        let changed = repo.markAllPlayed(in: p)

        XCTAssertEqual(changed, unplayedCount, "return value counts only episodes actually flipped")
        XCTAssertEqual(saveCount, 1, "exactly one batched save regardless of episode count, not one per episode")
        XCTAssertTrue(unplayed.allSatisfy(\.isPlayed), "every previously-unplayed episode is now played")
        XCTAssertTrue(
            alreadyPlayed.allSatisfy { $0.playedAt == fixedPlayedAt },
            "already-played episodes' playedAt must not be overwritten to .now"
        )
        XCTAssertTrue((unplayed + alreadyPlayed).allSatisfy(\.isPlayed), "the whole podcast ends up fully played")
    }

    // MARK: No-op cases -- must not dirty the context

    func testMarkAllPlayedOnFullyPlayedPodcastReturnsZeroAndSkipsSave() {
        let ctx = TestStore.freshContext()
        let p = makePodcast(ctx, "A")
        let e = makeEpisode(ctx, "a", podcast: p)
        e.isPlayed = true

        var saveCount = 0
        let repo = EpisodeRepository(context: ctx, onSave: { saveCount += 1 })

        let changed = repo.markAllPlayed(in: p)

        XCTAssertEqual(changed, 0)
        XCTAssertEqual(saveCount, 0, "no wasted save when nothing needs to change")
    }

    func testMarkAllPlayedOnEmptyPodcastReturnsZeroAndSkipsSave() {
        let ctx = TestStore.freshContext()
        let p = makePodcast(ctx, "A")

        var saveCount = 0
        let repo = EpisodeRepository(context: ctx, onSave: { saveCount += 1 })

        let changed = repo.markAllPlayed(in: p)

        XCTAssertEqual(changed, 0)
        XCTAssertEqual(saveCount, 0)
    }

    // MARK: Inbox-dismissal parity with the single-episode path

    /// The bulk path must dismiss episodes from the inbox exactly like
    /// `InboxRepository.markPlayed(_:)` (the single-episode mark-played path)
    /// does, so the inbox can't resurface episodes the user just bulk-marked
    /// played.
    func testMarkAllPlayedDismissesFromInboxMatchingSingleEpisodePath() {
        let ctx = TestStore.freshContext()
        let p = makePodcast(ctx, "A")
        let a = makeEpisode(ctx, "a", podcast: p)
        let b = makeEpisode(ctx, "b", podcast: p)
        XCTAssertFalse(a.inboxDismissed, "precondition: a fresh episode isn't dismissed")
        XCTAssertFalse(b.inboxDismissed, "precondition: a fresh episode isn't dismissed")

        // Reference: the existing single-episode mark-played path.
        InboxRepository(context: ctx).markPlayed(b)

        // Under test: the new bulk path, applied to the whole podcast (including a).
        let repo = EpisodeRepository(context: ctx)
        _ = repo.markAllPlayed(in: p)

        XCTAssertTrue(a.inboxDismissed, "bulk mark-played must dismiss from the inbox like the single-episode path")
        XCTAssertEqual(
            a.inboxDismissed, b.inboxDismissed,
            "bulk path's dismissal behavior matches InboxRepository.markPlayed's"
        )
    }
}
