import XCTest
import SwiftData
import os
@testable import Earshot

/// Proves the whole-library refresh writes happen on ``FeedRefreshActor``'s own
/// background context (not the caller's main context) while still producing the
/// same inserted/deduped episodes — the threading fix for VoiceOver sluggishness
/// during a large refresh (#382). Drives the `@ModelActor` directly via its
/// container, then asserts by reading the store through a *fresh, independent*
/// `ModelContext`.
@MainActor
final class FeedRefreshActorTests: XCTestCase {

    private func cleanContainer() -> ModelContainer {
        _ = TestStore.freshContext() // wipe the shared in-memory store first
        return TestStore.container
    }

    private let d1 = Date(timeIntervalSince1970: 1_700_000_000)
    private let d2 = Date(timeIntervalSince1970: 1_700_100_000)
    private let d3 = Date(timeIntervalSince1970: 1_700_200_000)

    private func parsedEpisode(_ guid: String, _ date: Date) -> ParsedEpisode {
        ParsedEpisode(
            guid: guid, title: "Ep \(guid)", audioURL: "https://x/\(guid).mp3",
            description: nil, pubDate: date, durationSeconds: nil, artworkURL: nil,
            episodeNumber: nil, seasonNumber: nil, chapterURL: nil, transcriptURL: nil
        )
    }

    private func parsedFeed(_ episodes: [ParsedEpisode]) -> ParsedFeed {
        ParsedFeed(
            title: "Show", artworkURL: nil, description: nil, author: "Host",
            websiteURL: nil, language: nil, category: nil, episodes: episodes
        )
    }

    /// Reads the store through a brand-new context, so the assertion can only
    /// pass if the actor persisted to the store (not to some caller's cached
    /// object graph).
    private func episodes(_ container: ModelContainer) throws -> [Episode] {
        try ModelContext(container).fetch(FetchDescriptor<Episode>())
    }

    /// A new subscription has its backlog pre-dismissed (so refresh of an existing
    /// podcast must add only genuinely-new episodes). Seed one directly with a
    /// mark already set, then refresh on the actor and read from a fresh context.
    func testActorRefreshInsertsNewEpisodesOffTheCallerContext() async throws {
        let container = cleanContainer()
        // Seed a subscribed podcast (mark = d1) with episode "a" via a context we
        // then DISCARD, so the actor can't be reusing our object graph.
        do {
            let seedCtx = ModelContext(container)
            let podcast = Podcast(feedURL: "https://x/feed.xml", title: "Show", lastSeenPubDate: d1)
            let a = Episode(guid: "a", title: "a", audioURL: "https://x/a.mp3", pubDate: d1)
            a.podcast = podcast
            a.inboxDismissed = true
            seedCtx.insert(podcast)
            seedCtx.insert(a)
            try seedCtx.save()
        }

        let actor = FeedRefreshActor(modelContainer: container)
        let fetcher = FakeFeed(parsedFeed([parsedEpisode("a", d1), parsedEpisode("b", d2), parsedEpisode("c", d3)]))
        let outcome = try await actor.refreshOne(
            feedURL: "https://x/feed.xml", feed: fetcher, autoQueueEnabled: false
        )

        XCTAssertEqual(outcome?.added, 2, "b and c are new; a is deduped by guid")
        XCTAssertEqual(outcome?.newestNewEpisodeGUID, "c")
        // The store now holds all three, read through an independent context.
        let stored = try episodes(container)
        XCTAssertEqual(Set(stored.map(\.guid)), ["a", "b", "c"])
    }

    /// Deduplication: refreshing with the same feed twice never double-inserts.
    func testActorRefreshIsIdempotentByGUID() async throws {
        let container = cleanContainer()
        do {
            let seedCtx = ModelContext(container)
            seedCtx.insert(Podcast(feedURL: "https://x/feed.xml", title: "Show", lastSeenPubDate: d1))
            try seedCtx.save()
        }
        let actor = FeedRefreshActor(modelContainer: container)
        let fetcher = FakeFeed(parsedFeed([parsedEpisode("a", d1), parsedEpisode("b", d2)]))

        _ = try await actor.refreshOne(feedURL: "https://x/feed.xml", feed: fetcher, autoQueueEnabled: false)
        let second = try await actor.refreshOne(feedURL: "https://x/feed.xml", feed: fetcher, autoQueueEnabled: false)

        XCTAssertEqual(second?.added, 0, "Second pass finds nothing new")
        XCTAssertEqual(try episodes(container).count, 2, "No duplicate rows")
    }

    /// A freshly-migrated shell (no episodes, no mark) backfills its whole catalog
    /// pre-dismissed and is flagged as a backfill (never notifies).
    func testActorBackfillsMigratedShellPreDismissed() async throws {
        let container = cleanContainer()
        do {
            let seedCtx = ModelContext(container)
            seedCtx.insert(Podcast(feedURL: "https://x/feed.xml", title: "Shell"))
            try seedCtx.save()
        }
        let actor = FeedRefreshActor(modelContainer: container)
        let fetcher = FakeFeed(parsedFeed([parsedEpisode("a", d1), parsedEpisode("b", d2)]))

        let outcome = try await actor.refreshOne(feedURL: "https://x/feed.xml", feed: fetcher, autoQueueEnabled: false)

        XCTAssertTrue(outcome?.wasBackfill == true)
        let stored = try episodes(container)
        XCTAssertEqual(stored.count, 2)
        XCTAssertTrue(stored.allSatisfy { $0.inboxDismissed }, "Backlog pre-dismissed")
    }

    // MARK: subscribe (off the caller's context)

    /// Subscribing inserts the podcast + every episode on the actor's OWN
    /// background context (read back via a fresh independent context), with the
    /// backlog dismissed when the seed count is 0 and the high-water mark seeded to
    /// the newest non-future pub date (#296).
    func testActorSubscribeInsertsPodcastAndBacklogOffTheCallerContext() async throws {
        let container = cleanContainer()
        let actor = FeedRefreshActor(modelContainer: container)
        let fetcher = FakeFeed(parsedFeed([parsedEpisode("a", d1), parsedEpisode("b", d2)]))

        // seed 0 = dismiss the whole backlog (the legacy behavior this asserts).
        let result = try await actor.subscribe(feedURL: "https://x/feed.xml", feed: fetcher, inboxSeedCount: 0)

        XCTAssertFalse(result.alreadySubscribed)
        XCTAssertEqual(result.episodeIDs.count, 2)

        // Read back through an independent context: the actor persisted to the store.
        let freshCtx = ModelContext(container)
        let podcasts = try freshCtx.fetch(FetchDescriptor<Podcast>())
        XCTAssertEqual(podcasts.count, 1)
        let podcast = try XCTUnwrap(podcasts.first)
        XCTAssertEqual(podcast.title, "Show")
        XCTAssertEqual(podcast.author, "Host")
        XCTAssertEqual(podcast.episodes.count, 2)
        XCTAssertTrue(podcast.episodes.allSatisfy { $0.inboxDismissed }, "Seed 0 dismisses the whole backlog")
        XCTAssertEqual(podcast.lastSeenPubDate, d2, "Mark seeded to newest pub date")
        XCTAssertNotNil(podcast.refreshedAt)
    }

    /// Subscribing with a seed count of N keeps the newest N non-future episodes in
    /// the inbox (`status == .newEpisode && !inboxDismissed`) and dismisses the
    /// older backlog — the core fix for the empty-inbox-on-subscribe parity gap.
    func testActorSubscribeSeedsNewestNIntoInbox() async throws {
        let container = cleanContainer()
        let actor = FeedRefreshActor(modelContainer: container)
        // Five episodes a<b<c<d<e by pub date; seed 2 keeps d and e.
        let d4 = d3.addingTimeInterval(100_000)
        let d5 = d4.addingTimeInterval(100_000)
        let fetcher = FakeFeed(parsedFeed([
            parsedEpisode("a", d1), parsedEpisode("b", d2), parsedEpisode("c", d3),
            parsedEpisode("d", d4), parsedEpisode("e", d5),
        ]))

        _ = try await actor.subscribe(feedURL: "https://x/feed.xml", feed: fetcher, inboxSeedCount: 2)

        let stored = try episodes(container)
        let seeded = stored.filter { !$0.inboxDismissed }
        XCTAssertEqual(Set(seeded.map(\.guid)), ["d", "e"], "Newest 2 seeded into inbox")
        XCTAssertTrue(seeded.allSatisfy { $0.status == .newEpisode }, "Seeded episodes are newEpisode")
        let dismissed = stored.filter { $0.inboxDismissed }
        XCTAssertEqual(Set(dismissed.map(\.guid)), ["a", "b", "c"], "Older backlog dismissed")
    }

    /// A seed count of -1 ("All") seeds the entire non-future backlog into the inbox.
    func testActorSubscribeSeedAllSeedsWholeBacklog() async throws {
        let container = cleanContainer()
        let actor = FeedRefreshActor(modelContainer: container)
        let fetcher = FakeFeed(parsedFeed([parsedEpisode("a", d1), parsedEpisode("b", d2), parsedEpisode("c", d3)]))

        _ = try await actor.subscribe(feedURL: "https://x/feed.xml", feed: fetcher, inboxSeedCount: -1)

        let stored = try episodes(container)
        XCTAssertTrue(stored.allSatisfy { !$0.inboxDismissed && $0.status == .newEpisode }, "Whole backlog seeded")
    }

    /// Future-dated episodes are never seeded into the inbox even when the seed
    /// count would otherwise include them (#296). With seed 3 and a feed of one
    /// real + one future episode, only the real one surfaces.
    func testActorSubscribeNeverSeedsFutureDatedEpisode() async throws {
        let container = cleanContainer()
        let actor = FeedRefreshActor(modelContainer: container)
        let future = Date(timeIntervalSinceNow: 60 * 60 * 24 * 30) // 30 days ahead
        let fetcher = FakeFeed(parsedFeed([parsedEpisode("a", d1), parsedEpisode("future", future)]))

        _ = try await actor.subscribe(feedURL: "https://x/feed.xml", feed: fetcher, inboxSeedCount: 3)

        let stored = try episodes(container)
        let seeded = stored.filter { !$0.inboxDismissed }
        XCTAssertEqual(Set(seeded.map(\.guid)), ["a"], "Only the non-future episode is seeded")
        let futureEp = try XCTUnwrap(stored.first { $0.guid == "future" })
        XCTAssertTrue(futureEp.inboxDismissed, "Future-dated episode stays dismissed")
    }

    /// Subscribing to an already-subscribed feed URL is idempotent: no fetch, no
    /// new rows, `alreadySubscribed == true`, and the existing podcast ID returned.
    func testActorSubscribeIsIdempotentByFeedURL() async throws {
        let container = cleanContainer()
        let actor = FeedRefreshActor(modelContainer: container)
        let fetcher = FakeFeed(parsedFeed([parsedEpisode("a", d1)]))

        let first = try await actor.subscribe(feedURL: "https://x/feed.xml", feed: fetcher, inboxSeedCount: 3)
        let second = try await actor.subscribe(feedURL: "https://x/feed.xml", feed: fetcher, inboxSeedCount: 3)

        XCTAssertFalse(first.alreadySubscribed)
        XCTAssertTrue(second.alreadySubscribed)
        XCTAssertEqual(first.podcastID, second.podcastID)
        XCTAssertTrue(second.episodeIDs.isEmpty, "Idempotent return inserts nothing")
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<Podcast>()).count, 1)
        XCTAssertEqual(try episodes(container).count, 1, "No duplicate episode rows")
    }

    /// A future-dated episode must not advance the high-water mark past real
    /// non-future episodes on subscribe (#296).
    func testActorSubscribeFutureDatedEpisodeDoesNotAdvanceMark() async throws {
        let container = cleanContainer()
        let actor = FeedRefreshActor(modelContainer: container)
        let future = Date(timeIntervalSinceNow: 60 * 60 * 24 * 30) // 30 days ahead
        let fetcher = FakeFeed(parsedFeed([parsedEpisode("a", d1), parsedEpisode("future", future)]))

        _ = try await actor.subscribe(feedURL: "https://x/feed.xml", feed: fetcher, inboxSeedCount: 3)

        let podcast = try XCTUnwrap(try ModelContext(container).fetch(FetchDescriptor<Podcast>()).first)
        XCTAssertEqual(podcast.lastSeenPubDate, d1, "Mark is newest NON-future date, not the future one")
    }

    // MARK: republished same-guid episodes (#397)

    /// A republished episode (same guid, newer pubDate) that is unplayed and not
    /// queued is re-surfaced: status flips back to `.newEpisode`, `inboxDismissed`
    /// clears, and the stored `pubDate` advances to the new value.
    func testActorRefreshResurfacesRepublishedUnplayedEpisode() async throws {
        let container = cleanContainer()
        do {
            let seedCtx = ModelContext(container)
            let podcast = Podcast(feedURL: "https://x/feed.xml", title: "Show", lastSeenPubDate: d2)
            let a = Episode(guid: "a", title: "a", audioURL: "https://x/a.mp3", pubDate: d1)
            a.podcast = podcast
            a.status = .newEpisode
            a.inboxDismissed = true // previously read/dismissed
            seedCtx.insert(podcast)
            seedCtx.insert(a)
            try seedCtx.save()
        }

        let actor = FeedRefreshActor(modelContainer: container)
        let fetcher = FakeFeed(parsedFeed([parsedEpisode("a", d3)])) // republished, newer pubDate
        let outcome = try await actor.refreshOne(
            feedURL: "https://x/feed.xml", feed: fetcher, autoQueueEnabled: false
        )

        let stored = try episodes(container)
        let a = try XCTUnwrap(stored.first { $0.guid == "a" })
        XCTAssertEqual(a.pubDate, d3, "pubDate advances to the republished value")
        XCTAssertEqual(a.status, .newEpisode)
        XCTAssertFalse(a.inboxDismissed, "Re-surfaced into the inbox")
        XCTAssertEqual(outcome?.added, 0, "Republish is not counted as a new episode")
        XCTAssertNil(outcome?.newestNewEpisodeGUID, "Republish never triggers the notification path")
    }

    /// A played episode is never re-surfaced by a republish, even with a newer
    /// pubDate — its pubDate and status are left untouched.
    func testActorRefreshDoesNotResurfacePlayedEpisode() async throws {
        let container = cleanContainer()
        do {
            let seedCtx = ModelContext(container)
            let podcast = Podcast(feedURL: "https://x/feed.xml", title: "Show", lastSeenPubDate: d2)
            let a = Episode(guid: "a", title: "a", audioURL: "https://x/a.mp3", pubDate: d1)
            a.podcast = podcast
            a.status = .played
            a.inboxDismissed = true
            seedCtx.insert(podcast)
            seedCtx.insert(a)
            try seedCtx.save()
        }

        let actor = FeedRefreshActor(modelContainer: container)
        let fetcher = FakeFeed(parsedFeed([parsedEpisode("a", d3)]))
        _ = try await actor.refreshOne(feedURL: "https://x/feed.xml", feed: fetcher, autoQueueEnabled: false)

        let stored = try episodes(container)
        let a = try XCTUnwrap(stored.first { $0.guid == "a" })
        XCTAssertEqual(a.pubDate, d1, "Played episode's pubDate is untouched")
        XCTAssertEqual(a.status, .played, "Played status is untouched")
        XCTAssertTrue(a.inboxDismissed, "Not re-surfaced")
    }

    /// A queued episode is never re-surfaced by a republish, even with a newer
    /// pubDate and unplayed status.
    func testActorRefreshDoesNotResurfaceQueuedEpisode() async throws {
        let container = cleanContainer()
        do {
            let seedCtx = ModelContext(container)
            let podcast = Podcast(feedURL: "https://x/feed.xml", title: "Show", lastSeenPubDate: d2)
            let a = Episode(guid: "a", title: "a", audioURL: "https://x/a.mp3", pubDate: d1)
            a.podcast = podcast
            a.status = .inQueue
            a.inboxDismissed = true
            let queueItem = QueueItem(episode: a, position: 0)
            seedCtx.insert(podcast)
            seedCtx.insert(a)
            seedCtx.insert(queueItem)
            try seedCtx.save()
        }

        let actor = FeedRefreshActor(modelContainer: container)
        let fetcher = FakeFeed(parsedFeed([parsedEpisode("a", d3)]))
        _ = try await actor.refreshOne(feedURL: "https://x/feed.xml", feed: fetcher, autoQueueEnabled: false)

        let stored = try episodes(container)
        let a = try XCTUnwrap(stored.first { $0.guid == "a" })
        XCTAssertEqual(a.pubDate, d1, "Queued episode's pubDate is untouched")
        XCTAssertNotNil(a.queueItem, "Still queued")
        XCTAssertTrue(a.inboxDismissed, "Not re-surfaced")
    }

    /// A same-guid item whose pubDate is NOT newer than the stored value (or is
    /// future-dated) leaves the existing episode untouched.
    func testActorRefreshIgnoresNonNewerOrFutureDatedRepublish() async throws {
        let container = cleanContainer()
        do {
            let seedCtx = ModelContext(container)
            let podcast = Podcast(feedURL: "https://x/feed.xml", title: "Show", lastSeenPubDate: d2)
            let a = Episode(guid: "a", title: "a", audioURL: "https://x/a.mp3", pubDate: d2)
            a.podcast = podcast
            a.status = .newEpisode
            a.inboxDismissed = true
            seedCtx.insert(podcast)
            seedCtx.insert(a)
            try seedCtx.save()
        }

        let actor = FeedRefreshActor(modelContainer: container)
        let future = Date(timeIntervalSinceNow: 60 * 60 * 24 * 30) // 30 days ahead
        // Same guid with an OLDER pubDate (d1 < d2) — not newer, so no change.
        let fetcher = FakeFeed(parsedFeed([parsedEpisode("a", d1)]))
        _ = try await actor.refreshOne(feedURL: "https://x/feed.xml", feed: fetcher, autoQueueEnabled: false)
        var stored = try episodes(container)
        var a = try XCTUnwrap(stored.first { $0.guid == "a" })
        XCTAssertEqual(a.pubDate, d2, "Older pubDate does not overwrite the stored value")
        XCTAssertTrue(a.inboxDismissed, "Not re-surfaced")

        // Same guid with a FUTURE pubDate — never re-surfaced (#296 guard).
        let futureFetcher = FakeFeed(parsedFeed([parsedEpisode("a", future)]))
        _ = try await actor.refreshOne(feedURL: "https://x/feed.xml", feed: futureFetcher, autoQueueEnabled: false)
        stored = try episodes(container)
        a = try XCTUnwrap(stored.first { $0.guid == "a" })
        XCTAssertEqual(a.pubDate, d2, "Future-dated republish does not overwrite the stored value")
        XCTAssertTrue(a.inboxDismissed, "Not re-surfaced")
    }

    /// `refreshAll` walks every subscription and reports progress, persisting to
    /// the store readable from a fresh context.
    func testActorRefreshAllProcessesEveryFeedAndPersists() async throws {
        let container = cleanContainer()
        do {
            let seedCtx = ModelContext(container)
            for i in 0..<3 {
                seedCtx.insert(Podcast(feedURL: "https://x/feed\(i).xml", title: "Show \(i)", lastSeenPubDate: d1))
            }
            try seedCtx.save()
        }
        let actor = FeedRefreshActor(modelContainer: container)
        let fetcher = FakeFeed(parsedFeed([parsedEpisode("a", d1), parsedEpisode("b", d2)]))
        let recorder = ProgressBox()

        let results = await actor.refreshAll(
            feed: fetcher,
            autoQueueEnabled: false,
            isCancelled: { false },
            onProgress: { completed, total in
                recorder.calls += 1
                recorder.lastCompleted = completed
                recorder.lastTotal = total
            }
        )

        XCTAssertEqual(results.count, 3, "One result per subscription")
        XCTAssertEqual(recorder.calls, 3)
        XCTAssertEqual(recorder.lastCompleted, 3)
        XCTAssertEqual(recorder.lastTotal, 3)
        // Each of the three feeds gained episode "b"; read via a fresh context.
        XCTAssertEqual(try episodes(container).filter { $0.guid == "b" }.count, 3)
    }

    // MARK: subscribeAll (bulk OPML path)

    /// Bulk subscribe inserts every feed's podcast + backlog on the actor's own
    /// background context, returns one result per feed in input order, and reports
    /// progress with increasing completed counts up to total.
    func testActorSubscribeAllInsertsEveryFeedAndReportsProgress() async throws {
        let container = cleanContainer()
        let actor = FeedRefreshActor(modelContainer: container)
        let fetcher = FakeFeed(parsedFeed([parsedEpisode("a", d1), parsedEpisode("b", d2)]))
        let urls = (0..<12).map { "https://x/feed\($0).xml" } // > saveBatchSize (10) to exercise batching
        let recorder = ProgressBox()

        let results = await actor.subscribeAll(
            feedURLs: urls,
            feed: fetcher,
            inboxSeedCount: 3,
            onProgress: { completed, total, _ in
                recorder.calls += 1
                recorder.lastCompleted = completed
                recorder.lastTotal = total
            }
        )

        XCTAssertEqual(results.count, 12)
        XCTAssertTrue(results.allSatisfy { !$0.alreadySubscribed })
        XCTAssertEqual(recorder.calls, 12)
        XCTAssertEqual(recorder.lastCompleted, 12)
        XCTAssertEqual(recorder.lastTotal, 12)
        // Read back through a fresh context: all 12 podcasts persisted (batched saves).
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<Podcast>()).count, 12)
        XCTAssertEqual(try episodes(container).count, 24)
    }

    /// A feed that throws is logged and skipped — the rest of the batch still
    /// subscribes and the result array omits the failed feed.
    func testActorSubscribeAllSkipsFailingFeedAndContinues() async throws {
        final class FlakyFeed: FeedFetching, @unchecked Sendable {
            let good: ParsedFeed
            init(_ good: ParsedFeed) { self.good = good }
            func fetch(_ urlString: String) async throws -> ParsedFeed {
                if urlString.contains("bad") { throw URLError(.badServerResponse) }
                return good
            }
        }
        let container = cleanContainer()
        let actor = FeedRefreshActor(modelContainer: container)
        let fetcher = FlakyFeed(parsedFeed([parsedEpisode("a", d1)]))

        let results = await actor.subscribeAll(
            feedURLs: ["https://x/good1.xml", "https://x/bad.xml", "https://x/good2.xml"],
            feed: fetcher,
            inboxSeedCount: 3
        )

        XCTAssertEqual(results.count, 2, "Only the two good feeds resolved")
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<Podcast>()).count, 2)
    }

    /// Idempotency: a URL already subscribed returns `alreadySubscribed` and never
    /// double-inserts.
    func testActorSubscribeAllIsIdempotentByFeedURL() async throws {
        let container = cleanContainer()
        let actor = FeedRefreshActor(modelContainer: container)
        let fetcher = FakeFeed(parsedFeed([parsedEpisode("a", d1)]))

        _ = await actor.subscribeAll(feedURLs: ["https://x/feed.xml"], feed: fetcher, inboxSeedCount: 3)
        let second = await actor.subscribeAll(
            feedURLs: ["https://x/feed.xml", "https://x/feed2.xml"], feed: fetcher, inboxSeedCount: 3
        )

        let already = second.filter { $0.alreadySubscribed }
        XCTAssertEqual(already.count, 1, "The re-imported URL is already subscribed")
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<Podcast>()).count, 2)
        XCTAssertEqual(try episodes(container).count, 2, "No duplicate episode rows")
    }

    /// Cancellation before the first feed processes nothing.
    func testActorRefreshAllCancelledImmediatelyDoesNothing() async throws {
        let container = cleanContainer()
        do {
            let seedCtx = ModelContext(container)
            seedCtx.insert(Podcast(feedURL: "https://x/feed.xml", title: "Show", lastSeenPubDate: d1))
            try seedCtx.save()
        }
        let actor = FeedRefreshActor(modelContainer: container)
        let fetcher = FakeFeed(parsedFeed([parsedEpisode("b", d2)]))
        let calls = OSAllocatedUnfairLock(initialState: 0)

        let results = await actor.refreshAll(
            feed: fetcher,
            autoQueueEnabled: false,
            isCancelled: { true },
            onProgress: { _, _ in calls.withLock { $0 += 1 } }
        )

        XCTAssertTrue(results.isEmpty)
        XCTAssertEqual(calls.withLock { $0 }, 0)
    }
}

/// Sendable feed double for the actor tests.
private final class FakeFeed: FeedFetching, @unchecked Sendable {
    let feed: ParsedFeed
    init(_ feed: ParsedFeed) { self.feed = feed }
    func fetch(_ urlString: String) async throws -> ParsedFeed { feed }
}

/// Captures progress callback values across the actor boundary.
private final class ProgressBox: @unchecked Sendable {
    var calls = 0
    var lastCompleted = 0
    var lastTotal = 0
}
