import XCTest
import SwiftData
@testable import Earshot

private final class FakeFeedFetcher: FeedFetching {
    var feed: ParsedFeed
    init(_ feed: ParsedFeed) { self.feed = feed }
    func fetch(_ urlString: String) async throws -> ParsedFeed { feed }
}

/// Records which episodes were passed to ``download(_:)`` without touching
/// the network or filesystem.
private final class FakeDownloader: EpisodeDownloading {
    private(set) var downloaded: [Episode] = []
    func download(_ episode: Episode) async { downloaded.append(episode) }
}

/// Returns the same feed for every URL but counts how many times ``fetch(_:)``
/// is called, so `refreshAll`'s per-iteration cancellation guard (#381) can be
/// asserted: a cancelled run must stop issuing fetches early.
private final class CountingFeedFetcher: FeedFetching {
    var feed: ParsedFeed
    private(set) var fetchCount = 0
    init(_ feed: ParsedFeed) { self.feed = feed }
    func fetch(_ urlString: String) async throws -> ParsedFeed {
        fetchCount += 1
        return feed
    }
}

@MainActor
final class SubscriptionRepositoryTests: XCTestCase {

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

    func testSubscribeCreatesPodcastAndPreDismissesBacklog() async throws {
        let ctx = TestStore.freshContext()
        let fetcher = FakeFeedFetcher(feed([episode("a", d1), episode("b", d2)]))
        let repo = SubscriptionRepository(context: ctx, feed: fetcher)

        let podcast = try await repo.subscribe(feedURL: "https://x/feed.xml")

        XCTAssertEqual(podcast.episodes.count, 2)
        XCTAssertTrue(podcast.episodes.allSatisfy { $0.inboxDismissed })
        XCTAssertEqual(podcast.lastSeenPubDate, d2)
        XCTAssertEqual(podcast.author, "Host")
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

    func testRefreshAddsOnlyNewEpisodesAndSurfacesThemInInbox() async throws {
        let ctx = TestStore.freshContext()
        let fetcher = FakeFeedFetcher(feed([episode("a", d1), episode("b", d2)]))
        let repo = SubscriptionRepository(context: ctx, feed: fetcher)
        let podcast = try await repo.subscribe(feedURL: "https://x/feed.xml")

        // Feed gains a newer episode "c" at d3.
        fetcher.feed = feed([episode("a", d1), episode("b", d2), episode("c", d3)])
        try await repo.refresh(podcast)

        XCTAssertEqual(podcast.episodes.count, 3)
        let c = try XCTUnwrap(podcast.episodes.first { $0.guid == "c" })
        XCTAssertFalse(c.inboxDismissed) // newer than the mark -> inbox
        XCTAssertEqual(podcast.lastSeenPubDate, d3)
    }

    func testRefreshIsIdempotentWhenNoNewEpisodes() async throws {
        let ctx = TestStore.freshContext()
        let fetcher = FakeFeedFetcher(feed([episode("a", d1)]))
        let repo = SubscriptionRepository(context: ctx, feed: fetcher)
        let podcast = try await repo.subscribe(feedURL: "https://x/feed.xml")

        try await repo.refresh(podcast)
        XCTAssertEqual(podcast.episodes.count, 1)
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

        XCTAssertEqual(shell.episodes.count, 2)
        XCTAssertTrue(shell.episodes.allSatisfy { $0.inboxDismissed }) // backlog pre-dismissed
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
        XCTAssertEqual(podcast.episodes.count, 2)
    }

    // MARK: Auto-queue on refresh

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

        let b = try XCTUnwrap(podcast.episodes.first { $0.guid == "b" })
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

        let b = try XCTUnwrap(podcast.episodes.first { $0.guid == "b" })
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

        let b = try XCTUnwrap(podcast.episodes.first { $0.guid == "b" })
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

        let old = try XCTUnwrap(podcast.episodes.first { $0.guid == "old" })
        // Old episodes are pre-dismissed into inbox, not auto-queued.
        XCTAssertEqual(old.status, .newEpisode)
        XCTAssertTrue(old.inboxDismissed) // dismissed, not queued
        XCTAssertNil(old.queueItem)
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
}
