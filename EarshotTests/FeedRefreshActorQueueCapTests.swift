import XCTest
import SwiftData
@testable import Earshot

/// Integration coverage for the per-podcast queue COUNT cap (#494) end-to-end
/// through ``FeedRefreshActor``, not just the pure ``QueueLogic/idsToEvictForCount``.
///
/// These drive the real auto-queue path the feature hooks into — `refreshOne`
/// (which calls the private `apply` → `enqueueAtEnd` → `enforceQueueCap`) against
/// a real `FeedRefreshActor` over an in-memory `ModelContainer` — and assert the
/// resulting store state through a fresh, independent `ModelContext`, so the test
/// can only pass if the actor actually persisted the eviction. Mirrors the
/// container/context conventions in `FeedRefreshActorTests`.
///
/// `enforceQueueCap` runs only inside the auto-queue branch of `apply`, after new
/// episodes are enrolled, so every test reaches it by refreshing a podcast with
/// `autoQueue == true` and `autoQueueEnabled: true` whose feed gained a new
/// (pub-date-after-mark) episode. Recency is keyed on `QueueItem.addedAt`; the
/// tests rely on the wall-clock gap between separate `await`ed refreshes (an
/// item auto-queued in a later refresh has a strictly later `addedAt`) rather
/// than mutating an actor-owned object from another context.
@MainActor
final class FeedRefreshActorQueueCapTests: XCTestCase {

    private func cleanContainer() -> ModelContainer {
        _ = TestStore.freshContext() // wipe the shared in-memory store first
        return TestStore.container
    }

    private let d1 = Date(timeIntervalSince1970: 1_700_000_000)
    private let d2 = Date(timeIntervalSince1970: 1_700_100_000)
    private let d3 = Date(timeIntervalSince1970: 1_700_200_000)
    private let d4 = Date(timeIntervalSince1970: 1_700_300_000)
    private let d5 = Date(timeIntervalSince1970: 1_700_400_000)

    private func parsedEpisode(_ guid: String, _ date: Date) -> ParsedEpisode {
        ParsedEpisode(
            guid: guid, title: "Ep \(guid)", audioURL: "https://x/\(guid).mp3",
            description: nil, pubDate: date, durationSeconds: nil, artworkURL: nil,
            episodeNumber: nil, seasonNumber: nil, chapterURL: nil, transcriptURL: nil
        )
    }

    private func parsedFeed(_ episodes: [ParsedEpisode], title: String = "Show") -> ParsedFeed {
        ParsedFeed(
            title: title, artworkURL: nil, description: nil, author: "Host",
            websiteURL: nil, language: nil, category: nil, episodes: episodes
        )
    }

    /// Seeds an already-subscribed, auto-queueing podcast (mark = `mark`, no
    /// episodes) directly through a throwaway context, so `apply` takes the normal
    /// refresh/auto-queue path (not the migrated-shell backfill, which needs both
    /// no episodes AND a nil mark) and the actor cannot be reusing our graph.
    @discardableResult
    private func seedAutoQueuePodcast(
        _ container: ModelContainer, feedURL: String, cap: Int?, mark: Date
    ) throws -> PersistentIdentifier {
        let ctx = ModelContext(container)
        let podcast = Podcast(
            feedURL: feedURL, title: "Show", autoQueue: true,
            inboxMaxEpisodes: cap, lastSeenPubDate: mark
        )
        ctx.insert(podcast)
        try ctx.save()
        return podcast.persistentModelID
    }

    /// All queued episode guids of `feedURL`, read through a fresh context.
    private func queuedGUIDs(_ container: ModelContainer, feedURL: String) throws -> Set<String> {
        let items = try ModelContext(container).fetch(FetchDescriptor<QueueItem>())
        return Set(items.compactMap { $0.episode?.podcast?.feedURL == feedURL ? $0.episode?.guid : nil })
    }

    /// The episode with `guid`, read through a fresh context.
    private func episode(_ container: ModelContainer, guid: String) throws -> Episode {
        var d = FetchDescriptor<Episode>(predicate: #Predicate { $0.guid == guid })
        d.fetchLimit = 1
        return try XCTUnwrap(try ModelContext(container).fetch(d).first)
    }

    /// All queue-item positions, read through a fresh context.
    private func positions(_ container: ModelContainer) throws -> [Int] {
        try ModelContext(container).fetch(FetchDescriptor<QueueItem>())
            .filter { $0.episode != nil }
            .map(\.position)
    }

    /// Asserts the live queue positions are a dense `0..<count` with no gaps or
    /// duplicates — the compaction invariant `recompactQueue` must restore.
    private func assertDensePositions(_ container: ModelContainer, file: StaticString = #filePath, line: UInt = #line) throws {
        let pos = try positions(container).sorted()
        XCTAssertEqual(pos, Array(0..<pos.count), "Positions must be a dense 0..<N with no gaps or duplicates", file: file, line: line)
    }

    // MARK: Core: oldest evicted, newest kept, evicted episode survives

    /// Acceptance criterion: a podcast capped at 1 with auto-queue on, fed new
    /// episodes over two refreshes, ends with ONLY the cap (1) queued — the
    /// newest-added kept, the oldest-added evicted, positions recompacted, and the
    /// evicted episode still present in the library (status `.newEpisode`, its
    /// `QueueItem` removed, not deleted).
    func testAutoQueueRefreshTrimsToCapEvictingOldestKeepingNewest() async throws {
        let container = cleanContainer()
        try seedAutoQueuePodcast(container, feedURL: "https://x/feed.xml", cap: 1, mark: d1)
        let actor = FeedRefreshActor(modelContainer: container)

        // Refresh 1 auto-queues b (new vs mark d1). Queue = [b], at cap, no evict.
        _ = try await actor.refreshOne(
            feedURL: "https://x/feed.xml",
            feed: FakeFeed(parsedFeed([parsedEpisode("a", d1), parsedEpisode("b", d2)])),
            autoQueueEnabled: true
        )
        XCTAssertEqual(try queuedGUIDs(container, feedURL: "https://x/feed.xml"), ["b"])

        // Refresh 2 auto-queues c (newer addedAt than b). Cap 1 → keep c, evict b.
        _ = try await actor.refreshOne(
            feedURL: "https://x/feed.xml",
            feed: FakeFeed(parsedFeed([parsedEpisode("a", d1), parsedEpisode("b", d2), parsedEpisode("c", d3)])),
            autoQueueEnabled: true
        )

        XCTAssertEqual(
            try queuedGUIDs(container, feedURL: "https://x/feed.xml"), ["c"],
            "Cap 1 keeps the newest-added (c) and evicts the oldest-added (b)"
        )
        // The evicted episode survives the eviction: still in the library, status
        // reverted to .newEpisode, its QueueItem removed (not the episode).
        let b = try episode(container, guid: "b")
        XCTAssertEqual(b.status, .newEpisode, "Evicted episode reverts to .newEpisode")
        XCTAssertNil(b.queueItem, "Evicted episode's QueueItem is removed")
        // The kept episode is still enqueued.
        let c = try episode(container, guid: "c")
        XCTAssertEqual(c.status, .inQueue)
        XCTAssertNotNil(c.queueItem)
        // Exactly one queue item remains and positions are dense 0..<1.
        XCTAssertEqual(try positions(container).count, 1)
        try assertDensePositions(container)
    }

    // MARK: Now-playing protection

    /// Acceptance criterion: the cap never dequeues the currently-playing episode.
    /// With `b` (the item that would otherwise be evicted at cap 1) set as
    /// `SettingsKey.lastPlayingEpisodeID`, refreshing in `c` leaves `b` queued and
    /// evicts the newer non-playing `c` instead — playback is never interrupted by
    /// the cap.
    func testAutoQueueRefreshNeverEvictsTheCurrentlyPlayingEpisode() async throws {
        let container = cleanContainer()
        try seedAutoQueuePodcast(container, feedURL: "https://x/feed.xml", cap: 1, mark: d1)
        let actor = FeedRefreshActor(modelContainer: container)

        _ = try await actor.refreshOne(
            feedURL: "https://x/feed.xml",
            feed: FakeFeed(parsedFeed([parsedEpisode("a", d1), parsedEpisode("b", d2)])),
            autoQueueEnabled: true
        )

        // b (the oldest-added, the one cap-1 would normally evict) is now playing.
        let store = AppSettingsStore(context: ModelContext(container))
        store.setRawValue("b", for: SettingsKey.lastPlayingEpisodeID)

        _ = try await actor.refreshOne(
            feedURL: "https://x/feed.xml",
            feed: FakeFeed(parsedFeed([parsedEpisode("a", d1), parsedEpisode("b", d2), parsedEpisode("c", d3)])),
            autoQueueEnabled: true
        )

        // b (playing) is protected and stays queued; c is evicted instead so the
        // cap is honored without dropping the episode the user is listening to.
        XCTAssertEqual(
            try queuedGUIDs(container, feedURL: "https://x/feed.xml"), ["b"],
            "The currently-playing episode is never the one evicted"
        )
        let bEp = try episode(container, guid: "b")
        XCTAssertEqual(bEp.status, .inQueue)
        XCTAssertNotNil(bEp.queueItem, "Playing episode keeps its QueueItem")
        let cEp = try episode(container, guid: "c")
        XCTAssertEqual(cEp.status, .newEpisode, "The newer non-playing item is evicted to honor the cap")
        XCTAssertNil(cEp.queueItem)
        try assertDensePositions(container)
    }

    /// Acceptance criterion (the "left over the cap" branch): when protecting the
    /// playing item leaves nothing else to evict, the queue is left OVER the cap
    /// rather than dequeue the playing episode. Cap 0 with the podcast's single
    /// queued item being the now-playing one evicts nothing.
    func testAutoQueueRefreshLeavesQueueOverCapWhenOnlyOverflowIsNowPlaying() async throws {
        let container = cleanContainer()
        // Cap 0 = keep nothing; but the lone item is playing, so it is protected.
        try seedAutoQueuePodcast(container, feedURL: "https://x/feed.xml", cap: 0, mark: d1)
        let actor = FeedRefreshActor(modelContainer: container)

        // Pre-mark b as the playing episode before it is auto-queued, so the very
        // refresh that enrolls it also runs the cap with b protected.
        AppSettingsStore(context: ModelContext(container))
            .setRawValue("b", for: SettingsKey.lastPlayingEpisodeID)

        _ = try await actor.refreshOne(
            feedURL: "https://x/feed.xml",
            feed: FakeFeed(parsedFeed([parsedEpisode("a", d1), parsedEpisode("b", d2)])),
            autoQueueEnabled: true
        )

        // The only over-cap item is the playing one → evict nothing, stay over cap.
        XCTAssertEqual(
            try queuedGUIDs(container, feedURL: "https://x/feed.xml"), ["b"],
            "Queue is left over the cap rather than dropping the playing episode"
        )
        let bEp = try episode(container, guid: "b")
        XCTAssertEqual(bEp.status, .inQueue)
        XCTAssertNotNil(bEp.queueItem)
        try assertDensePositions(container)
    }

    // MARK: Unlimited (nil cap) is a no-op

    /// Acceptance criterion: `inboxMaxEpisodes == nil` (unlimited) never evicts,
    /// even when one refresh auto-queues many episodes.
    func testAutoQueueRefreshNilCapNeverEvicts() async throws {
        let container = cleanContainer()
        try seedAutoQueuePodcast(container, feedURL: "https://x/feed.xml", cap: nil, mark: d1)
        let actor = FeedRefreshActor(modelContainer: container)

        // Four new episodes (b,c,e,f) all auto-queue; nil cap → no enforcement.
        _ = try await actor.refreshOne(
            feedURL: "https://x/feed.xml",
            feed: FakeFeed(parsedFeed([
                parsedEpisode("a", d1), parsedEpisode("b", d2), parsedEpisode("c", d3),
                parsedEpisode("e", d4), parsedEpisode("f", d5),
            ])),
            autoQueueEnabled: true
        )

        XCTAssertEqual(
            try queuedGUIDs(container, feedURL: "https://x/feed.xml"), ["b", "c", "e", "f"],
            "Unlimited cap keeps every auto-queued episode"
        )
        try assertDensePositions(container)
    }

    // MARK: Per-podcast independence

    /// Acceptance criterion: enforcement is per-podcast. Refreshing (and trimming)
    /// one capped podcast never evicts another podcast's queued items, even when
    /// the other podcast is itself over its own cap.
    func testAutoQueueRefreshEnforcesCapPerPodcastOnly() async throws {
        let container = cleanContainer()
        try seedAutoQueuePodcast(container, feedURL: "https://x/p1.xml", cap: 1, mark: d1)
        let p2ID = try seedAutoQueuePodcast(container, feedURL: "https://x/p2.xml", cap: 1, mark: d1)

        // Manually queue TWO of P2's episodes (no refresh → P2's cap never runs),
        // leaving P2 over its own cap of 1 and untouched by P1's enforcement.
        do {
            let ctx = ModelContext(container)
            let p2 = try XCTUnwrap(ctx.model(for: p2ID) as? Podcast)
            for (i, guid) in ["y2", "z2"].enumerated() {
                let ep = Episode(guid: guid, title: guid, audioURL: "https://x/\(guid).mp3",
                                 pubDate: i == 0 ? d2 : d3, status: .inQueue, inboxDismissed: true)
                ep.podcast = p2
                ctx.insert(ep)
                ctx.insert(QueueItem(episode: ep, position: 100 + i))
            }
            try ctx.save()
        }

        let actor = FeedRefreshActor(modelContainer: container)
        // Two P1 refreshes: b1 then c1. Cap 1 → P1 trims to [c1], evicting b1.
        _ = try await actor.refreshOne(
            feedURL: "https://x/p1.xml",
            feed: FakeFeed(parsedFeed([parsedEpisode("a1", d1), parsedEpisode("b1", d2)])),
            autoQueueEnabled: true
        )
        _ = try await actor.refreshOne(
            feedURL: "https://x/p1.xml",
            feed: FakeFeed(parsedFeed([parsedEpisode("a1", d1), parsedEpisode("b1", d2), parsedEpisode("c1", d3)])),
            autoQueueEnabled: true
        )

        XCTAssertEqual(
            try queuedGUIDs(container, feedURL: "https://x/p1.xml"), ["c1"],
            "P1 trims to its own cap (newest kept, oldest evicted)"
        )
        XCTAssertEqual(
            try queuedGUIDs(container, feedURL: "https://x/p2.xml"), ["y2", "z2"],
            "P2's queued items are untouched by P1's enforcement, even over P2's cap"
        )
        // b1 evicted; total live queue is c1 + y2 + z2 with dense positions.
        XCTAssertNil(try episode(container, guid: "b1").queueItem)
        XCTAssertEqual(try positions(container).count, 3)
        try assertDensePositions(container)
    }

    // MARK: addedAt recency keeps a manual "Play next" of an older episode

    /// Acceptance criterion: recency is keyed on `QueueItem.addedAt`, not publish
    /// date. A manually "Play next"-ed episode with an OLD pub date but a recent
    /// `addedAt` is kept over an auto-queued episode with a NEWER pub date but an
    /// older `addedAt`. Cap 2: keep the two most-recently-added (manual z + newest
    /// auto c), evict the older auto-queued b despite its newer pub date.
    func testAutoQueueRefreshKeepsManuallyAddedOlderEpisodeByAddedAtRecency() async throws {
        let container = cleanContainer()
        let pID = try seedAutoQueuePodcast(container, feedURL: "https://x/feed.xml", cap: 2, mark: d1)
        let actor = FeedRefreshActor(modelContainer: container)

        // Refresh 1: auto-queue b (pub d2). It has the OLDEST addedAt.
        _ = try await actor.refreshOne(
            feedURL: "https://x/feed.xml",
            feed: FakeFeed(parsedFeed([parsedEpisode("a", d1), parsedEpisode("b", d2)])),
            autoQueueEnabled: true
        )

        // Manually "Play next" z: an OLD pub date (d1) but added now — newer
        // addedAt than b, older than the c that the next refresh will add.
        do {
            let ctx = ModelContext(container)
            let p = try XCTUnwrap(ctx.model(for: pID) as? Podcast)
            let z = Episode(guid: "z", title: "z", audioURL: "https://x/z.mp3",
                            pubDate: d1, status: .inQueue, inboxDismissed: true)
            z.podcast = p
            ctx.insert(z)
            ctx.insert(QueueItem(episode: z, position: 50, addedAt: Date.now))
            try ctx.save()
        }

        // Refresh 2: auto-queue c (pub d3) — the newest addedAt. Now b, z, c are
        // queued (count 3 > cap 2). enforceQueueCap keeps the two newest-added
        // (c, z) and evicts the oldest-added (b), regardless of pub date.
        _ = try await actor.refreshOne(
            feedURL: "https://x/feed.xml",
            feed: FakeFeed(parsedFeed([parsedEpisode("a", d1), parsedEpisode("b", d2), parsedEpisode("c", d3)])),
            autoQueueEnabled: true
        )

        XCTAssertEqual(
            try queuedGUIDs(container, feedURL: "https://x/feed.xml"), ["z", "c"],
            "Manual older-pub-date z (recent addedAt) is kept; older-added b is evicted despite its newer pub date"
        )
        XCTAssertNil(try episode(container, guid: "b").queueItem, "Oldest-added episode evicted")
        XCTAssertEqual(try episode(container, guid: "b").status, .newEpisode)
        try assertDensePositions(container)
    }
}

/// Sendable feed double for the actor tests (returns the same parsed feed every
/// fetch; the actor dedups by guid so a growing feed is modeled by passing a
/// larger feed on a later refresh).
private final class FakeFeed: FeedFetching, @unchecked Sendable {
    let feed: ParsedFeed
    init(_ feed: ParsedFeed) { self.feed = feed }
    func fetch(_ urlString: String) async throws -> ParsedFeed { feed }
}
