import XCTest
import SwiftData
@testable import Earshot

/// The inbox tab badge count must NOT be computed by materializing the whole
/// non-dismissed library and filtering `status` in Swift. On a large library
/// that re-runs on every 5-second playback-position save and saturates the main
/// thread, and iOS force-terminates the app under its `cpu_resource_fatal` limit
/// (~93% CPU over 60s). The fix restricts the store fetch to unplayed,
/// non-dismissed episodes (`InboxQuery.unplayedPredicate`) — excluding the
/// played-history bucket that grows without bound because finished episodes are
/// never dismissed — then applies the exact `.newEpisode` membership check in
/// memory over that small set. See `RootView.InboxTabBadge` and
/// `InboxRepository.inboxCount(optInOnly:)`.
@MainActor
final class InboxBadgeCountTests: XCTestCase {

    private func podcast(_ ctx: ModelContext, _ title: String) -> Podcast {
        let p = Podcast(feedURL: "https://x/\(title).xml", title: title)
        ctx.insert(p)
        return p
    }

    @discardableResult
    private func episode(_ ctx: ModelContext, _ guid: String, podcast: Podcast,
                         status: EpisodeStatus = .newEpisode, dismissed: Bool = false,
                         played: Bool = false) -> Episode {
        let e = Episode(guid: guid, title: "Ep \(guid)", audioURL: "https://x/\(guid).mp3",
                        pubDate: nil, status: status, inboxDismissed: dismissed)
        e.podcast = podcast
        // Route played episodes through the real setter so `playedAt` is set the
        // same way production does (this is exactly what the fix's predicate keys
        // off). A played episode's `playedAt` must be non-nil.
        if played { e.isPlayed = true }
        ctx.insert(e)
        return e
    }

    /// Only `.newEpisode`, undismissed episodes from non-excluded podcasts count.
    /// Played, in-queue, dismissed, and excluded-podcast episodes must not.
    func testInboxCountCountsOnlyNewUndismissedFromIncludedPodcasts() {
        let ctx = TestStore.freshContext()
        let a = podcast(ctx, "A")
        let excluded = podcast(ctx, "B")
        excluded.inboxExcluded = true

        episode(ctx, "a-new1", podcast: a)
        episode(ctx, "a-new2", podcast: a)
        episode(ctx, "a-dismissed", podcast: a, dismissed: true)   // dismissed → out
        episode(ctx, "a-played", podcast: a, played: true)         // played → out
        episode(ctx, "a-inqueue", podcast: a, status: .inQueue)    // in queue → out
        episode(ctx, "b-new-excluded", podcast: excluded)          // excluded show → out
        try? ctx.save()

        let repo = InboxRepository(context: ctx)
        XCTAssertEqual(repo.inboxCount(optInOnly: false), 2)
    }

    /// The badge count must equal the materialized inbox count for the same
    /// (normal) mode, so the badge never drifts from the Inbox screen's list.
    func testInboxCountMatchesMaterializedInboxEpisodes() {
        let ctx = TestStore.freshContext()
        let a = podcast(ctx, "A")
        let b = podcast(ctx, "B")
        episode(ctx, "a-new", podcast: a)
        episode(ctx, "b-new", podcast: b)
        episode(ctx, "b-played", podcast: b, played: true)
        episode(ctx, "b-dismissed", podcast: b, dismissed: true)
        try? ctx.save()

        let repo = InboxRepository(context: ctx)
        XCTAssertEqual(repo.inboxCount(optInOnly: false), repo.inboxEpisodes().count)
    }

    /// In opt-in-only mode, only podcasts explicitly opted in contribute.
    func testInboxCountOptInOnlyCountsOnlyIncludedPodcasts() {
        let ctx = TestStore.freshContext()
        let optedIn = podcast(ctx, "A")
        optedIn.inboxIncluded = true
        let normal = podcast(ctx, "B") // not opted in

        episode(ctx, "a-new", podcast: optedIn)
        episode(ctx, "b-new", podcast: normal)
        try? ctx.save()

        let repo = InboxRepository(context: ctx)
        XCTAssertEqual(repo.inboxCount(optInOnly: true), 1)
    }

    /// Regression guard for the `playedAt == nil` fetch: clearing the queue
    /// reverts its episodes to `.newEpisode`, so a played-then-queued episode
    /// resurfaces in the inbox. The badge counted it before this fix; it must
    /// still count it. This holds only if `QueueRepository.clear()` restores the
    /// "a `.newEpisode` episode is unplayed" invariant (clears `playedAt`) — a
    /// raw `status = .newEpisode` would leave a stale `playedAt` that the unplayed
    /// fetch silently drops, undercounting the badge.
    func testClearedQueueRevertsPlayedEpisodeIntoInboxCount() {
        let ctx = TestStore.freshContext()
        let p = podcast(ctx, "A")
        let e = episode(ctx, "played-then-queued", podcast: p, played: true)
        try? ctx.save()

        let queue = QueueRepository(context: ctx)
        queue.add(e)
        queue.clear()

        let repo = InboxRepository(context: ctx)
        XCTAssertEqual(repo.inboxCount(optInOnly: false), 1)
    }

    /// The performance guard: the store fetch that backs the badge must EXCLUDE
    /// played episodes, because that bucket grows without bound over listening
    /// history and materializing it on every playback-position save is what
    /// triggered the CPU-limit termination. If a future change lets played
    /// episodes back into `unplayedPredicate`, this fails.
    func testUnplayedFetchExcludesPlayedEpisodes() {
        let ctx = TestStore.freshContext()
        let a = podcast(ctx, "A")
        episode(ctx, "new", podcast: a)
        episode(ctx, "played-1", podcast: a, played: true)
        episode(ctx, "played-2", podcast: a, played: true)
        try? ctx.save()

        let fetched = (try? ctx.fetch(
            FetchDescriptor<Episode>(predicate: InboxQuery.unplayedPredicate(optInOnly: false))
        )) ?? []
        let guids = Set(fetched.map(\.guid))
        XCTAssertTrue(guids.contains("new"))
        XCTAssertFalse(guids.contains("played-1"))
        XCTAssertFalse(guids.contains("played-2"))
    }

    /// #736: the badge's cheap change-detector `inboxCandidateCount` is a
    /// store-level COUNT of the unplayed, non-dismissed set — a superset of the
    /// exact `inboxCount` (it also counts queued/expired unplayed episodes). It
    /// must never undercount the badge, or the detector could hide a real change.
    func testInboxCandidateCountIsSupersetOfInboxCount() {
        let ctx = TestStore.freshContext()
        let a = podcast(ctx, "A")
        episode(ctx, "new1", podcast: a)
        episode(ctx, "new2", podcast: a)
        episode(ctx, "queued", podcast: a, status: .inQueue)   // unplayed, not dismissed → candidate only
        episode(ctx, "expired", podcast: a, status: .expired)  // unplayed, not dismissed → candidate only
        episode(ctx, "played", podcast: a, played: true)       // excluded from both
        episode(ctx, "dismissed", podcast: a, dismissed: true) // excluded from both
        try? ctx.save()

        let repo = InboxRepository(context: ctx)
        XCTAssertEqual(repo.inboxCount(optInOnly: false), 2, "exact badge = the 2 new episodes")
        XCTAssertEqual(repo.inboxCandidateCount(optInOnly: false), 4,
                       "candidates add queued + expired (still unplayed, non-dismissed)")
        XCTAssertGreaterThanOrEqual(repo.inboxCandidateCount(optInOnly: false),
                                    repo.inboxCount(optInOnly: false),
                                    "candidate detector must never undercount the badge")
    }

    /// #736: the detector's guarantee. A playback-position save mutates only
    /// `positionSeconds`, so it must NOT change the candidate total — that's what
    /// lets `InboxTabBadge` skip the expensive exact recompute on the ~5-second
    /// position-save hot path that was heating the phone.
    func testPositionSaveDoesNotChangeCandidateCount() {
        let ctx = TestStore.freshContext()
        let a = podcast(ctx, "A")
        for i in 0..<20 { episode(ctx, "e\(i)", podcast: a) }
        try? ctx.save()

        let repo = InboxRepository(context: ctx)
        let before = repo.inboxCandidateCount(optInOnly: false)

        let first = try? ctx.fetch(
            FetchDescriptor<Episode>(predicate: InboxQuery.normalUnplayed)
        ).first
        first?.positionSeconds = 321
        try? ctx.save()

        XCTAssertEqual(repo.inboxCandidateCount(optInOnly: false), before,
                       "a position save must not move the candidate total")
    }
}
