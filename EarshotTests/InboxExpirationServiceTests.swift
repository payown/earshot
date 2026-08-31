import XCTest
import SwiftData
@testable import Earshot

@MainActor
final class InboxExpirationServiceTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private func daysAgo(_ d: Double) -> Date { now.addingTimeInterval(-d * 86400) }
    private func hoursAgo(_ h: Double) -> Date { now.addingTimeInterval(-h * 3600) }

    private func podcast(_ ctx: ModelContext, _ title: String) -> Podcast {
        let p = Podcast(feedURL: "https://x/\(title).xml", title: title)
        ctx.insert(p)
        return p
    }

    @discardableResult
    private func episode(_ ctx: ModelContext, _ guid: String, podcast: Podcast,
                         status: EpisodeStatus = .newEpisode, pubDate: Date? = nil,
                         dismissed: Bool = false) -> Episode {
        let e = Episode(guid: guid, title: "Ep \(guid)", audioURL: "https://x/\(guid).mp3",
                        pubDate: pubDate, status: status, inboxDismissed: dismissed)
        e.podcast = podcast
        ctx.insert(e)
        return e
    }

    // MARK: Inbox filtering

    func testInboxIncludesOnlyNewUndismissed() {
        let ctx = TestStore.freshContext()
        let p = podcast(ctx, "A")
        episode(ctx, "new", podcast: p)
        episode(ctx, "dismissed", podcast: p, dismissed: true)
        episode(ctx, "played", podcast: p, status: .played)
        try? ctx.save()

        let titles = InboxRepository(context: ctx).inboxEpisodes().map(\.title)
        XCTAssertEqual(titles, ["Ep new"])
    }

    func testInboxExcludesExcludedPodcasts() {
        let ctx = TestStore.freshContext()
        let included = podcast(ctx, "A")
        let excluded = podcast(ctx, "B")
        excluded.inboxExcluded = true
        episode(ctx, "a", podcast: included)
        episode(ctx, "b", podcast: excluded)
        try? ctx.save()

        XCTAssertEqual(InboxRepository(context: ctx).inboxEpisodes().map(\.title), ["Ep a"])
    }

    /// `inbox(from:)` is the in-memory pass the views now run over a
    /// predicate-filtered `@Query` (non-dismissed, newest first) instead of
    /// re-fetching via `inboxEpisodes()` on every body. It must produce the exact
    /// same episodes in the same order, or the badge/list/heading would drift
    /// from the canonical fetch.
    func testInboxFromCandidatesMatchesInboxEpisodes() {
        let ctx = TestStore.freshContext()
        let a = podcast(ctx, "A")
        let b = podcast(ctx, "B")
        let excluded = podcast(ctx, "C")
        excluded.inboxExcluded = true
        // Mixed statuses, dismissal, exclusion, and varied pubDates across shows.
        episode(ctx, "a-new-old", podcast: a, pubDate: daysAgo(5))
        episode(ctx, "a-new-recent", podcast: a, pubDate: daysAgo(1))
        episode(ctx, "a-dismissed", podcast: a, pubDate: daysAgo(2), dismissed: true)
        episode(ctx, "a-played", podcast: a, status: .played, pubDate: daysAgo(3))
        episode(ctx, "b-new-mid", podcast: b, pubDate: daysAgo(3))
        episode(ctx, "b-nil-date", podcast: b, pubDate: nil)
        episode(ctx, "c-excluded", podcast: excluded, pubDate: daysAgo(1))
        try? ctx.save()

        let repo = InboxRepository(context: ctx)
        let canonical = repo.inboxEpisodes()

        // Re-create the views' predicate-filtered @Query: non-dismissed, newest
        // first. `inbox(from:)` then applies the remaining status + exclusion rules.
        var descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate { $0.inboxDismissed == false },
            sortBy: [SortDescriptor(\.pubDate, order: .reverse)]
        )
        descriptor.relationshipKeyPathsForPrefetching = [\Episode.podcast]
        let candidates = (try? ctx.fetch(descriptor)) ?? []
        let viaCandidates = repo.inbox(from: candidates)

        // Identical order and contents to the canonical fetch (this is the parity
        // the views depend on; ordering is covered here since both share the same
        // sort descriptor).
        XCTAssertEqual(viaCandidates.map(\.guid), canonical.map(\.guid))
        // Membership is correct: only new, undismissed, non-excluded episodes.
        // Set comparison avoids depending on where a nil pubDate lands in the sort.
        XCTAssertEqual(Set(canonical.map(\.title)),
                       ["Ep a-new-recent", "Ep b-new-mid", "Ep a-new-old", "Ep b-nil-date"])
    }

    func testLiveEpisodeFilterDropsDeletedCachedCandidateBeforePersistedAccess() throws {
        let ctx = TestStore.freshContext()
        let p = podcast(ctx, "A")
        let deleted = episode(ctx, "deleted", podcast: p)
        let retained = episode(ctx, "retained", podcast: p)
        try ctx.save()

        // Matches AllInboxCandidates retaining a prior event-driven fetch while
        // refresh identity repair deletes that Episode in the same view context.
        let cached = [deleted, retained]
        ctx.delete(deleted)
        try ctx.save()

        XCTAssertEqual(
            InboxRepository.liveEpisodes(cached, in: ctx).map(\.persistentModelID),
            [retained.persistentModelID]
        )
    }

    func testApplyLimitsDismissesByCount() {
        let ctx = TestStore.freshContext()
        let p = podcast(ctx, "A")
        p.inboxMaxEpisodes = 1
        episode(ctx, "old", podcast: p, pubDate: daysAgo(2))
        episode(ctx, "new", podcast: p, pubDate: daysAgo(1))
        try? ctx.save()

        InboxRepository(context: ctx).applyLimits(now: now)
        XCTAssertEqual(InboxRepository(context: ctx).inboxEpisodes().map(\.title), ["Ep new"])
    }

    func testApplyLimitsDismissesByAgeKeepsStarted() {
        let ctx = TestStore.freshContext()
        let p = podcast(ctx, "A")
        p.inboxAgeLimitHours = 24
        episode(ctx, "stale", podcast: p, pubDate: hoursAgo(50))
        let started = episode(ctx, "started", podcast: p, pubDate: hoursAgo(50))
        started.positionSeconds = 30
        try? ctx.save()

        InboxRepository(context: ctx).applyLimits(now: now)
        // Stale unplayed dismissed; started one stays despite age.
        XCTAssertEqual(InboxRepository(context: ctx).inboxEpisodes().map(\.title), ["Ep started"])
    }

    func testClearInboxDismissesAll() {
        let ctx = TestStore.freshContext()
        let p = podcast(ctx, "A")
        episode(ctx, "a", podcast: p)
        episode(ctx, "b", podcast: p)
        try? ctx.save()

        InboxRepository(context: ctx).clearInbox()
        XCTAssertTrue(InboxRepository(context: ctx).inboxEpisodes().isEmpty)
    }

    // MARK: Expiration

    func testExpiresStaleQueuedEpisodesAndPersistsOneOrderingIntent() throws {
        let ctx = TestStore.freshContext()
        let p = podcast(ctx, "A")
        p.queueAgeLimitDays = 7
        let episodes = ["old-a", "old-b"].enumerated().map { position, guid in
            let episode = episode(ctx, guid, podcast: p, status: .inQueue)
            ctx.insert(QueueItem(episode: episode, position: position, addedAt: daysAgo(10)))
            return episode
        }
        try ctx.save()

        ExpirationService(context: ctx).runExpiration(now: now)

        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<QueueItem>()), 0)
        XCTAssertEqual(ExpirationService(context: ctx).recentlyExpired().count, 2)
        XCTAssertTrue(episodes.allSatisfy { $0.status == .expired })
        let removals = try PendingCloudQueueMutation.memberships(in: ctx)
        XCTAssertEqual(Set(removals.map(\.guid)), ["old-a", "old-b"])
        XCTAssertTrue(removals.allSatisfy { !$0.isQueued && $0.eventDate == now })
        XCTAssertEqual(try PendingCloudQueueMutation.orderings(in: ctx).count, 1)
    }

    func testCatalogExpirationDoesNotCreateCloudQueueIntent() throws {
        let ctx = TestStore.freshContext()
        let p = podcast(ctx, "Catalog")
        p.subscriptionStateRaw = PodcastSubscriptionState.catalogOnly.rawValue
        p.queueAgeLimitDays = 7
        let e = episode(ctx, "old", podcast: p, status: .inQueue)
        ctx.insert(QueueItem(episode: e, position: 0, addedAt: daysAgo(10)))
        try ctx.save()

        ExpirationService(context: ctx).runExpiration(now: now)

        XCTAssertTrue(try PendingCloudQueueMutation.memberships(in: ctx).isEmpty)
        XCTAssertTrue(try PendingCloudQueueMutation.orderings(in: ctx).isEmpty)
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<QueueItem>()), 0)
    }

    func testExpirationSaveFailureRollsBackQueueAndCloudIntent() throws {
        enum Injected: Error { case save }
        let ctx = TestStore.freshContext()
        let p = podcast(ctx, "A")
        p.queueAgeLimitDays = 7
        let e = episode(ctx, "old", podcast: p, status: .inQueue)
        ctx.insert(QueueItem(episode: e, position: 0, addedAt: daysAgo(10)))
        try ctx.save()

        ExpirationService(
            context: ctx,
            saveOperation: { _ in throw Injected.save }
        ).runExpiration(now: now)

        let fresh = ModelContext(ctx.container)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<QueueItem>()), 1)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<RecentlyExpired>()), 0)
        XCTAssertTrue(try PendingCloudQueueMutation.memberships(in: fresh).isEmpty)
        XCTAssertTrue(try PendingCloudQueueMutation.orderings(in: fresh).isEmpty)
        XCTAssertEqual(try XCTUnwrap(fresh.fetch(FetchDescriptor<Episode>()).first).status, .inQueue)
    }

    func testExpirationReusesExistingRelationshipWhenQueuedAndExpiredConflict() throws {
        let ctx = TestStore.freshContext()
        let p = podcast(ctx, "A")
        p.queueAgeLimitDays = 7
        let e = episode(ctx, "conflict", podcast: p, status: .inQueue)
        let existing = RecentlyExpired(episode: e, expiredAt: daysAgo(20))
        ctx.insert(existing)
        ctx.insert(QueueItem(episode: e, position: 0, addedAt: daysAgo(10)))
        try ctx.save()
        let existingID = existing.persistentModelID

        ExpirationService(context: ctx).runExpiration(now: now)

        let rows = try ctx.fetch(FetchDescriptor<RecentlyExpired>())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.persistentModelID, existingID)
        XCTAssertEqual(rows.first?.expiredAt, now)
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<QueueItem>()), 0)
        XCTAssertEqual(e.status, .expired)
    }

    func testDoesNotExpireWithinLimitOrWithoutLimit() {
        let ctx = TestStore.freshContext()
        let limited = podcast(ctx, "A"); limited.queueAgeLimitDays = 7
        let unlimited = podcast(ctx, "B")
        let fresh = episode(ctx, "fresh", podcast: limited, status: .inQueue)
        let noLimit = episode(ctx, "noLimit", podcast: unlimited, status: .inQueue)
        ctx.insert(QueueItem(episode: fresh, position: 0, addedAt: daysAgo(3)))
        ctx.insert(QueueItem(episode: noLimit, position: 1, addedAt: daysAgo(100)))
        try? ctx.save()

        ExpirationService(context: ctx).runExpiration(now: now)
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<QueueItem>()), 2)
    }

    func testPurgesRecentlyExpiredAfterRetention() {
        let ctx = TestStore.freshContext()
        let p = podcast(ctx, "A")
        let e = episode(ctx, "x", podcast: p, status: .expired)
        ctx.insert(RecentlyExpired(episode: e, expiredAt: daysAgo(8)))
        try? ctx.save()

        ExpirationService(context: ctx).runExpiration(now: now)
        XCTAssertTrue(ExpirationService(context: ctx).recentlyExpired().isEmpty)
    }

    func testRestoreReQueuesAndRemovesRecentlyExpired() {
        let ctx = TestStore.freshContext()
        let p = podcast(ctx, "A")
        let e = episode(ctx, "x", podcast: p, status: .expired)
        ctx.insert(RecentlyExpired(episode: e, expiredAt: daysAgo(1)))
        try? ctx.save()

        ExpirationService(context: ctx).restore(e)

        XCTAssertTrue(ExpirationService(context: ctx).recentlyExpired().isEmpty)
        XCTAssertEqual(e.status, .inQueue)
        XCTAssertNotNil(e.queueItem)
    }
}
