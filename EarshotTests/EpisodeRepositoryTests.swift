import XCTest
import SwiftData
@testable import Earshot

/// Covers `EpisodeRepository.markAllPlayed(in:)`, the batched "Mark all as
/// played" operation backing #640. The issue is explicitly about performance on
/// very large podcasts (1000+ episodes), so the primary fixture here is
/// oversized on purpose -- the point is proving one save fires per bounded
/// page, never one save per mutated row.
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

    func testMarkAllPlayedUsesBoundedSavesForLargeList() async throws {
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
        // Production bulk operations page durable library rows. Persist the
        // oversized fixture before the first fetch; a fetchLimit over pending
        // inserts is a different SwiftData registration scenario.
        try ctx.save()

        var saveCount = 0
        let repo = EpisodeRepository(context: ctx, onSave: { saveCount += 1 })

        let changed = await repo.markAllPlayed(in: p)

        XCTAssertEqual(changed, unplayedCount, "return value counts only episodes actually flipped")
        XCTAssertEqual(
            saveCount,
            Int(ceil(Double(unplayedCount) / Double(EpisodeRepository.batchSize))),
            "one durable save per bounded batch, never one save per episode"
        )
        XCTAssertTrue(unplayed.allSatisfy(\.isPlayed), "every previously-unplayed episode is now played")
        XCTAssertTrue(
            alreadyPlayed.allSatisfy { $0.playedAt == fixedPlayedAt },
            "already-played episodes' playedAt must not be overwritten to .now"
        )
        XCTAssertTrue((unplayed + alreadyPlayed).allSatisfy(\.isPlayed), "the whole podcast ends up fully played")
    }

    func testSelectedPlayedLeavesExceptionsAndOtherPodcastUntouched() async throws {
        let ctx = TestStore.freshContext()
        let podcast = makePodcast(ctx, "Selected")
        let otherPodcast = makePodcast(ctx, "Other")
        let episodes = (0..<225).map { makeEpisode(ctx, "e\($0)", podcast: podcast) }
        let unrelated = makeEpisode(ctx, "unrelated", podcast: otherPodcast)
        let fixedDate = Date(timeIntervalSince1970: 1_000_000)
        episodes[2].isPlayed = true
        episodes[2].playedAt = fixedDate
        try ctx.save()

        let source = EpisodeListDataSource(
            context: ctx, podcastID: podcast.persistentModelID, podcastTitle: podcast.title
        )
        let state = MultiSelectState()
        state.enter()
        state.selectAll(try await source.matchingEpisodeIDs(filter: .all, searchText: ""))
        state.toggle(episodes[0].persistentModelID)
        state.toggle(episodes[224].persistentModelID)
        // Even an accidentally supplied identifier from another podcast must
        // never change that podcast's played state.
        var selected = state.selectedIDs
        selected.insert(unrelated.persistentModelID)

        var saves = 0
        let changed = await EpisodeRepository(context: ctx, onSave: { saves += 1 })
            .markSelectedPlayed(in: podcast, ids: selected)

        XCTAssertEqual(changed, 222)
        XCTAssertEqual(saves, 3)
        XCTAssertFalse(episodes[0].isPlayed)
        XCTAssertFalse(episodes[224].isPlayed)
        XCTAssertFalse(unrelated.isPlayed)
        XCTAssertEqual(episodes[2].playedAt, fixedDate)
        XCTAssertTrue(episodes[100].inboxDismissed)
        XCTAssertTrue(episodes[223].isPlayed)
    }

    func testSelectedUnplayedRestoresOnlySelectedAndKeepsInboxDismissal() async throws {
        let ctx = TestStore.freshContext()
        let podcast = makePodcast(ctx, "Selected")
        let a = makeEpisode(ctx, "a", podcast: podcast)
        let b = makeEpisode(ctx, "b", podcast: podcast)
        let c = makeEpisode(ctx, "c", podcast: podcast)
        for episode in [a, b, c] {
            episode.isPlayed = true
            episode.inboxDismissed = true
        }
        let oldPlayedAt = c.playedAt
        try ctx.save()

        let changed = await EpisodeRepository(context: ctx).markSelectedUnplayed(
            in: podcast, ids: [a.persistentModelID, b.persistentModelID]
        )

        XCTAssertEqual(changed, 2)
        XCTAssertFalse(a.isPlayed)
        XCTAssertFalse(b.isPlayed)
        XCTAssertNil(a.playedAt)
        XCTAssertNil(b.playedAt)
        XCTAssertTrue(a.inboxDismissed)
        XCTAssertTrue(b.inboxDismissed)
        XCTAssertTrue(c.isPlayed)
        XCTAssertEqual(c.playedAt, oldPlayedAt)
    }

    // MARK: No-op cases -- must not dirty the context

    func testMarkAllPlayedOnFullyPlayedPodcastReturnsZeroAndSkipsSave() async {
        let ctx = TestStore.freshContext()
        let p = makePodcast(ctx, "A")
        let e = makeEpisode(ctx, "a", podcast: p)
        e.isPlayed = true

        var saveCount = 0
        let repo = EpisodeRepository(context: ctx, onSave: { saveCount += 1 })

        let changed = await repo.markAllPlayed(in: p)

        XCTAssertEqual(changed, 0)
        XCTAssertEqual(saveCount, 0, "no wasted save when nothing needs to change")
    }

    func testMarkAllPlayedOnEmptyPodcastReturnsZeroAndSkipsSave() async {
        let ctx = TestStore.freshContext()
        let p = makePodcast(ctx, "A")

        var saveCount = 0
        let repo = EpisodeRepository(context: ctx, onSave: { saveCount += 1 })

        let changed = await repo.markAllPlayed(in: p)

        XCTAssertEqual(changed, 0)
        XCTAssertEqual(saveCount, 0)
    }

    // MARK: Inbox-dismissal parity with the single-episode path

    /// The bulk path must dismiss episodes from the inbox exactly like
    /// `InboxRepository.markPlayed(_:)` (the single-episode mark-played path)
    /// does, so the inbox can't resurface episodes the user just bulk-marked
    /// played.
    func testMarkAllPlayedDismissesFromInboxMatchingSingleEpisodePath() async {
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
        _ = await repo.markAllPlayed(in: p)

        XCTAssertTrue(a.inboxDismissed, "bulk mark-played must dismiss from the inbox like the single-episode path")
        XCTAssertEqual(
            a.inboxDismissed, b.inboxDismissed,
            "bulk path's dismissal behavior matches InboxRepository.markPlayed's"
        )
    }
}
