import XCTest
import SwiftData
import os
@testable import Earshot

/// Proves the whole-library refresh writes happen on ``FeedRefreshActor``'s own
/// background context (not the caller's main context) while still producing the
/// same inserted/deduped episodes — the threading fix for VoiceOver sluggishness
/// during a large refresh (#382). Mirrors `SubscriptionImporterTests`: drive the
/// `@ModelActor` directly via its container, then assert by reading the store
/// through a *fresh, independent* `ModelContext`.
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
