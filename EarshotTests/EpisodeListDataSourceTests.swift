import SwiftData
import XCTest
@testable import Earshot

@MainActor
final class EpisodeListDataSourceTests: XCTestCase {
    private func fixture(count: Int) throws -> (ModelContext, Podcast) {
        let context = TestStore.freshContext()
        let podcast = Podcast(feedURL: "https://example.com/stress.xml", title: "Stress Show")
        context.insert(podcast)
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<count {
            let episode = Episode(
                guid: String(format: "%06d", index),
                title: "Episode \(String(format: "%06d", index))",
                audioURL: "https://example.com/\(index).mp3",
                episodeDescription: index == 42 ? "A Café astronomy special" : nil,
                pubDate: epoch.addingTimeInterval(TimeInterval(index))
            )
            episode.podcast = podcast
            context.insert(episode)
        }
        try context.save()
        return (context, podcast)
    }

    private func source(_ context: ModelContext, _ podcast: Podcast) -> EpisodeListDataSource {
        EpisodeListDataSource(
            context: context,
            podcastID: podcast.persistentModelID,
            podcastTitle: podcast.title
        )
    }

    func testInitialAndExplicitNextPageAreBounded() throws {
        let (context, podcast) = try fixture(count: 250)
        let data = source(context, podcast)

        data.resetAndLoad(filter: .all, sort: .latestFirst, searchText: "")
        XCTAssertEqual(data.episodes.count, 100)
        XCTAssertEqual(data.matchingCount, 250)
        XCTAssertTrue(data.hasMore)
        XCTAssertEqual(data.episodes.first?.guid, "000249")

        data.loadMore(filter: .all, sort: .latestFirst, searchText: "")
        XCTAssertEqual(data.episodes.count, 200)
        XCTAssertEqual(Set(data.episodes.map(\.persistentModelID)).count, 200)
        XCTAssertTrue(data.hasMore)
    }

    func testStressPodcastPublishesOnlyFirstHundredModels() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUN_EPISODE_LIST_SCALE_DIAG"] != nil,
            "Set RUN_EPISODE_LIST_SCALE_DIAG=1 for the 45,436-row memory diagnostic."
        )
        let (context, podcast) = try fixture(count: 45_436)
        let data = source(context, podcast)

        data.resetAndLoad(filter: .all, sort: .latestFirst, searchText: "")

        XCTAssertEqual(data.matchingCount, 45_436)
        XCTAssertEqual(data.episodes.count, EpisodeListDataSource.pageSize)
        XCTAssertEqual(data.episodes.first?.guid, "045435")
    }

    func testUnheardPredicateAndWholeScopeCounts() throws {
        let (context, podcast) = try fixture(count: 8)
        let played = try context.fetch(FetchDescriptor<Episode>()).prefix(3)
        for episode in played { episode.isPlayed = true }
        try context.save()
        let data = source(context, podcast)

        data.resetAndLoad(filter: .unheard, sort: .latestFirst, searchText: "")

        XCTAssertEqual(data.allCount, 8)
        XCTAssertEqual(data.unplayedCount, 5)
        XCTAssertEqual(data.matchingCount, 5)
        XCTAssertTrue(data.episodes.allSatisfy { !$0.isPlayed })
    }

    func testNewestOldestAndNilDatesLast() throws {
        let (context, podcast) = try fixture(count: 3)
        let undated = Episode(guid: "nil", title: "Undated", audioURL: "https://example.com/nil.mp3")
        undated.podcast = podcast
        context.insert(undated)
        try context.save()
        let data = source(context, podcast)

        data.resetAndLoad(filter: .all, sort: .latestFirst, searchText: "")
        XCTAssertEqual(data.episodes.map(\.guid), ["000002", "000001", "000000", "nil"])

        data.resetAndLoad(filter: .all, sort: .latestLast, searchText: "")
        XCTAssertEqual(data.episodes.map(\.guid), ["000000", "000001", "000002", "nil"])
    }

    func testLocalizedTitleDescriptionAndPodcastTitleSearchCapability() throws {
        let (context, podcast) = try fixture(count: 80)
        let data = source(context, podcast)

        data.resetAndLoad(filter: .all, sort: .latestFirst, searchText: "CAFE")
        XCTAssertEqual(data.matchingCount, 1)
        XCTAssertEqual(data.episodes.first?.guid, "000042")

        data.resetAndLoad(filter: .all, sort: .latestFirst, searchText: "episode 000007")
        XCTAssertEqual(data.episodes.map(\.guid), ["000007"])

        data.resetAndLoad(filter: .all, sort: .latestFirst, searchText: "stress show")
        XCTAssertEqual(data.matchingCount, 80, "matching the podcast title preserves the old all-row behavior")
    }

    func testEqualDateRawStoreBoundaryIsDeterministicButDocumentsArticleResidual() throws {
        let context = TestStore.freshContext()
        let podcast = Podcast(feedURL: "https://example.com/ties.xml", title: "Ties")
        context.insert(podcast)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<100 {
            let episode = Episode(
                guid: "b\(index)", title: "Banana \(String(format: "%03d", index))",
                audioURL: "https://example.com/b\(index).mp3", pubDate: date
            )
            episode.podcast = podcast
            context.insert(episode)
        }
        let article = Episode(
            guid: "apple", title: "The Apple", audioURL: "https://example.com/apple.mp3", pubDate: date
        )
        article.podcast = podcast
        context.insert(article)
        try context.save()
        let data = source(context, podcast)

        data.resetAndLoad(filter: .all, sort: .latestFirst, searchText: "")

        XCTAssertEqual(data.episodes.count, 100)
        XCTAssertEqual(data.episodes.first?.guid, "b0")
        XCTAssertFalse(
            data.episodes.contains { $0.guid == "apple" },
            "the exact 100-model fetch cannot see an article-aware title beyond the raw-title store boundary"
        )
        data.loadMore(filter: .all, sort: .latestFirst, searchText: "")
        XCTAssertEqual(data.episodes.first?.guid, "apple")
    }

    func testDeletionBetweenPagesDoesNotDuplicateOrCrash() throws {
        let (context, podcast) = try fixture(count: 250)
        let data = source(context, podcast)
        data.resetAndLoad(filter: .all, sort: .latestFirst, searchText: "")
        let deleted = try XCTUnwrap(data.episodes.dropFirst(20).first)
        context.delete(deleted)
        try context.save()

        data.loadMore(filter: .all, sort: .latestFirst, searchText: "")

        XCTAssertEqual(data.episodes.count, 199, "the deleted loaded row is removed; the request still fetches only 100 more")
        XCTAssertEqual(Set(data.episodes.map(\.persistentModelID)).count, 199)
        XCTAssertFalse(data.episodes.contains { $0.isDeleted })
    }
}
