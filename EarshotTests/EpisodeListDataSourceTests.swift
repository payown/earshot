import SwiftData
import XCTest
@testable import Earshot

@MainActor
final class EpisodeListDataSourceTests: XCTestCase {
    private func assertPartialReady(_ data: EpisodeListDataSource) async {
        let ready = await data.waitForCurrentLoad()
        XCTAssertTrue(ready)
    }

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

    func testPersistedPodcastOrderAppliesToPagesSearchAndReload() throws {
        let (context, podcast) = try fixture(count: 250)
        let settings = AppSettingsStore(context: context)
        settings.setEpisodeSortOrder(.latestLast, forFeedURL: podcast.feedURL)
        let sort = settings.episodeSortOrder(forFeedURL: podcast.feedURL)
        let data = source(context, podcast)
        data.resetAndLoad(filter: .unheard, sort: sort, searchText: "Episode")
        XCTAssertEqual(data.episodes.first?.guid, "000000")
        data.loadMore(filter: .unheard, sort: sort, searchText: "Episode")
        XCTAssertEqual(data.episodes.last?.guid, "000199")
        XCTAssertEqual(data.episodes.count, 200)
        let reloaded = source(context, podcast)
        reloaded.resetAndLoad(filter: .all, sort: settings.episodeSortOrder(forFeedURL: podcast.feedURL), searchText: "Episode")
        XCTAssertEqual(reloaded.episodes.first?.guid, "000000")
        XCTAssertEqual(settings.episodeSortOrder(), .latestFirst)
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

    func testOlderFeedInsertionKeepsExpandedPageInBothSortOrders() throws {
        for sort in [EpisodeSortOrder.latestFirst, .latestLast] {
            let (context, podcast) = try fixture(count: 250)
            let data = source(context, podcast)
            data.resetAndLoad(filter: .all, sort: sort, searchText: "")
            data.loadMore(filter: .all, sort: sort, searchText: "")
            let previouslyVisible = Set(data.episodes.map(\.persistentModelID))
            XCTAssertEqual(previouslyVisible.count, 200)

            let earlier = Date(timeIntervalSince1970: 1_699_999_000)
            for index in 0..<10 {
                let episode = Episode(
                    guid: "older-\(index)", title: "Older \(index)",
                    audioURL: "https://example.com/older-\(index).mp3",
                    pubDate: earlier.addingTimeInterval(TimeInterval(index))
                )
                episode.podcast = podcast
                context.insert(episode)
            }
            try context.save()

            data.reloadKeepingLoadedLimit(
                filter: .all, sort: sort, searchText: "", insertedEpisodeCount: 10
            )

            XCTAssertEqual(data.episodes.count, 210)
            XCTAssertTrue(previouslyVisible.isSubset(of: Set(data.episodes.map(\.persistentModelID))))
            XCTAssertTrue(data.hasMore)
            data.loadMore(filter: .all, sort: sort, searchText: "")
            XCTAssertEqual(data.episodes.count, 260)
            XCTAssertEqual(Set(data.episodes.map(\.persistentModelID)).count, 260)
            XCTAssertFalse(data.hasMore)
        }
    }

    func testSelectAllIdentitiesIncludeUnloadedPagesAndHonorFilter() async throws {
        let (context, podcast) = try fixture(count: 225)
        let data = source(context, podcast)
        data.resetAndLoad(filter: .all, sort: .latestFirst, searchText: "")
        XCTAssertEqual(data.episodes.count, 100)

        let all = try await data.matchingEpisodeIDs(filter: .all, searchText: "")
        XCTAssertEqual(all.count, 225)
        XCTAssertEqual(data.episodes.count, 100, "selection must not expand the rendered page")

        let searched = try await data.matchingEpisodeIDs(filter: .all, searchText: "Episode 000224")
        XCTAssertEqual(searched.count, 1)
        let played = try context.fetch(FetchDescriptor<Episode>()).first { $0.guid == "000224" }!
        played.isPlayed = true
        try context.save()
        let unheard = try await data.matchingEpisodeIDs(filter: .unheard, searchText: "Episode 000224")
        XCTAssertTrue(unheard.isEmpty)
    }

    func testStressPodcastPublishesOnlyFirstHundredModels() async throws {
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
        let started = Date()
        let ids = try await data.matchingEpisodeIDs(filter: .all, searchText: "")
        XCTAssertEqual(ids.count, 45_436)
        XCTAssertEqual(data.episodes.count, EpisodeListDataSource.pageSize)
        print("Episode selection ID fetch, 45,436 rows: \(Date().timeIntervalSince(started)) seconds")
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

    func testSavedUnfinishedProgressCanBeCountedInStore() async throws {
        let (context, podcast) = try fixture(count: 5)
        let episodes = try context.fetch(FetchDescriptor<Episode>())
            .sorted { $0.guid < $1.guid }
        episodes[0].positionSeconds = 0
        episodes[1].positionSeconds = 42
        episodes[2].positionSeconds = 900
        episodes[2].isPlayed = true
        episodes[3].positionSeconds = 12
        episodes[4].positionSeconds = 0
        try context.save()

        let podcastID = podcast.persistentModelID
        let request = FetchDescriptor<Episode>(predicate: #Predicate {
            $0.podcast?.persistentModelID == podcastID &&
            $0.positionSeconds > 0 && $0.playedAt == nil
        })

        XCTAssertEqual(try context.fetchCount(request), 2)
        XCTAssertEqual(Set(try context.fetch(request).map(\.guid)), ["000001", "000003"])
        let data = source(context, podcast)
        data.resetAndLoad(filter: .partiallyPlayed, sort: .latestFirst, searchText: "")
        await assertPartialReady(data)
        XCTAssertEqual(data.filteredCount, 2)
        XCTAssertEqual(data.matchingCount, 2)
        XCTAssertEqual(Set(data.episodes.map(\.guid)), ["000001", "000003"])

        // A legacy or repaired row can have only one of the two completion
        // markers. Neither should be called partially played.
        episodes[0].positionSeconds = 77
        episodes[0].playedAt = .now
        episodes[4].positionSeconds = 99
        episodes[4].status = .played
        try context.save()
        let candidateRequest = FetchDescriptor<Episode>(predicate: #Predicate {
            $0.podcast?.persistentModelID == podcastID &&
            $0.positionSeconds > 0 &&
            $0.playedAt == nil
        })
        XCTAssertEqual(Set(try context.fetch(candidateRequest).map(\.guid)),
                       ["000001", "000003", "000004"])
        data.reloadKeepingLoadedLimit(filter: .partiallyPlayed, sort: .latestFirst, searchText: "")
        await assertPartialReady(data)
        XCTAssertEqual(Set(data.episodes.map(\.guid)), ["000001", "000003"])
        XCTAssertEqual(data.matchingCount, 2)
    }

    func testPartiallyPlayedSearchSortPagingAndSelectionStayStoreBounded() async throws {
        for sort in [EpisodeSortOrder.latestFirst, .latestLast] {
            let (context, podcast) = try fixture(count: 250)
            let stored = try context.fetch(FetchDescriptor<Episode>())
                .sorted { $0.guid < $1.guid }
            for episode in stored.prefix(125) { episode.positionSeconds = 20 }
            try context.save()
            let data = source(context, podcast)

            data.resetAndLoad(filter: .partiallyPlayed, sort: sort, searchText: "")
            await assertPartialReady(data)
            XCTAssertEqual(data.allCount, 250)
            XCTAssertEqual(data.unplayedCount, 250)
            XCTAssertEqual(data.filteredCount, 125)
            XCTAssertEqual(data.matchingCount, 125)
            XCTAssertEqual(data.episodes.count, 100)
            XCTAssertTrue(data.hasMore)
            XCTAssertEqual(data.episodes.first?.guid,
                           sort == .latestFirst ? "000124" : "000000")

            data.loadMore(filter: .partiallyPlayed, sort: sort, searchText: "")
            await assertPartialReady(data)
            XCTAssertEqual(data.episodes.count, 125)
            XCTAssertFalse(data.hasMore)
            XCTAssertEqual(Set(data.episodes.map(\.persistentModelID)).count, 125)

            data.resetAndLoad(filter: .partiallyPlayed, sort: sort,
                              searchText: "Episode 000042")
            await assertPartialReady(data)
            XCTAssertEqual(data.episodes.map(\.guid), ["000042"])
            XCTAssertEqual(data.matchingCount, 1)
            let ids = try await data.matchingEpisodeIDs(
                filter: .partiallyPlayed, searchText: "Episode 000042"
            )
            XCTAssertEqual(ids, Set(data.episodes.map(\.persistentModelID)))

            stored[42].isPlayed = true
            try context.save()
            data.reloadKeepingLoadedLimit(filter: .partiallyPlayed, sort: sort,
                                          searchText: "Episode 000042")
            await assertPartialReady(data)
            XCTAssertEqual(data.matchingCount, 0)
            XCTAssertTrue(data.episodes.isEmpty)
        }
    }

    func testPartiallyPlayedSupersededSearchAndCancellationDoNotPublishLateResults() async throws {
        let (context, podcast) = try fixture(count: 1_000)
        let stored = try context.fetch(FetchDescriptor<Episode>())
        for episode in stored { episode.positionSeconds = 15 }
        try context.save()
        let data = source(context, podcast)

        data.resetAndLoad(filter: .partiallyPlayed, sort: .latestFirst, searchText: "Episode")
        data.resetAndLoad(filter: .partiallyPlayed, sort: .latestFirst,
                          searchText: "Episode 000042")
        await assertPartialReady(data)
        XCTAssertEqual(data.episodes.map(\.guid), ["000042"])
        XCTAssertEqual(data.matchingCount, 1)

        data.resetAndLoad(filter: .partiallyPlayed, sort: .latestFirst, searchText: "Episode")
        data.cancelPendingLoad()
        XCTAssertFalse(data.isLoading)
        data.resetAndLoad(filter: .partiallyPlayed, sort: .latestFirst,
                          searchText: "Episode 000999")
        await assertPartialReady(data)
        XCTAssertEqual(data.episodes.map(\.guid), ["000999"])
        XCTAssertEqual(data.matchingCount, 1)
    }

    func testPartiallyPlayedTenThousandRowsKeepsRenderedPageBounded() async throws {
        let (context, podcast) = try fixture(count: 10_000)
        let stored = try context.fetch(FetchDescriptor<Episode>())
        for episode in stored { episode.positionSeconds = 15 }
        try context.save()
        let data = source(context, podcast)

        let started = Date()
        data.resetAndLoad(filter: .partiallyPlayed, sort: .latestFirst, searchText: "")
        XCTAssertTrue(data.isLoading)
        XCTAssertLessThanOrEqual(data.episodes.count, EpisodeListDataSource.pageSize)
        await assertPartialReady(data)
        XCTAssertEqual(data.matchingCount, 10_000)
        XCTAssertEqual(data.episodes.count, EpisodeListDataSource.pageSize)
        XCTAssertEqual(data.episodes.first?.guid, "009999")
        print("Partially Played 10,000-row background scan: \(Date().timeIntervalSince(started)) seconds")
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
