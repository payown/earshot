import XCTest
import SwiftData
import UserNotifications
import os
@testable import Earshot

/// `@unchecked Sendable`: the fetcher is handed to `FeedRefreshActor` (a
/// background `@ModelActor`). Tests only mutate `feed` while no refresh is in
/// flight and read results after `await` completes, so there's no concurrent
/// access in practice.
private final class FakeFeedFetcher: FeedFetching, @unchecked Sendable {
    var feed: ParsedFeed
    init(_ feed: ParsedFeed) { self.feed = feed }
    func fetch(_ urlString: String) async throws -> ParsedFeed { feed }
}

/// Returns a distinct, independently-mutable feed per URL (keyed by the exact
/// `feedURL` string), unlike ``FakeFeedFetcher`` which returns the same feed for
/// every URL. Needed to construct multi-podcast `refreshAll()` scenarios where
/// only some podcasts discover a genuinely new episode in a given pass (#639).
/// Locked because `FeedRefreshActor` reads it off the main actor.
private final class PerURLFeedFetcher: FeedFetching, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [String: ParsedFeed]())
    func setFeed(_ feed: ParsedFeed, for url: String) {
        lock.withLock { $0[url] = feed }
    }
    func fetch(_ urlString: String) async throws -> ParsedFeed {
        guard let feed = lock.withLock({ $0[urlString] }) else {
            throw NSError(domain: "PerURLFeedFetcher", code: 1, userInfo: [NSLocalizedDescriptionKey: "No feed registered for \(urlString)"])
        }
        return feed
    }
}

/// Records which episodes were passed to ``download(_:)`` without touching
/// the network or filesystem.
private final class FakeDownloader: EpisodeDownloading {
    private(set) var downloaded: [Episode] = []
    private(set) var queuedDownloadSweeps = 0
    func download(_ episode: Episode) async { downloaded.append(episode) }
    func downloadQueuedIfEnabled() async { queuedDownloadSweeps += 1 }
    /// Clears recorded calls so a test can isolate the auto-download trigger it's
    /// asserting (e.g. refresh) from an earlier one (e.g. the initial subscribe).
    func reset() {
        downloaded.removeAll()
        queuedDownloadSweeps = 0
    }
}

/// Returns the same feed for every URL but counts how many times ``fetch(_:)``
/// is called, so `refreshAll`'s per-iteration cancellation guard (#381) can be
/// asserted: a cancelled run must stop issuing fetches early.
private final class CountingFeedFetcher: FeedFetching, @unchecked Sendable {
    var feed: ParsedFeed
    // Serialized so the actor's off-main increments and the test's main-actor
    // reads (taken only after `await` completes) don't race. OSAllocatedUnfairLock
    // is async-safe (NSLock is not, under the Swift 6 checker).
    private let count = OSAllocatedUnfairLock(initialState: 0)
    var fetchCount: Int { count.withLock { $0 } }
    init(_ feed: ParsedFeed) { self.feed = feed }
    func fetch(_ urlString: String) async throws -> ParsedFeed {
        count.withLock { $0 += 1 }
        return feed
    }
}

/// Holds the first fetch until the test releases it. Used with
/// ``ConcurrentTaskBarrier`` so both subscribe calls have started before either
/// can commit its natural-key insert.
private actor ConcurrentSubscribeFeedFetcher: FeedFetching {
    private let feed: ParsedFeed
    private var calls = 0
    private var fetchStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    init(_ feed: ParsedFeed) { self.feed = feed }

    func fetch(_ urlString: String) async throws -> ParsedFeed {
        calls += 1
        if calls == 1 {
            let waiters = fetchStartedWaiters
            fetchStartedWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            await withCheckedContinuation { continuation in
                releaseWaiter = continuation
            }
        }
        return feed
    }

    func waitUntilFirstFetchStarts() async {
        guard calls == 0 else { return }
        await withCheckedContinuation { continuation in
            fetchStartedWaiters.append(continuation)
        }
    }

    func releaseFirstFetch() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }

    func fetchCount() -> Int { calls }
}

private actor ConcurrentTaskBarrier {
    private let target: Int
    private var arrivals = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(target: Int) { self.target = target }

    func arriveAndWait() async {
        arrivals += 1
        if arrivals == target {
            let queued = waiters
            waiters.removeAll()
            for waiter in queued { waiter.resume() }
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

@MainActor
final class SubscriptionRepositoryTests: XCTestCase {
    func testRefreshReportAnnouncementsDistinguishFullPartialAndFailure() {
        func report(
            succeeded: Int, total: Int, failed: Int, cancelled: Bool = false
        ) -> SubscriptionRefreshReport {
            SubscriptionRefreshReport(
                notifications: [], attempted: succeeded + failed, total: total,
                succeeded: succeeded, failed: failed, cancelled: cancelled,
                intendedInsertions: 0, durableInsertions: 0
            )
        }

        XCTAssertEqual(
            report(succeeded: 3, total: 3, failed: 0).announcement,
            "Library refreshed"
        )
        XCTAssertEqual(
            report(succeeded: 2, total: 3, failed: 1).announcement,
            "Library partially refreshed, 2 of 3 feeds"
        )
        XCTAssertEqual(
            report(succeeded: 0, total: 3, failed: 3).announcement,
            "Library refresh failed"
        )
        XCTAssertEqual(
            report(succeeded: 0, total: 3, failed: 0, cancelled: true).announcement,
            "Library refresh failed"
        )
    }

    private let d1 = Date(timeIntervalSince1970: 1_700_000_000)
    private let d2 = Date(timeIntervalSince1970: 1_700_100_000)
    private let d3 = Date(timeIntervalSince1970: 1_700_200_000)

    private func episode(_ guid: String, _ date: Date) -> ParsedEpisode {
        ParsedEpisode(
            guid: guid, title: "Ep \(guid)", audioURL: "https://x/\(guid).mp3",
            description: nil, pubDate: date, durationSeconds: nil, artworkURL: nil,
            episodeNumber: nil, seasonNumber: nil, chapterURL: nil, transcriptURL: nil
        )
    }

    private func feed(_ episodes: [ParsedEpisode]) -> ParsedFeed {
        ParsedFeed(
            title: "Show", artworkURL: nil, description: nil, author: "Host",
            websiteURL: nil, language: nil, category: nil, episodes: episodes
        )
    }

    /// Subscribing seeds the newest N episodes (N = global `inboxDefaultCount`,
    /// default 3) into the inbox rather than dismissing the whole backlog, so a
    /// fresh subscribe is not an empty inbox (Flutter parity). With 2 episodes and
    /// the default seed of 3, both surface.
    func testSubscribeCreatesPodcastAndSeedsInbox() async throws {
        let ctx = TestStore.freshContext()
        let fetcher = FakeFeedFetcher(feed([episode("a", d1), episode("b", d2)]))
        let repo = SubscriptionRepository(context: ctx, feed: fetcher)

        let podcast = try await repo.subscribe(feedURL: "https://x/feed.xml")

        XCTAssertEqual(podcast.episodes?.count, 2)
        // Both episodes are within the default seed (3), so both are in the inbox.
        XCTAssertTrue((podcast.episodes ?? []).allSatisfy { !$0.inboxDismissed && $0.status == .newEpisode })
        XCTAssertEqual(InboxRepository(context: ctx).inboxEpisodes().count, 2)
        XCTAssertEqual(podcast.lastSeenPubDate, d2)
        XCTAssertEqual(podcast.author, "Host")
    }

    /// The returned `Podcast` must be a valid MAIN-context object — re-fetched by
    /// persistentModelID after the background actor saved — so callers like
    /// `OPMLImportService` can attach relationships (folder membership) to it. A
    /// background-context object would either fault wrong or fail a relationship
    /// insert on the main context.
    func testSubscribeReturnsMainContextPodcastUsableForRelationships() async throws {
        let ctx = TestStore.freshContext()
        let fetcher = FakeFeedFetcher(feed([episode("a", d1)]))
        let repo = SubscriptionRepository(context: ctx, feed: fetcher)

        let podcast = try await repo.subscribe(feedURL: "https://x/feed.xml")

        // The returned object resolves to the SAME row a fresh main-context fetch finds.
        let fetched = try XCTUnwrap(try ctx.fetch(FetchDescriptor<Podcast>()).first)
        XCTAssertEqual(podcast.persistentModelID, fetched.persistentModelID)

        // It is a live main-context object: attach a folder membership to it (the
        // OPML import path) and save without error.
        let folder = PodcastFolder(name: "News")
        ctx.insert(folder)
        ctx.insert(FolderMembership(folder: folder, podcast: podcast))
        XCTAssertNoThrow(try ctx.save())
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<FolderMembership>()).count, 1)
    }

    func testSubscribeTwiceReturnsExistingWithoutDuplicates() async throws {
        let ctx = TestStore.freshContext()
        let fetcher = FakeFeedFetcher(feed([episode("a", d1)]))
        let repo = SubscriptionRepository(context: ctx, feed: fetcher)

        let first = try await repo.subscribe(feedURL: "https://x/feed.xml")
        let second = try await repo.subscribe(feedURL: "https://x/feed.xml")

        XCTAssertEqual(first.persistentModelID, second.persistentModelID)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Podcast>()).count, 1)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Episode>()).count, 1)
    }

    func testSubscribeCanonicalizesFeedIdentityAcrossEntryPointVariants() async throws {
        let ctx = TestStore.freshContext()
        let fetcher = CountingFeedFetcher(feed([episode("a", d1)]))
        let repo = SubscriptionRepository(context: ctx, feed: fetcher)

        let first = try await repo.subscribe(feedURL: " HTTPS://Example.COM:443/feed.xml#one ")
        let second = try await repo.subscribe(feedURL: "https://example.com/feed.xml")

        XCTAssertEqual(first.persistentModelID, second.persistentModelID)
        XCTAssertEqual(first.feedURL, "https://example.com/feed.xml")
        XCTAssertEqual(fetcher.fetchCount, 1)
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<Podcast>()), 1)
    }

    func testConcurrentSubscribeConvergesToOneNaturalKey() async throws {
        let ctx = TestStore.freshContext()
        let fetcher = ConcurrentSubscribeFeedFetcher(feed([episode("a", d1)]))
        let repo = SubscriptionRepository(context: ctx, feed: fetcher)
        let start = ConcurrentTaskBarrier(target: 2)

        async let first: PersistentIdentifier = { @MainActor in
            await start.arriveAndWait()
            return try await repo.subscribe(feedURL: "HTTPS://Example.COM:443/feed.xml#one")
                .persistentModelID
        }()
        async let second: PersistentIdentifier = { @MainActor in
            await start.arriveAndWait()
            return try await repo.subscribe(feedURL: "https://example.com/feed.xml")
                .persistentModelID
        }()
        await fetcher.waitUntilFirstFetchStarts()
        await fetcher.releaseFirstFetch()
        let resolved = try await [first, second]
        let fetchCount = await fetcher.fetchCount()

        XCTAssertEqual(fetchCount, 1, "The second writer must recheck after the first commits")
        XCTAssertEqual(Set(resolved).count, 1)
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<Podcast>()), 1)
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<Episode>()), 1)
    }

    func testRefreshAddsOnlyNewEpisodesAndSurfacesThemInInbox() async throws {
        let ctx = TestStore.freshContext()
        let fetcher = FakeFeedFetcher(feed([episode("a", d1), episode("b", d2)]))
        let repo = SubscriptionRepository(context: ctx, feed: fetcher)
        let podcast = try await repo.subscribe(feedURL: "https://x/feed.xml")

        // Feed gains a newer episode "c" at d3.
        fetcher.feed = feed([episode("a", d1), episode("b", d2), episode("c", d3)])
        try await repo.refresh(podcast)

        XCTAssertEqual(podcast.episodes?.count, 3)
        let c = try XCTUnwrap(podcast.episodes?.first { $0.guid == "c" })
        XCTAssertFalse(c.inboxDismissed) // newer than the mark -> inbox
        XCTAssertEqual(podcast.lastSeenPubDate, d3)
    }

    func testRefreshIsIdempotentWhenNoNewEpisodes() async throws {
        let ctx = TestStore.freshContext()
        let fetcher = FakeFeedFetcher(feed([episode("a", d1)]))
        let repo = SubscriptionRepository(context: ctx, feed: fetcher)
        let podcast = try await repo.subscribe(feedURL: "https://x/feed.xml")

        try await repo.refresh(podcast)
        XCTAssertEqual(podcast.episodes?.count, 1)
    }

    func testFirstRefreshBackfillsMigratedShellPreDismissed() async throws {
        let ctx = TestStore.freshContext()
        // A migrated shell: subscribed, but no episodes and no high-water mark.
        let shell = Podcast(feedURL: "https://x/feed.xml", title: "Shell")
        ctx.insert(shell)
        try ctx.save()
        let fetcher = FakeFeedFetcher(feed([episode("a", d1), episode("b", d2)]))
        let repo = SubscriptionRepository(context: ctx, feed: fetcher)

        try await repo.refresh(shell)

        XCTAssertEqual(shell.episodes?.count, 2)
        XCTAssertTrue((shell.episodes ?? []).allSatisfy { $0.inboxDismissed }) // backlog pre-dismissed
        XCTAssertEqual(shell.lastSeenPubDate, d2)
        XCTAssertEqual(InboxRepository(context: ctx).inboxEpisodes().count, 0) // inbox starts empty
    }

    func testFutureDatedEpisodeDoesNotAdvanceMarkOnSubscribe() async throws {
        let ctx = TestStore.freshContext()
        let future = Date(timeIntervalSinceNow: 60 * 60 * 24 * 30) // 30 days ahead
        let fetcher = FakeFeedFetcher(feed([episode("a", d1), episode("future", future)]))
        let repo = SubscriptionRepository(context: ctx, feed: fetcher)

        let podcast = try await repo.subscribe(feedURL: "https://x/feed.xml")

        // Mark is the newest NON-future date, not the future one (#296).
        XCTAssertEqual(podcast.lastSeenPubDate, d1)
    }

    func testFutureDatedEpisodeDoesNotAdvanceMarkOnRefresh() async throws {
        let ctx = TestStore.freshContext()
        let fetcher = FakeFeedFetcher(feed([episode("a", d1)]))
        let repo = SubscriptionRepository(context: ctx, feed: fetcher)
        let podcast = try await repo.subscribe(feedURL: "https://x/feed.xml") // mark = d1

        let future = Date(timeIntervalSinceNow: 60 * 60 * 24 * 30)
        fetcher.feed = feed([episode("a", d1), episode("future", future)])
        try await repo.refresh(podcast)

        // The future episode must not poison the mark past real dates (#296).
        XCTAssertEqual(podcast.lastSeenPubDate, d1)
    }

    // MARK: Auto-download on subscribe

    func testSubscribeAutoDownloadsNMostRecentEpisodes() async throws {
        let ctx = TestStore.freshContext()
        // Set autoDownloadCount = 3 in settings.
        AppSettingsStore(context: ctx).setInt(3, for: SettingsKey.autoDownloadCount)
        let fetcher = FakeFeedFetcher(feed([episode("a", d1), episode("b", d2), episode("c", d3)]))
        let fakeDownloader = FakeDownloader()
        let repo = SubscriptionRepository(context: ctx, feed: fetcher, downloader: fakeDownloader)

        _ = try await repo.subscribe(feedURL: "https://x/feed.xml")

        // All 3 episodes should be downloaded; the most-recent-first sort means
        // "c" (d3), "b" (d2), "a" (d1) are the top 3 of 3.
        XCTAssertEqual(fakeDownloader.downloaded.count, 3)
        let downloadedGUIDs = Set(fakeDownloader.downloaded.map(\.guid))
        XCTAssertEqual(downloadedGUIDs, ["a", "b", "c"])
    }

    func testSubscribeAutoDownloadsOnlyNMostRecentWhenFeedHasMore() async throws {
        let ctx = TestStore.freshContext()
        AppSettingsStore(context: ctx).setInt(2, for: SettingsKey.autoDownloadCount)
        let d0 = Date(timeIntervalSince1970: 1_699_900_000) // older than d1
        let fetcher = FakeFeedFetcher(
            feed([episode("old", d0), episode("a", d1), episode("b", d2), episode("c", d3)])
        )
        let fakeDownloader = FakeDownloader()
        let repo = SubscriptionRepository(context: ctx, feed: fetcher, downloader: fakeDownloader)

        _ = try await repo.subscribe(feedURL: "https://x/feed.xml")

        // Only the 2 most recent (c, b) should be downloaded.
        XCTAssertEqual(fakeDownloader.downloaded.count, 2)
        let downloadedGUIDs = Set(fakeDownloader.downloaded.map(\.guid))
        XCTAssertTrue(downloadedGUIDs.contains("c"))
        XCTAssertTrue(downloadedGUIDs.contains("b"))
        XCTAssertFalse(downloadedGUIDs.contains("old"))
    }

    func testSubscribeWithAutoDownloadCountZeroDoesNotDownload() async throws {
        let ctx = TestStore.freshContext()
        AppSettingsStore(context: ctx).setInt(0, for: SettingsKey.autoDownloadCount)
        let fetcher = FakeFeedFetcher(feed([episode("a", d1), episode("b", d2)]))
        let fakeDownloader = FakeDownloader()
        let repo = SubscriptionRepository(context: ctx, feed: fetcher, downloader: fakeDownloader)

        _ = try await repo.subscribe(feedURL: "https://x/feed.xml")

        XCTAssertEqual(fakeDownloader.downloaded.count, 0)
    }

    func testSubscribeWithNoDownloaderDoesNotDownload() async throws {
        let ctx = TestStore.freshContext()
        AppSettingsStore(context: ctx).setInt(3, for: SettingsKey.autoDownloadCount)
        let fetcher = FakeFeedFetcher(feed([episode("a", d1), episode("b", d2)]))
        // downloader omitted -- nil by default
        let repo = SubscriptionRepository(context: ctx, feed: fetcher)

        // Should complete without error; no downloads fired.
        let podcast = try await repo.subscribe(feedURL: "https://x/feed.xml")
        XCTAssertEqual(podcast.episodes?.count, 2)
    }

    // MARK: Auto-download on refresh (#639)

    /// Bug 1 (#639): an ORDINARY refresh of an already-subscribed podcast (pull-to-
    /// refresh, cold-launch throttled refresh, foreground-resume, BGTaskScheduler
    /// background refresh) must trigger auto-download for genuinely new episodes,
    /// not just the one-time first-subscribe path. Before the fix, `refresh(_:)`
    /// never called any download trigger at all.
    func testRefreshAutoDownloadsNewEpisodes() async throws {
        let ctx = TestStore.freshContext()
        AppSettingsStore(context: ctx).setInt(3, for: SettingsKey.autoDownloadCount)
        let fetcher = FakeFeedFetcher(feed([episode("a", d1)]))
        let fakeDownloader = FakeDownloader()
        let repo = SubscriptionRepository(context: ctx, feed: fetcher, downloader: fakeDownloader)
        let podcast = try await repo.subscribe(feedURL: "https://x/feed.xml")
        // Subscribe itself already auto-downloads "a" -- clear it so the assertion
        // below isolates the refresh-path trigger, which is what #639 is about.
        fakeDownloader.reset()

        // A genuinely new episode "b" appears on the next refresh.
        fetcher.feed = feed([episode("a", d1), episode("b", d2)])
        _ = try await repo.refresh(podcast)

        XCTAssertEqual(
            fakeDownloader.downloaded.map(\.guid), ["b"],
            "refresh(_:) must trigger auto-download for genuinely new episodes, not just subscribe(_:)"
        )
    }

    /// Auto-queue and auto-download are orthogonal (#639): a new episode routed
    /// into the queue instead of the inbox is still eligible for auto-download.
    func testRefreshAutoDownloadsNewEpisodeEvenWhenAutoQueued() async throws {
        let ctx = TestStore.freshContext()
        AppSettingsStore(context: ctx).setInt(3, for: SettingsKey.autoDownloadCount)
        let fetcher = FakeFeedFetcher(feed([episode("a", d1)]))
        let fakeDownloader = FakeDownloader()
        let queueRepo = QueueRepository(context: ctx)
        let repo = SubscriptionRepository(context: ctx, feed: fetcher, downloader: fakeDownloader, queue: queueRepo)
        let podcast = try await repo.subscribe(feedURL: "https://x/feed.xml")
        podcast.autoQueue = true
        try ctx.save()
        fakeDownloader.reset()

        let queueChange = expectation(description: "auto-queue publishes queue change")
        queueChange.assertForOverFulfill = true
        let token = NotificationCenter.default.addObserver(
            forName: .earshotQueueDidChange,
            object: nil,
            queue: nil
        ) { _ in
            queueChange.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        fetcher.feed = feed([episode("a", d1), episode("b", d2)])
        _ = try await repo.refresh(podcast)

        let b = try XCTUnwrap(podcast.episodes?.first { $0.guid == "b" })
        XCTAssertEqual(b.status, .inQueue, "b is auto-queued")
        XCTAssertEqual(
            fakeDownloader.downloaded.map(\.guid), ["b"],
            "Auto-queued episodes are still eligible for auto-download"
        )
        await fulfillment(of: [queueChange], timeout: 1)
    }

    /// A backfill refresh (migrated shell) must NOT auto-download -- its inserted
    /// episodes are pre-existing catalog, matching the existing `wasBackfill`
    /// notification gate (#72 / #639).
    func testBackfillRefreshDoesNotAutoDownload() async throws {
        let ctx = TestStore.freshContext()
        AppSettingsStore(context: ctx).setInt(3, for: SettingsKey.autoDownloadCount)
        let shell = Podcast(feedURL: "https://x/feed.xml", title: "Shell")
        ctx.insert(shell)
        try ctx.save()
        let fetcher = FakeFeedFetcher(feed([episode("a", d1), episode("b", d2)]))
        let fakeDownloader = FakeDownloader()
        let repo = SubscriptionRepository(context: ctx, feed: fetcher, downloader: fakeDownloader)

        _ = try await repo.refresh(shell)

        XCTAssertTrue(fakeDownloader.downloaded.isEmpty, "Backfilled catalog episodes must not auto-download")
    }

    /// Bug 1 also applies to the whole-library refresh path: `refreshAll()` must
    /// auto-download genuinely-new episodes discovered per podcast, matching
    /// `refresh(_:)`'s single-podcast behavior.
    func testRefreshAllAutoDownloadsNewEpisodesAcrossPodcasts() async throws {
        let ctx = TestStore.freshContext()
        AppSettingsStore(context: ctx).setInt(1, for: SettingsKey.autoDownloadCount)
        let fetcher = FakeFeedFetcher(feed([episode("a", d1)]))
        let fakeDownloader = FakeDownloader()
        let repo = SubscriptionRepository(context: ctx, feed: fetcher, downloader: fakeDownloader)
        _ = try await repo.subscribe(feedURL: "https://x/one.xml")
        _ = try await repo.subscribe(feedURL: "https://x/two.xml")
        fakeDownloader.reset()

        // Both podcasts share the same fetcher (FakeFeedFetcher ignores the URL),
        // so each discovers "b" as a genuinely new episode.
        fetcher.feed = feed([episode("a", d1), episode("b", d2)])
        _ = await repo.refreshAll()

        XCTAssertEqual(fakeDownloader.downloaded.count, 2, "One new-episode download per podcast")
        XCTAssertTrue(fakeDownloader.downloaded.allSatisfy { $0.guid == "b" })
    }

    /// #696 regression guard. `mergeBackgroundWrites` used to fetch the ENTIRE
    /// Episode table to re-fault held objects after a background save — measured
    /// on device at +580 MB (400 feeds) / ~+1.7 GB (1200 feeds), a memory-pressure
    /// jetsam kill on low-RAM devices that ran on every launch/resume/refresh/import.
    /// It now re-faults ONLY the episodes of the podcasts a refresh actually
    /// touched, passed as `affectedPodcastIDs` (flat +6.6 MB at 1184 feeds). This
    /// asserts the scoped re-fault still surfaces new episodes on the HELD
    /// main-context `Podcast` objects across a whole-library `refreshAll()` — the
    /// exact behavior the old blanket fetch provided, now for multiple affected IDs.
    func testRefreshAllSurfacesNewEpisodesOnHeldPodcastsViaScopedRefault() async throws {
        let ctx = TestStore.freshContext()
        let fetcher = FakeFeedFetcher(feed([episode("a", d1)]))
        let repo = SubscriptionRepository(context: ctx, feed: fetcher)
        let one = try await repo.subscribe(feedURL: "https://x/one.xml")
        let two = try await repo.subscribe(feedURL: "https://x/two.xml")
        XCTAssertEqual(one.episodes?.count, 1)
        XCTAssertEqual(two.episodes?.count, 1)

        // Both feeds gain a newer episode "b"; refreshAll passes both podcast IDs
        // to mergeBackgroundWrites as affectedPodcastIDs.
        fetcher.feed = feed([episode("a", d1), episode("b", d2)])
        _ = await repo.refreshAll()

        // The new episode is visible on the HELD Podcast objects — the scoped
        // per-podcast re-fault worked without materializing the whole Episode table.
        XCTAssertEqual(one.episodes?.count, 2)
        XCTAssertEqual(two.episodes?.count, 2)
        XCTAssertTrue(one.episodes?.contains { $0.guid == "b" } == true)
        XCTAssertTrue(two.episodes?.contains { $0.guid == "b" } == true)
        XCTAssertEqual(one.lastSeenPubDate, d2)
        XCTAssertEqual(two.lastSeenPubDate, d2)
    }

    /// `autoDownloadCount == 0` means auto-download is off. This must hold on the
    /// refresh path exactly as it already does on subscribe
    /// (`testSubscribeWithAutoDownloadCountZeroDoesNotDownload`) -- `refresh(_:)`
    /// still discovers "b" as genuinely new (and it still surfaces in the inbox),
    /// it just must not be downloaded.
    func testRefreshWithAutoDownloadCountZeroDoesNotDownload() async throws {
        let ctx = TestStore.freshContext()
        AppSettingsStore(context: ctx).setInt(0, for: SettingsKey.autoDownloadCount)
        let fetcher = FakeFeedFetcher(feed([episode("a", d1)]))
        let fakeDownloader = FakeDownloader()
        let repo = SubscriptionRepository(context: ctx, feed: fetcher, downloader: fakeDownloader)
        let podcast = try await repo.subscribe(feedURL: "https://x/feed.xml")
        fakeDownloader.reset()

        fetcher.feed = feed([episode("a", d1), episode("b", d2)])
        let outcome = try await repo.refresh(podcast)

        XCTAssertEqual(outcome.newEpisodeIDs.count, 1, "b is still discovered as genuinely new")
        XCTAssertTrue(fakeDownloader.downloaded.isEmpty, "autoDownloadCount == 0 must suppress refresh-triggered downloads")
    }

    /// Same off-switch, whole-library path: `refreshAll()` must also respect
    /// `autoDownloadCount == 0`.
    func testRefreshAllWithAutoDownloadCountZeroDoesNotDownload() async throws {
        let ctx = TestStore.freshContext()
        AppSettingsStore(context: ctx).setInt(0, for: SettingsKey.autoDownloadCount)
        let fetcher = FakeFeedFetcher(feed([episode("a", d1)]))
        let fakeDownloader = FakeDownloader()
        let repo = SubscriptionRepository(context: ctx, feed: fetcher, downloader: fakeDownloader)
        _ = try await repo.subscribe(feedURL: "https://x/one.xml")
        _ = try await repo.subscribe(feedURL: "https://x/two.xml")
        fakeDownloader.reset()

        fetcher.feed = feed([episode("a", d1), episode("b", d2)])
        _ = await repo.refreshAll()

        XCTAssertTrue(fakeDownloader.downloaded.isEmpty, "autoDownloadCount == 0 must suppress refreshAll-triggered downloads")
    }

    /// `refreshAll()` must download only for podcasts that genuinely discovered a
    /// new episode this pass -- a podcast with no change must not redownload its
    /// existing episodes, and must not prevent a sibling podcast's genuinely-new
    /// episode from downloading. Uses a per-URL fetcher (unlike `FakeFeedFetcher`,
    /// which returns the same feed for every URL) so the two podcasts can diverge:
    /// "unchanged.xml" never changes, "updated.xml" gains episode "b" before the
    /// refresh pass.
    func testRefreshAllOnlyDownloadsForPodcastsWithGenuinelyNewEpisodes() async throws {
        let ctx = TestStore.freshContext()
        AppSettingsStore(context: ctx).setInt(3, for: SettingsKey.autoDownloadCount)
        let fetcher = PerURLFeedFetcher()
        fetcher.setFeed(feed([episode("a", d1)]), for: "https://x/unchanged.xml")
        fetcher.setFeed(feed([episode("a", d1)]), for: "https://x/updated.xml")
        let fakeDownloader = FakeDownloader()
        let repo = SubscriptionRepository(context: ctx, feed: fetcher, downloader: fakeDownloader)
        _ = try await repo.subscribe(feedURL: "https://x/unchanged.xml")
        _ = try await repo.subscribe(feedURL: "https://x/updated.xml")
        fakeDownloader.reset()

        // Only "updated.xml" gains a genuinely new episode this pass.
        fetcher.setFeed(feed([episode("a", d1), episode("b", d2)]), for: "https://x/updated.xml")
        _ = await repo.refreshAll()

        XCTAssertEqual(
            fakeDownloader.downloaded.map(\.guid), ["b"],
            "Only the podcast with a genuinely new episode should trigger a download"
        )
    }

    // MARK: RefreshOutcome.newEpisodeIDs (#639)

    /// The identifiers backing Bug 1's fix: `refresh(_:)` must report the
    /// `persistentModelID` of every genuinely-new episode so the caller can
    /// resolve and download them, and the IDs must actually resolve (proving
    /// they were captured AFTER the background save, not before -- a
    /// `persistentModelID` read before a SwiftData save is temporary).
    func testRefreshOutcomeNewEpisodeIDsPopulatedForGenuinelyNewEpisodes() async throws {
        let ctx = TestStore.freshContext()
        let fetcher = FakeFeedFetcher(feed([episode("a", d1)]))
        let repo = SubscriptionRepository(context: ctx, feed: fetcher)
        let podcast = try await repo.subscribe(feedURL: "https://x/feed.xml")

        fetcher.feed = feed([episode("a", d1), episode("b", d2), episode("c", d3)])
        let outcome = try await repo.refresh(podcast)

        XCTAssertEqual(outcome.newEpisodeIDs.count, 2, "Both b and c are genuinely new")
        let resolvedGUIDs = Set(outcome.newEpisodeIDs.compactMap { id in
            podcast.episodes?.first { $0.persistentModelID == id }?.guid
        })
        XCTAssertEqual(resolvedGUIDs, ["b", "c"], "Every ID must resolve to the correct main-context episode")
    }

    /// Backfilled episodes must never populate `newEpisodeIDs`, mirroring
    /// `wasBackfill` and `newestNewEpisodeGUID`.
    func testBackfillRefreshOutcomeNewEpisodeIDsIsEmpty() async throws {
        let ctx = TestStore.freshContext()
        let shell = Podcast(feedURL: "https://x/feed.xml", title: "Shell")
        ctx.insert(shell)
        try ctx.save()
        let fetcher = FakeFeedFetcher(feed([episode("a", d1), episode("b", d2)]))
        let repo = SubscriptionRepository(context: ctx, feed: fetcher)

        let outcome = try await repo.refresh(shell)

        XCTAssertTrue(outcome.newEpisodeIDs.isEmpty, "Backfill must never carry auto-download-eligible IDs")
    }

    // MARK: Auto-queue on refresh

    func testManualLibraryRefreshTriggersAutoQueueNewEpisodes() async throws {
        for trigger in [FeedRefreshTrigger.manualToolbar, .manualPullToRefresh] {
            let ctx = TestStore.freshContext()
            let feedURL = "https://x/\(trigger.rawValue).xml"
            let podcast = Podcast(
                feedURL: feedURL,
                title: "Manual refresh",
                autoQueue: true,
                lastSeenPubDate: d1
            )
            ctx.insert(podcast)
            try ctx.save()
            let downloader = FakeDownloader()
            let repo = makeManualLibraryRefreshRepository(
                context: ctx,
                feed: FakeFeedFetcher(feed([episode("new", d2)])),
                downloader: downloader
            )

            _ = await repo.refreshAllReport(trigger: trigger)

            let refreshed = try XCTUnwrap(
                ctx.fetch(FetchDescriptor<Episode>()).first
            )
            XCTAssertEqual(refreshed.status, .inQueue, "\(trigger.rawValue) must auto-queue")
            XCTAssertTrue(refreshed.inboxDismissed)
            XCTAssertNotNil(refreshed.queueItem)
            XCTAssertEqual(downloader.queuedDownloadSweeps, 1)
        }
    }

    func testManualLibraryRefreshKeepsNonAutoQueueEpisodesInInbox() async throws {
        for trigger in [FeedRefreshTrigger.manualToolbar, .manualPullToRefresh] {
            let ctx = TestStore.freshContext()
            let feedURL = "https://x/inbox-\(trigger.rawValue).xml"
            let podcast = Podcast(
                feedURL: feedURL,
                title: "Manual refresh",
                autoQueue: false,
                lastSeenPubDate: d1
            )
            ctx.insert(podcast)
            try ctx.save()
            let repo = makeManualLibraryRefreshRepository(
                context: ctx,
                feed: FakeFeedFetcher(feed([episode("new", d2)]))
            )

            _ = await repo.refreshAllReport(trigger: trigger)

            let refreshed = try XCTUnwrap(
                ctx.fetch(FetchDescriptor<Episode>()).first
            )
            XCTAssertEqual(refreshed.status, .newEpisode)
            XCTAssertFalse(refreshed.inboxDismissed)
            XCTAssertNil(refreshed.queueItem)
        }
    }

    func testRefreshWithAutoQueueEnabledNewEpisodesGoToQueue() async throws {
        let ctx = TestStore.freshContext()
        let fetcher = FakeFeedFetcher(feed([episode("a", d1)]))
        let queueRepo = QueueRepository(context: ctx)
        let repo = SubscriptionRepository(context: ctx, feed: fetcher, queue: queueRepo)
        // Subscribe with autoQueue off so the initial episodes go to the normal path.
        let podcast = try await repo.subscribe(feedURL: "https://x/feed.xml")
        podcast.autoQueue = true
        try ctx.save()

        // Feed gains a new episode "b" at d2, which is after the mark (d1).
        fetcher.feed = feed([episode("a", d1), episode("b", d2)])
        try await repo.refresh(podcast)

        let b = try XCTUnwrap(podcast.episodes?.first { $0.guid == "b" })
        // Should be in queue, not inbox.
        XCTAssertEqual(b.status, .inQueue)
        XCTAssertTrue(b.inboxDismissed) // kept out of inbox
        XCTAssertNotNil(b.queueItem)
        // Verify it appears in the queue.
        XCTAssertTrue(queueRepo.queue().map(\.guid).contains("b"))
    }

    func testRefreshWithAutoQueueDisabledNewEpisodesGoToInbox() async throws {
        let ctx = TestStore.freshContext()
        let fetcher = FakeFeedFetcher(feed([episode("a", d1)]))
        let queueRepo = QueueRepository(context: ctx)
        let repo = SubscriptionRepository(context: ctx, feed: fetcher, queue: queueRepo)
        let podcast = try await repo.subscribe(feedURL: "https://x/feed.xml")
        // autoQueue defaults to false; leave it off.

        fetcher.feed = feed([episode("a", d1), episode("b", d2)])
        try await repo.refresh(podcast)

        let b = try XCTUnwrap(podcast.episodes?.first { $0.guid == "b" })
        // Should be in inbox, not queue.
        XCTAssertEqual(b.status, .newEpisode)
        XCTAssertFalse(b.inboxDismissed)
        XCTAssertNil(b.queueItem)
        XCTAssertFalse(queueRepo.queue().map(\.guid).contains("b"))
    }

    func testRefreshWithAutoQueueButNoQueueRepositoryNewEpisodesGoToInbox() async throws {
        let ctx = TestStore.freshContext()
        let fetcher = FakeFeedFetcher(feed([episode("a", d1)]))
        // No queue injected -- should fall back to normal inbox path.
        let repo = SubscriptionRepository(context: ctx, feed: fetcher)
        let podcast = try await repo.subscribe(feedURL: "https://x/feed.xml")
        podcast.autoQueue = true
        try ctx.save()

        fetcher.feed = feed([episode("a", d1), episode("b", d2)])
        try await repo.refresh(podcast)

        let b = try XCTUnwrap(podcast.episodes?.first { $0.guid == "b" })
        // Falls back to inbox because queue was not provided.
        XCTAssertEqual(b.status, .newEpisode)
        XCTAssertFalse(b.inboxDismissed)
    }

    func testRefreshAutoQueueDoesNotEnqueueOldEpisodes() async throws {
        let ctx = TestStore.freshContext()
        let d0 = Date(timeIntervalSince1970: 1_699_900_000) // older than d1
        let fetcher = FakeFeedFetcher(feed([episode("a", d1)]))
        let queueRepo = QueueRepository(context: ctx)
        let repo = SubscriptionRepository(context: ctx, feed: fetcher, queue: queueRepo)
        let podcast = try await repo.subscribe(feedURL: "https://x/feed.xml") // mark = d1
        podcast.autoQueue = true
        try ctx.save()

        // "old" has a pub date before the mark -- it is NOT a new episode.
        fetcher.feed = feed([episode("a", d1), episode("old", d0)])
        try await repo.refresh(podcast)

        // Automatic refresh no longer reconstructs historical catalog gaps.
        // The old row is neither inserted nor accidentally auto-queued.
        XCTAssertNil(podcast.episodes?.first { $0.guid == "old" })
        XCTAssertTrue(queueRepo.queue().isEmpty)
    }

    // MARK: refreshAll cancellation (#381)

    /// Subscribes `count` podcasts (each on a distinct URL) so the store holds
    /// real subscriptions with a high-water mark, then returns the fetcher's call
    /// count after setup so a later `refreshAll` delta can be measured.
    private func seedSubscriptions(
        _ count: Int, fetcher: CountingFeedFetcher, repo: SubscriptionRepository
    ) async throws {
        for i in 0..<count {
            _ = try await repo.subscribe(feedURL: "https://x/feed\(i).xml")
        }
    }

    func testRefreshAllProcessesAllWhenNotCancelled() async throws {
        let ctx = TestStore.freshContext()
        let fetcher = CountingFeedFetcher(feed([episode("a", d1)]))
        let repo = SubscriptionRepository(context: ctx, feed: fetcher)
        try await seedSubscriptions(3, fetcher: fetcher, repo: repo)

        let before = fetcher.fetchCount
        var lastCompleted = 0
        await repo.refreshAll(isCancelled: { false }) { completed, _ in
            lastCompleted = completed
        }

        // One fetch per podcast during refreshAll.
        XCTAssertEqual(fetcher.fetchCount - before, 3)
        XCTAssertEqual(lastCompleted, 3) // progress reported through to the end
    }

    func testRefreshAllStopsEarlyWhenCancelled() async throws {
        let ctx = TestStore.freshContext()
        let fetcher = CountingFeedFetcher(feed([episode("a", d1)]))
        let repo = SubscriptionRepository(context: ctx, feed: fetcher)
        try await seedSubscriptions(3, fetcher: fetcher, repo: repo)

        let before = fetcher.fetchCount
        // Cancel as soon as the first feed has been fetched. The guard runs before
        // each iteration, so iteration 0 fetches once, then iteration 1's guard
        // fires and the loop returns -- the remaining two feeds are never fetched.
        var progressCalls = 0
        await repo.refreshAll(isCancelled: { fetcher.fetchCount - before >= 1 }) { _, _ in
            progressCalls += 1
        }

        // Only the first podcast was fetched; the loop stopped before the rest.
        XCTAssertEqual(fetcher.fetchCount - before, 1)
        // Progress fired only for the one feed processed before cancellation.
        XCTAssertEqual(progressCalls, 1)
    }

    func testRefreshAllCancelledBeforeFirstFeedDoesNothing() async throws {
        let ctx = TestStore.freshContext()
        let fetcher = CountingFeedFetcher(feed([episode("a", d1)]))
        let repo = SubscriptionRepository(context: ctx, feed: fetcher)
        try await seedSubscriptions(3, fetcher: fetcher, repo: repo)

        let before = fetcher.fetchCount
        var progressCalls = 0
        // Already cancelled at entry: no feed should be fetched at all.
        await repo.refreshAll(isCancelled: { true }) { _, _ in progressCalls += 1 }

        XCTAssertEqual(fetcher.fetchCount - before, 0)
        XCTAssertEqual(progressCalls, 0)
    }

    // MARK: New-episode notifications (#72)

    func testRefreshOutcomeReportsAddedAndNewestEpisode() async throws {
        let ctx = TestStore.freshContext()
        let fetcher = FakeFeedFetcher(feed([episode("a", d1)]))
        let repo = SubscriptionRepository(context: ctx, feed: fetcher)
        let podcast = try await repo.subscribe(feedURL: "https://x/feed.xml")

        fetcher.feed = feed([episode("a", d1), episode("b", d2), episode("c", d3)])
        let outcome = try await repo.refresh(podcast)

        XCTAssertEqual(outcome.added, 2)
        XCTAssertFalse(outcome.wasBackfill)
        XCTAssertEqual(outcome.newestNewEpisodeGUID, "c", "Newest new episode is the deep-link target")
    }

    func testBackfillRefreshOutcomeIsMarkedBackfill() async throws {
        let ctx = TestStore.freshContext()
        let shell = Podcast(feedURL: "https://x/feed.xml", title: "Shell")
        ctx.insert(shell)
        try ctx.save()
        let fetcher = FakeFeedFetcher(feed([episode("a", d1), episode("b", d2)]))
        let repo = SubscriptionRepository(context: ctx, feed: fetcher)

        let outcome = try await repo.refresh(shell)

        XCTAssertTrue(outcome.wasBackfill, "Migrated-shell backfill must be flagged so it never notifies")
        XCTAssertNil(outcome.newestNewEpisodeGUID)
    }

    func testRefreshAllSurfacesNotificationOnlyForEnabledPodcastsWithNewEpisodes() async throws {
        let ctx = TestStore.freshContext()
        let fetcher = FakeFeedFetcher(feed([episode("a", d1)]))
        let repo = SubscriptionRepository(context: ctx, feed: fetcher)

        // Two enabled, one disabled. All subscribed (so backlog pre-dismissed).
        let enabled = try await repo.subscribe(feedURL: "https://x/enabled.xml")
        enabled.notificationEnabled = true
        let disabled = try await repo.subscribe(feedURL: "https://x/disabled.xml")
        disabled.notificationEnabled = false
        try ctx.save()

        // Feed now has a new episode "b" — applies to every feed via FakeFeedFetcher.
        fetcher.feed = feed([episode("a", d1), episode("b", d2)])
        let notifications = await repo.refreshAll()

        XCTAssertEqual(notifications.count, 1, "Only the enabled podcast notifies")
        let n = try XCTUnwrap(notifications.first)
        XCTAssertEqual(n.podcastFeedURL, "https://x/enabled.xml")
        XCTAssertEqual(n.episodeGUID, "b")
        XCTAssertEqual(n.newEpisodeCount, 1)
        XCTAssertEqual(n.podcastTitle, "Show")
    }

    func testRefreshAllSurfacesNoNotificationsWhenNoNewEpisodes() async throws {
        let ctx = TestStore.freshContext()
        let fetcher = FakeFeedFetcher(feed([episode("a", d1)]))
        let repo = SubscriptionRepository(context: ctx, feed: fetcher)
        let podcast = try await repo.subscribe(feedURL: "https://x/feed.xml")
        podcast.notificationEnabled = true
        try ctx.save()

        // No new episodes on refresh.
        let notifications = await repo.refreshAll()
        XCTAssertTrue(notifications.isEmpty)
    }

    // MARK: Foreground delivery + throttle decoupling (#421)

    /// The fix for #421: a FOREGROUND refresh (pull-to-refresh / launch restore)
    /// must DELIVER the notifications it finds, not discard them. This mirrors
    /// SubscriptionsView.refreshAll(): refreshAll() → NotificationService.deliver().
    func testForegroundRefreshDeliversNotifications() async throws {
        let ctx = TestStore.freshContext()
        let fetcher = FakeFeedFetcher(feed([episode("a", d1)]))
        let repo = SubscriptionRepository(context: ctx, feed: fetcher)
        let podcast = try await repo.subscribe(feedURL: "https://x/feed.xml")
        podcast.notificationEnabled = true
        try ctx.save()

        // A genuinely-new episode arrives.
        fetcher.feed = feed([episode("a", d1), episode("b", d2)])

        // Foreground path: find new episodes, then deliver via the service.
        let notifications = await repo.refreshAll()
        XCTAssertEqual(notifications.count, 1, "Foreground refresh found one new-episode notification")

        let mock = TestNotificationCenter(status: .authorized)
        await NotificationService(center: mock).deliver(notifications)

        let added = await mock.addedRequestSummaries()
        XCTAssertEqual(added.count, 1, "Foreground refresh delivered the notification (not discarded)")
        XCTAssertEqual(added.first, "Show")
    }

    /// A foreground pull stamps `lastFeedRefresh`, so the next background wake
    /// inside the 15-minute window is throttle-skipped (FeedRefreshPolicy). The
    /// notification must NOT be lost: the foreground path that found the new
    /// episode is the path that delivers it. This asserts the coherent design —
    /// throttle-skipped background, but the notification was already delivered.
    func testNotificationNotLostWhenBackgroundRunIsThrottleSkipped() async throws {
        let ctx = TestStore.freshContext()
        let fetcher = FakeFeedFetcher(feed([episode("a", d1)]))
        let repo = SubscriptionRepository(context: ctx, feed: fetcher)
        let podcast = try await repo.subscribe(feedURL: "https://x/feed.xml")
        podcast.notificationEnabled = true
        try ctx.save()

        // New episode appears; foreground pull finds and delivers it, then stamps
        // the throttle window (as SubscriptionsView.refreshAll does).
        fetcher.feed = feed([episode("a", d1), episode("b", d2)])
        let foregroundNotifications = await repo.refreshAll()
        let mock = TestNotificationCenter(status: .authorized)
        await NotificationService(center: mock).deliver(foregroundNotifications)
        let stampedAt = Date()

        // A background wake one minute later is within the 15-minute window, so
        // FeedRefreshPolicy skips it — it never even runs refreshAll.
        let backgroundShouldRun = FeedRefreshPolicy.shouldRefresh(
            lastRefresh: stampedAt,
            now: stampedAt.addingTimeInterval(60),
            force: false
        )
        XCTAssertFalse(backgroundShouldRun, "Background wake is throttle-skipped within the window")

        // The notification was already delivered by the foreground path, so it is
        // NOT lost despite the background skip. deliver() coalesces per podcast by
        // a stable identifier, so even if the background path had run it could not
        // double-deliver the same show.
        let addedCount = await mock.addedRequestCount()
        XCTAssertEqual(addedCount, 1, "Notification delivered once by the foreground path; never lost")
    }

    // MARK: Unsubscribe (#499/#500)

    /// Unsubscribing deletes the podcast and cascades its episodes, so the store is
    /// empty afterward and a fresh feed-URL lookup no longer finds it.
    func testUnsubscribeRemovesPodcastAndEpisodes() async throws {
        let ctx = TestStore.freshContext()
        let fetcher = FakeFeedFetcher(feed([episode("a", d1), episode("b", d2)]))
        let repo = SubscriptionRepository(context: ctx, feed: fetcher)
        let podcast = try await repo.subscribe(feedURL: "https://x/feed.xml")
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Podcast>()).count, 1)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Episode>()).count, 2)

        let ok = repo.unsubscribe(podcast)

        XCTAssertTrue(ok, "A clean delete saves and reports success")
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Podcast>()).count, 0)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Episode>()).count, 0, "Episodes cascade with the podcast")
    }

    /// Unsubscribing first removes folder memberships, so no dangling
    /// `FolderMembership` row survives the podcast delete (the F2 no-cascade case).
    func testUnsubscribeRemovesFolderMemberships() async throws {
        let ctx = TestStore.freshContext()
        let fetcher = FakeFeedFetcher(feed([episode("a", d1)]))
        let repo = SubscriptionRepository(context: ctx, feed: fetcher)
        let podcast = try await repo.subscribe(feedURL: "https://x/feed.xml")

        let folder = PodcastFolder(name: "News")
        ctx.insert(folder)
        FolderRepository(context: ctx).add(podcast, to: folder)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<FolderMembership>()).count, 1)

        XCTAssertTrue(repo.unsubscribe(podcast))

        XCTAssertEqual(
            try ctx.fetch(FetchDescriptor<FolderMembership>()).count, 0,
            "Membership rows are removed before the podcast delete so none dangles"
        )
        // The folder itself survives an unsubscribe — only its membership is gone.
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<PodcastFolder>()).count, 1)
    }

    /// A podcast's ``ListeningSession`` rows are dangling references (no cascade,
    /// the F2 decision), so unsubscribing must delete them or they survive as
    /// "Unknown Podcast" and corrupt stats (#377). Sessions belonging to other
    /// podcasts — and sessions reached only via `episode` (no `podcast` ref) —
    /// are handled correctly: the doomed show's are removed, the keeper's is not.
    func testUnsubscribeRemovesListeningSessionsButKeepsOthers() async throws {
        let ctx = TestStore.freshContext()
        let fetcher = FakeFeedFetcher(feed([episode("a", d1), episode("b", d2)]))
        let repo = SubscriptionRepository(context: ctx, feed: fetcher)
        let doomed = try await repo.subscribe(feedURL: "https://x/feed.xml")
        let doomedEpisodes = try ctx.fetch(FetchDescriptor<Episode>())
        XCTAssertEqual(doomedEpisodes.count, 2)

        // A second podcast whose session must survive the unsubscribe untouched.
        let keeper = Podcast(feedURL: "https://y/feed.xml", title: "Keeper")
        ctx.insert(keeper)

        // Three sessions on the doomed show — including one reached ONLY through
        // its episode (no direct `podcast` ref) — plus one on the keeper.
        ctx.insert(ListeningSession(episode: doomedEpisodes[0], podcast: doomed, durationSeconds: 600, date: d1))
        ctx.insert(ListeningSession(episode: doomedEpisodes[1], podcast: doomed, durationSeconds: 300, date: d2))
        ctx.insert(ListeningSession(episode: doomedEpisodes[0], podcast: nil, durationSeconds: 120, date: d3))
        ctx.insert(ListeningSession(episode: nil, podcast: keeper, durationSeconds: 900, date: d1))
        try ctx.save()
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<ListeningSession>()).count, 4)

        XCTAssertTrue(repo.unsubscribe(doomed))

        let remaining = try ctx.fetch(FetchDescriptor<ListeningSession>())
        XCTAssertEqual(
            remaining.count, 1,
            "All three of the doomed show's sessions are gone, including the episode-only one"
        )
        XCTAssertEqual(remaining.first?.podcast?.title, "Keeper", "The other podcast's session survives")

        // Nothing dangles into "Unknown Podcast" in the aggregated stats.
        let stats = StatsRepository(context: ctx).stats(for: .allTime)
        XCTAssertFalse(
            stats.perPodcast.contains { $0.podcastTitle == "Unknown Podcast" },
            "No dangling sessions remain to pollute stats"
        )
    }

    /// After unsubscribe the same feed URL can be subscribed again from scratch,
    /// proving the unique-feedURL row was truly removed (the search re-follow path).
    func testResubscribeAfterUnsubscribeSucceeds() async throws {
        let ctx = TestStore.freshContext()
        let fetcher = FakeFeedFetcher(feed([episode("a", d1)]))
        let repo = SubscriptionRepository(context: ctx, feed: fetcher)

        let first = try await repo.subscribe(feedURL: "https://x/feed.xml")
        XCTAssertTrue(repo.unsubscribe(first))
        let second = try await repo.subscribe(feedURL: "https://x/feed.xml")

        XCTAssertNotEqual(first.persistentModelID, second.persistentModelID)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Podcast>()).count, 1)
    }

    /// The inbox-unfollow path (#500): an inbox row reaches its owning show via
    /// `episode.podcast` and hands THAT to the shared `unsubscribe(_:)`. Unfollowing
    /// from one episode must remove the whole podcast, cascade its episodes, and
    /// empty the inbox of every one of its episodes — not just the row swiped.
    func testUnfollowFromInboxEpisodeRemovesOwningPodcastAndClearsItsInboxEpisodes() async throws {
        let ctx = TestStore.freshContext()
        let fetcher = FakeFeedFetcher(feed([episode("a", d1), episode("b", d2)]))
        let repo = SubscriptionRepository(context: ctx, feed: fetcher)
        _ = try await repo.subscribe(feedURL: "https://x/feed.xml")

        // Both seeded episodes are sitting in the inbox before the unfollow.
        let inboxBefore = InboxRepository(context: ctx).inboxEpisodes()
        XCTAssertEqual(inboxBefore.count, 2)

        // Take ONE inbox episode and resolve its owning show, exactly as the inbox
        // row's swipe action does (`episode.podcast`), then unfollow that show.
        let owningPodcast = try XCTUnwrap(inboxBefore.first?.podcast)
        let removed = repo.unsubscribe(owningPodcast)

        XCTAssertTrue(removed, "A clean delete saves and reports success")
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Podcast>()).count, 0)
        XCTAssertEqual(
            try ctx.fetch(FetchDescriptor<Episode>()).count, 0,
            "Every episode of the unfollowed show cascades away, not only the swiped row"
        )
        XCTAssertTrue(
            InboxRepository(context: ctx).inboxEpisodes().isEmpty,
            "The unfollowed show's episodes all leave the inbox"
        )
    }

    // MARK: Free-tier podcast cap (#635)

    /// Subscribing an 11th podcast throws `.podcastCapReached` for a non-entitled
    /// user, and the 11th podcast is never inserted.
    func testSubscribeThrowsCapReachedAtEleventhPodcastWhenNotEntitled() async throws {
        let ctx = TestStore.freshContext()
        let fetcher = FakeFeedFetcher(feed([episode("a", d1)]))
        let repo = SubscriptionRepository(context: ctx, feed: fetcher, isEntitled: false)
        for i in 0..<10 {
            _ = try await repo.subscribe(feedURL: "https://x/feed\(i).xml")
        }

        do {
            _ = try await repo.subscribe(feedURL: "https://x/feed10.xml")
            XCTFail("Expected SubscriptionError.podcastCapReached")
        } catch SubscriptionError.podcastCapReached(let currentCount, let limit) {
            XCTAssertEqual(currentCount, 10)
            XCTAssertEqual(limit, 10)
        }
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Podcast>()).count, 10, "The 11th podcast is never inserted")
    }

    /// An entitled (Plus) user can subscribe past 10 with no error.
    func testSubscribeSucceedsWhenEntitledRegardlessOfCount() async throws {
        let ctx = TestStore.freshContext()
        let fetcher = FakeFeedFetcher(feed([episode("a", d1)]))
        let repo = SubscriptionRepository(context: ctx, feed: fetcher, isEntitled: true)
        for i in 0..<12 {
            _ = try await repo.subscribe(feedURL: "https://x/feed\(i).xml")
        }
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Podcast>()).count, 12)
    }

    /// `isEntitled == nil` (the default) means the cap isn't enforced — every
    /// legacy/test call site that predates #635 keeps working unchanged.
    func testSubscribeSucceedsWhenIsEntitledNilRegardlessOfCount() async throws {
        let ctx = TestStore.freshContext()
        let fetcher = FakeFeedFetcher(feed([episode("a", d1)]))
        let repo = SubscriptionRepository(context: ctx, feed: fetcher) // isEntitled defaults to nil
        for i in 0..<12 {
            _ = try await repo.subscribe(feedURL: "https://x/feed\(i).xml")
        }
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Podcast>()).count, 12)
    }

    /// A grandfathered tester who already had 15 podcasts before gating shipped
    /// cannot add ANY more while non-entitled — not just past 15 — because
    /// `effectiveFreeLimit(grandfatheredCount: 15) == max(10, 15) == 15`, and their
    /// current count (15) is already at that raised limit.
    func testSubscribeRespectsRaisedGrandfatheredCount() async throws {
        let ctx = TestStore.freshContext()
        for i in 0..<15 {
            ctx.insert(Podcast(feedURL: "https://x/existing\(i).xml", title: "Existing \(i)"))
        }
        try ctx.save()
        AppSettingsStore(context: ctx).setInt(15, for: SettingsKey.grandfatheredPodcastCount)

        let fetcher = FakeFeedFetcher(feed([episode("a", d1)]))
        let repo = SubscriptionRepository(context: ctx, feed: fetcher, isEntitled: false)

        do {
            _ = try await repo.subscribe(feedURL: "https://x/new.xml")
            XCTFail("A grandfathered-15, non-entitled user cannot add ANY more podcast")
        } catch SubscriptionError.podcastCapReached(let currentCount, let limit) {
            XCTAssertEqual(currentCount, 15)
            XCTAssertEqual(limit, 15, "effectiveFreeLimit = max(10, 15) = 15")
        }
    }

    /// Bulk/OPML path (#635): with 3 already subscribed, requesting 12 more feeds
    /// imports only however many free slots remain and reports the rest skipped.
    func testSubscribeAllRespectsCapAndReportsSkipped() async throws {
        let ctx = TestStore.freshContext()
        for i in 0..<3 {
            ctx.insert(Podcast(feedURL: "https://x/existing\(i).xml", title: "Existing \(i)"))
        }
        try ctx.save()
        let fetcher = FakeFeedFetcher(feed([episode("a", d1)]))
        let repo = SubscriptionRepository(context: ctx, feed: fetcher, isEntitled: false)

        let feeds = (0..<12).map { "https://x/new\($0).xml" }
        let result = await repo.subscribeAll(feedURLs: feeds)

        XCTAssertEqual(result.outcomes.count, 7, "10 - 3 already subscribed = 7 free slots remaining")
        XCTAssertEqual(result.skippedForCap, 5)
    }

    func testSubscribeAllEntitledImportsAllRegardlessOfCap() async throws {
        let ctx = TestStore.freshContext()
        for i in 0..<3 {
            ctx.insert(Podcast(feedURL: "https://x/existing\(i).xml", title: "Existing \(i)"))
        }
        try ctx.save()
        let fetcher = FakeFeedFetcher(feed([episode("a", d1)]))
        let repo = SubscriptionRepository(context: ctx, feed: fetcher, isEntitled: true)

        let feeds = (0..<12).map { "https://x/new\($0).xml" }
        let result = await repo.subscribeAll(feedURLs: feeds)

        XCTAssertEqual(result.outcomes.count, 12)
        XCTAssertEqual(result.skippedForCap, 0)
    }

    func testSubscribeAllNilEntitlementDoesNotEnforceCap() async throws {
        let ctx = TestStore.freshContext()
        for i in 0..<3 {
            ctx.insert(Podcast(feedURL: "https://x/existing\(i).xml", title: "Existing \(i)"))
        }
        try ctx.save()
        let fetcher = FakeFeedFetcher(feed([episode("a", d1)]))
        let repo = SubscriptionRepository(context: ctx, feed: fetcher) // isEntitled defaults to nil

        let feeds = (0..<12).map { "https://x/new\($0).xml" }
        let result = await repo.subscribeAll(feedURLs: feeds)

        XCTAssertEqual(result.outcomes.count, 12)
        XCTAssertEqual(result.skippedForCap, 0)
    }

    /// Auto-download (#635): with a non-entitled user and podcasts beyond the cap,
    /// episodes belonging to read-only podcasts are NOT downloaded, while episodes
    /// for in-cap podcasts still download normally. Podcasts are inserted directly
    /// with explicit, distinct `createdAt` values so rank is deterministic
    /// (podcast 0 is oldest/in-cap; podcast 11 is newest/beyond the 10-podcast limit).
    func testAutoDownloadRecentSkipsReadOnlyPodcastsWhenNotEntitled() async throws {
        let ctx = TestStore.freshContext()
        AppSettingsStore(context: ctx).setInt(3, for: SettingsKey.autoDownloadCount)

        var podcasts: [Podcast] = []
        for i in 0..<12 {
            let podcast = Podcast(
                feedURL: "https://x/feed\(i).xml", title: "Show \(i)",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(i))
            )
            ctx.insert(podcast)
            let ep = Episode(guid: "g\(i)", title: "Ep \(i)", audioURL: "https://x/\(i).mp3", pubDate: d1)
            ep.podcast = podcast
            ctx.insert(ep)
            podcast.episodes = [ep]
            podcasts.append(podcast)
        }
        try ctx.save()

        let fetcher = FakeFeedFetcher(feed([episode("a", d1)]))
        let fakeDownloader = FakeDownloader()
        let repo = SubscriptionRepository(context: ctx, feed: fetcher, downloader: fakeDownloader, isEntitled: false)

        let inCap = podcasts[0] // rank 0 — well within the 10-podcast limit
        let overCap = podcasts[11] // rank 11 — beyond the limit, read-only

        await repo.autoDownloadRecent(episodeIDsPerPodcast: [
            (inCap.episodes ?? []).map(\.persistentModelID),
            (overCap.episodes ?? []).map(\.persistentModelID),
        ])

        let downloadedGUIDs = Set(fakeDownloader.downloaded.map(\.guid))
        XCTAssertTrue(downloadedGUIDs.contains("g0"), "In-cap podcast's episode still downloads")
        XCTAssertFalse(downloadedGUIDs.contains("g11"), "Read-only (beyond cap) podcast's episode is skipped")
    }
}

/// Local actor-isolated mock of ``NotificationScheduling`` for the foreground
/// delivery tests (#421). Mirrors the one in NotificationServiceTests, scoped
/// here so the two test files stay independent.
private actor TestNotificationCenter: @preconcurrency NotificationScheduling {
    private let status: UNAuthorizationStatus
    private(set) var addedRequests: [UNNotificationRequest] = []

    init(status: UNAuthorizationStatus) { self.status = status }

    func authorizationStatus() async -> UNAuthorizationStatus { status }
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool { true }
    func setNotificationCategories(_ categories: Set<UNNotificationCategory>) async {}
    func add(_ request: UNNotificationRequest) async throws { addedRequests.append(request) }
    func addedRequestCount() -> Int { addedRequests.count }
    func addedRequestSummaries() -> [String] { addedRequests.map(\.content.title) }
}
