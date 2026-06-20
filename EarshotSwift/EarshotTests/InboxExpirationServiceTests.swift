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

    func testExpiresStaleQueuedEpisode() {
        let ctx = TestStore.freshContext()
        let p = podcast(ctx, "A")
        p.queueAgeLimitDays = 7
        let e = episode(ctx, "old", podcast: p, status: .inQueue)
        let item = QueueItem(episode: e, position: 0, addedAt: daysAgo(10))
        ctx.insert(item)
        try? ctx.save()

        ExpirationService(context: ctx).runExpiration(now: now)

        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<QueueItem>()), 0)
        XCTAssertEqual(ExpirationService(context: ctx).recentlyExpired().count, 1)
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
