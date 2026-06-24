import XCTest
import SwiftData
import os
@testable import Earshot

/// Covers the bulk OPML import path (#440): importing a multi-feed OPML must
/// subscribe every feed, create folders + memberships, be idempotent, run
/// auto-download once, and — the core VoiceOver fix — reconcile the main context
/// (the full-table re-fetch in `mergeBackgroundWrites`) exactly ONCE for the whole
/// import rather than once per feed.
///
/// The fetcher returns a distinct feed per URL (title derived from the URL) so the
/// progress `currentTitle` and per-podcast episodes can be asserted. No network is
/// hit: `FeedRefreshActor` calls the fake fetcher.
@MainActor
final class OPMLBulkImportTests: XCTestCase {

    private let d1 = Date(timeIntervalSince1970: 1_700_000_000)
    private let d2 = Date(timeIntervalSince1970: 1_700_100_000)
    private let d3 = Date(timeIntervalSince1970: 1_700_200_000)

    /// Returns a feed whose title encodes the requested URL, with three episodes,
    /// so a multi-feed import yields distinguishable podcasts and episode sets.
    private final class PerURLFeedFetcher: FeedFetching, @unchecked Sendable {
        let d1: Date, d2: Date, d3: Date
        init(d1: Date, d2: Date, d3: Date) { self.d1 = d1; self.d2 = d2; self.d3 = d3 }
        func fetch(_ urlString: String) async throws -> ParsedFeed {
            func ep(_ guid: String, _ date: Date) -> ParsedEpisode {
                ParsedEpisode(
                    guid: "\(urlString)#\(guid)", title: "Ep \(guid)", audioURL: "\(urlString)/\(guid).mp3",
                    description: nil, pubDate: date, durationSeconds: nil, artworkURL: nil,
                    episodeNumber: nil, seasonNumber: nil, chapterURL: nil, transcriptURL: nil
                )
            }
            return ParsedFeed(
                title: "Show \(urlString)", artworkURL: nil, description: nil, author: "Host",
                websiteURL: nil, language: nil, category: nil,
                episodes: [ep("a", d1), ep("b", d2), ep("c", d3)]
            )
        }
    }

    /// Records every episode handed to `download(_:)`.
    private final class FakeDownloader: EpisodeDownloading {
        private(set) var downloaded: [Episode] = []
        func download(_ episode: Episode) async { downloaded.append(episode) }
    }

    private func fetcher() -> PerURLFeedFetcher { PerURLFeedFetcher(d1: d1, d2: d2, d3: d3) }

    private func opml(feeds: [String]) -> String {
        let outlines = feeds.map { "<outline type=\"rss\" text=\"\($0)\" xmlUrl=\"\($0)\"/>" }.joined(separator: "\n")
        return "<opml><body>\n\(outlines)\n</body></opml>"
    }

    // MARK: All feeds subscribed

    func testBulkImportSubscribesEveryFeed() async throws {
        let ctx = TestStore.freshContext()
        let repo = SubscriptionRepository(context: ctx, feed: fetcher())
        let service = OPMLImportService(context: ctx, subscriptions: repo)

        let feeds = (0..<5).map { "https://feed\($0).com/rss" }
        let imported = await service.importOPML(opml(feeds: feeds))

        XCTAssertEqual(imported, 5)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Podcast>()).count, 5)
        // Each feed's three episodes were inserted (backlog pre-dismissed).
        let episodes = try ctx.fetch(FetchDescriptor<Episode>())
        XCTAssertEqual(episodes.count, 15)
        XCTAssertTrue(episodes.allSatisfy { $0.inboxDismissed }, "Subscribe pre-dismisses backlog")
    }

    // MARK: Folders + memberships

    func testBulkImportCreatesFoldersAndMemberships() async throws {
        let ctx = TestStore.freshContext()
        let repo = SubscriptionRepository(context: ctx, feed: fetcher())
        let service = OPMLImportService(context: ctx, subscriptions: repo)

        let opml = """
        <opml><body>
        <outline text="News">
            <outline type="rss" text="A" xmlUrl="https://a.com/feed"/>
            <outline type="rss" text="B" xmlUrl="https://b.com/feed"/>
        </outline>
        <outline type="rss" text="C" xmlUrl="https://c.com/feed"/>
        </body></opml>
        """
        let imported = await service.importOPML(opml)

        XCTAssertEqual(imported, 3)
        let folders = try ctx.fetch(FetchDescriptor<PodcastFolder>())
        XCTAssertEqual(folders.map(\.name), ["News"])
        let memberships = try ctx.fetch(FetchDescriptor<FolderMembership>())
        XCTAssertEqual(memberships.count, 2, "A and B are in News; C is ungrouped")
        let memberFeedURLs = Set(memberships.compactMap { $0.podcast?.feedURL })
        XCTAssertEqual(memberFeedURLs, ["https://a.com/feed", "https://b.com/feed"])
    }

    // MARK: Idempotency

    func testBulkImportIsIdempotent() async throws {
        let ctx = TestStore.freshContext()
        let opml = """
        <opml><body>
        <outline text="News">
            <outline type="rss" text="A" xmlUrl="https://a.com/feed"/>
        </outline>
        <outline type="rss" text="B" xmlUrl="https://b.com/feed"/>
        </body></opml>
        """

        let first = await OPMLImportService(
            context: ctx, subscriptions: SubscriptionRepository(context: ctx, feed: fetcher())
        ).importOPML(opml)
        let second = await OPMLImportService(
            context: ctx, subscriptions: SubscriptionRepository(context: ctx, feed: fetcher())
        ).importOPML(opml)

        XCTAssertEqual(first, 2)
        XCTAssertEqual(second, 2, "Re-import still resolves all feeds (now already-subscribed)")
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Podcast>()).count, 2, "No duplicate podcasts")
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<FolderMembership>()).count, 1, "No duplicate memberships")
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<PodcastFolder>()).count, 1, "No duplicate folders")
    }

    // MARK: The core fix — merge ONCE per import, not per feed

    func testBulkImportReconcilesMainContextExactlyOnce() async throws {
        let ctx = TestStore.freshContext()
        let merges = OSAllocatedUnfairLock(initialState: 0)
        let repo = SubscriptionRepository(
            context: ctx, feed: fetcher(),
            onMerge: { merges.withLock { $0 += 1 } }
        )
        let service = OPMLImportService(context: ctx, subscriptions: repo)

        let feeds = (0..<8).map { "https://feed\($0).com/rss" }
        _ = await service.importOPML(opml(feeds: feeds))

        XCTAssertEqual(
            merges.withLock { $0 }, 1,
            "Main-context reconciliation (full-table re-fetch) runs ONCE for the whole import, not once per feed"
        )
    }

    // MARK: #296 future-date clamp preserved

    func testBulkImportPreservesFutureDateClamp() async throws {
        final class FutureFeed: FeedFetching, @unchecked Sendable {
            let d1: Date
            init(_ d1: Date) { self.d1 = d1 }
            func fetch(_ urlString: String) async throws -> ParsedFeed {
                let future = Date(timeIntervalSinceNow: 60 * 60 * 24 * 30)
                func ep(_ guid: String, _ date: Date) -> ParsedEpisode {
                    ParsedEpisode(
                        guid: guid, title: guid, audioURL: "x", description: nil, pubDate: date,
                        durationSeconds: nil, artworkURL: nil, episodeNumber: nil, seasonNumber: nil,
                        chapterURL: nil, transcriptURL: nil
                    )
                }
                return ParsedFeed(
                    title: "Show", artworkURL: nil, description: nil, author: nil, websiteURL: nil,
                    language: nil, category: nil, episodes: [ep("a", d1), ep("future", future)]
                )
            }
        }
        let ctx = TestStore.freshContext()
        let repo = SubscriptionRepository(context: ctx, feed: FutureFeed(d1))
        let service = OPMLImportService(context: ctx, subscriptions: repo)

        _ = await service.importOPML(opml(feeds: ["https://x.com/feed"]))

        let podcast = try XCTUnwrap(try ctx.fetch(FetchDescriptor<Podcast>()).first)
        XCTAssertEqual(podcast.lastSeenPubDate, d1, "Mark is the newest NON-future date (#296)")
    }

    // MARK: Auto-download runs (once at the end) when a downloader is injected

    func testBulkImportAutoDownloadsRecentWhenDownloaderInjected() async throws {
        let ctx = TestStore.freshContext()
        AppSettingsStore(context: ctx).setInt(2, for: SettingsKey.autoDownloadCount)
        let downloader = FakeDownloader()
        let repo = SubscriptionRepository(context: ctx, feed: fetcher(), downloader: downloader)
        let service = OPMLImportService(context: ctx, subscriptions: repo)

        let feeds = ["https://a.com/feed", "https://b.com/feed"]
        _ = await service.importOPML(opml(feeds: feeds))

        // 2 most recent (b@d2, c@d3) per podcast × 2 podcasts = 4 downloads.
        XCTAssertEqual(downloader.downloaded.count, 4)
        // None of the downloaded episodes is the oldest "a" (d1).
        XCTAssertTrue(downloader.downloaded.allSatisfy { !$0.guid.hasSuffix("#a") })
    }

    func testBulkImportNoDownloaderDoesNotDownload() async throws {
        let ctx = TestStore.freshContext()
        AppSettingsStore(context: ctx).setInt(3, for: SettingsKey.autoDownloadCount)
        let repo = SubscriptionRepository(context: ctx, feed: fetcher()) // no downloader
        let service = OPMLImportService(context: ctx, subscriptions: repo)

        let imported = await service.importOPML(opml(feeds: ["https://a.com/feed"]))
        XCTAssertEqual(imported, 1) // completes, no crash, no downloads
    }

    // MARK: Progress callback

    func testBulkImportProgressFiresWithIncreasingCompletedUpToTotal() async throws {
        let ctx = TestStore.freshContext()
        let repo = SubscriptionRepository(context: ctx, feed: fetcher())
        let service = OPMLImportService(context: ctx, subscriptions: repo)

        let feeds = (0..<4).map { "https://feed\($0).com/rss" }
        let recorder = ProgressRecorder()
        _ = await service.importOPML(opml(feeds: feeds)) { completed, total, title in
            recorder.completes.append(completed)
            recorder.total = total
            if let title { recorder.titles.append(title) }
        }

        XCTAssertEqual(recorder.completes, [1, 2, 3, 4], "completed increments by one per feed up to total")
        XCTAssertEqual(recorder.total, 4)
        XCTAssertEqual(recorder.titles.count, 4, "Each completed feed reports a title")
    }
}

/// Captures progress callback values on the main actor.
@MainActor
private final class ProgressRecorder {
    var completes: [Int] = []
    var total = 0
    var titles: [String] = []
}
