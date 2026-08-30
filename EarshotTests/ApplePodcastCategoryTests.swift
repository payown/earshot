import XCTest
@testable import Earshot

final class ApplePodcastCategoryTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    func testTaxonomyHasUniqueIDsAndNames() {
        let categories = ApplePodcastCategories.all
        let flattened = categories + categories.flatMap(\.subcategories)

        XCTAssertEqual(categories.count, 19)
        XCTAssertEqual(Set(flattened.map(\.id)).count, flattened.count)
        XCTAssertEqual(Set(flattened.map(\.name)).count, flattened.count)
    }

    func testTaxonomyContainsExpectedParentAndSubcategories() throws {
        let fiction = try XCTUnwrap(ApplePodcastCategories.all.first { $0.name == "Fiction" })
        XCTAssertEqual(fiction.id, "1483")
        XCTAssertEqual(
            fiction.subcategories.map(\.name),
            ["Comedy Fiction", "Drama", "Science Fiction"]
        )

        let sports = try XCTUnwrap(ApplePodcastCategories.all.first { $0.name == "Sports" })
        XCTAssertEqual(sports.subcategories.count, 15)
        XCTAssertTrue(sports.subcategories.contains { $0.id == "1547" && $0.name == "American Football" })
    }

    func testStorefrontUsesTwoLetterRegionAndFallsBackForInvalidValues() {
        XCTAssertEqual(ApplePodcastCategoryService.sanitizedStorefront("SE"), "se")
        XCTAssertEqual(ApplePodcastCategoryService.sanitizedStorefront("USA"), "us")
        XCTAssertEqual(ApplePodcastCategoryService.sanitizedStorefront("1!"), "us")
    }

    func testCategoryLoadPreservesChartOrderAndMapsLookupFields() async throws {
        let chart = Data("""
        {"feed":{"entry":[
          {"id":{"attributes":{"im:id":"20"}}},
          {"id":{"attributes":{"im:id":"10"}}}
        ]}}
        """.utf8)
        // Lookup deliberately returns the opposite order. The chart ranking wins.
        let lookup = Data("""
        {"results":[
          {"collectionId":10,"collectionName":"Second","artistName":"B",
           "feedUrl":"https://second.example/feed","artworkUrl100":"https://img/second"},
          {"collectionId":20,"collectionName":"First","artistName":"A",
           "feedUrl":"https://first.example/feed","artworkUrl600":"https://img/first"}
        ]}
        """.utf8)
        MockURLProtocol.setOutcomes([
            .response(statusCode: 200, data: chart),
            .response(statusCode: 200, data: lookup),
        ])

        let outcome = await ApplePodcastCategoryService(
            session: MockURLProtocol.makeSession(), cache: ApplePodcastCategoryCache()
        ).topPodcasts(categoryID: "1483", storefront: "se", limit: 100)

        guard case let .results(results) = outcome else {
            return XCTFail("Expected category results")
        }
        XCTAssertEqual(results.map(\.title), ["First", "Second"])
        XCTAssertEqual(results.map(\.author), ["A", "B"])
        XCTAssertEqual(results.map(\.feedURL), [
            "https://first.example/feed", "https://second.example/feed",
        ])
        XCTAssertEqual(results.first?.artworkURL, "https://img/first")

        let requests = MockURLProtocol.requestedURLs
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].host, "itunes.apple.com")
        XCTAssertEqual(requests[0].path, "/se/rss/toppodcasts/limit=100/genre=1483/json")
        let lookupItems = URLComponents(
            url: requests[1], resolvingAgainstBaseURL: false
        )?.queryItems
        XCTAssertEqual(lookupItems?.first { $0.name == "id" }?.value, "20,10")
        XCTAssertEqual(lookupItems?.first { $0.name == "country" }?.value, "se")
        XCTAssertEqual(lookupItems?.first { $0.name == "entity" }?.value, "podcast")
    }

    func testMissingFeedAndCanonicalDuplicateAreDropped() async {
        let chart = Data("""
        {"feed":{"entry":[
          {"id":{"attributes":{"im:id":"1"}}},
          {"id":{"attributes":{"im:id":"2"}}},
          {"id":{"attributes":{"im:id":"3"}}}
        ]}}
        """.utf8)
        let lookup = Data("""
        {"results":[
          {"collectionId":1,"collectionName":"First","feedUrl":"HTTPS://Example.COM:443/feed#top"},
          {"collectionId":2,"collectionName":"No Feed"},
          {"collectionId":3,"collectionName":"Duplicate","feedUrl":"https://example.com/feed"}
        ]}
        """.utf8)
        MockURLProtocol.setOutcomes([
            .response(statusCode: 200, data: chart),
            .response(statusCode: 200, data: lookup),
        ])

        let outcome = await ApplePodcastCategoryService(
            session: MockURLProtocol.makeSession(), cache: ApplePodcastCategoryCache()
        ).topPodcasts(categoryID: "1301", storefront: "us", limit: 25)

        guard case let .results(results) = outcome else {
            return XCTFail("Expected category results")
        }
        XCTAssertEqual(results.map(\.title), ["First"])
    }

    func testEmptyChartReturnsEmptyWithoutLookupRequest() async {
        MockURLProtocol.setOutcomes([
            .response(statusCode: 200, data: Data(#"{"feed":{}}"#.utf8)),
        ])

        let outcome = await ApplePodcastCategoryService(
            session: MockURLProtocol.makeSession(), cache: ApplePodcastCategoryCache()
        ).topPodcasts(categoryID: "1511", storefront: "us", limit: 25)

        XCTAssertEqual(outcome, .results([]))
        XCTAssertEqual(MockURLProtocol.requestedURLs.count, 1)
    }

    func testMalformedChartAndLookupFailuresReturnFailure() async {
        MockURLProtocol.setOutcomes([
            .response(statusCode: 200, data: Data("bad chart".utf8)),
        ])
        let service = ApplePodcastCategoryService(
            session: MockURLProtocol.makeSession(), cache: ApplePodcastCategoryCache()
        )
        let malformedOutcome = await service.topPodcasts(
            categoryID: "1483", storefront: "us", limit: 25
        )
        XCTAssertEqual(malformedOutcome, .failure)

        MockURLProtocol.reset()
        let chart = Data(#"{"feed":{"entry":[{"id":{"attributes":{"im:id":"1"}}}]}}"#.utf8)
        MockURLProtocol.setOutcomes([
            .response(statusCode: 200, data: chart),
            .failure(URLError(.notConnectedToInternet)),
        ])
        let networkOutcome = await service.topPodcasts(
            categoryID: "1483", storefront: "us", limit: 25
        )
        XCTAssertEqual(networkOutcome, .failure)
    }

    func testInvalidCategoryShortCircuitsWithoutNetwork() async {
        let outcome = await ApplePodcastCategoryService(
            session: MockURLProtocol.makeSession(), cache: ApplePodcastCategoryCache()
        ).topPodcasts(categoryID: "1483&limit=999", storefront: "us", limit: 999)

        XCTAssertEqual(outcome, .failure)
        XCTAssertTrue(MockURLProtocol.requestedURLs.isEmpty)
    }

    func testLimitIsClampedToOneThroughOneHundred() async {
        let empty = Data(#"{"feed":{}}"#.utf8)
        MockURLProtocol.setOutcomes([
            .response(statusCode: 200, data: empty),
            .response(statusCode: 200, data: empty),
        ])
        let service = ApplePodcastCategoryService(
            session: MockURLProtocol.makeSession(), cache: ApplePodcastCategoryCache()
        )

        _ = await service.topPodcasts(categoryID: "1483", storefront: "us", limit: 0)
        _ = await service.topPodcasts(categoryID: "1483", storefront: "us", limit: 999)

        XCTAssertEqual(MockURLProtocol.requestedURLs.map(\.path), [
            "/us/rss/toppodcasts/limit=1/genre=1483/json",
            "/us/rss/toppodcasts/limit=100/genre=1483/json",
        ])
    }

    func testPagingAdvancesByTwentyFiveAndCapsAtTotal() {
        XCTAssertEqual(CategoryResultPaging.nextVisibleCount(current: 25, total: 100), 50)
        XCTAssertEqual(CategoryResultPaging.nextVisibleCount(current: 75, total: 88), 88)
        XCTAssertEqual(CategoryResultPaging.nextVisibleCount(current: 88, total: 88), 88)
        XCTAssertEqual(
            CategoryResultPaging.loadedAnnouncement(previous: 25, current: 50),
            "25 more results loaded, 50 results available"
        )
        XCTAssertEqual(
            CategoryResultPaging.loadedAnnouncement(previous: 75, current: 88),
            "13 more results loaded, 88 results available"
        )
        XCTAssertEqual(
            CategoryResultPaging.initialAnnouncement(
                visible: 25, total: 100, categoryName: "Fiction"
            ),
            "25 of 100 top shows loaded in Fiction"
        )
        XCTAssertEqual(
            CategoryResultPaging.initialAnnouncement(
                visible: 1, total: 1, categoryName: "History"
            ),
            "1 top show loaded in History"
        )
    }

    func testSuccessfulCategoryResultIsCachedForTheSession() async {
        let chart = Data(#"{"feed":{"entry":[{"id":{"attributes":{"im:id":"1"}}}]}}"#.utf8)
        let lookup = Data(#"{"results":[{"collectionId":1,"collectionName":"One","feedUrl":"https://one.example/feed"}]}"#.utf8)
        MockURLProtocol.setOutcomes([
            .response(statusCode: 200, data: chart),
            .response(statusCode: 200, data: lookup),
        ])
        let cache = ApplePodcastCategoryCache()
        let service = ApplePodcastCategoryService(
            session: MockURLProtocol.makeSession(), cache: cache
        )

        let first = await service.topPodcasts(
            categoryID: "1483", storefront: "us", limit: 25
        )
        let second = await service.topPodcasts(
            categoryID: "1483", storefront: "us", limit: 25
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(MockURLProtocol.requestedURLs.count, 2)
    }

    @MainActor
    func testResultsModelPublishesLoadedAndFailedStates() async {
        let result = PodcastSearchResult(
            id: "https://example.com/feed",
            title: "Example",
            author: nil,
            artworkURL: nil,
            feedURL: "https://example.com/feed"
        )
        let loadedModel = PodcastCategoryResultsModel(
            service: StubApplePodcastCategoryService(outcome: .results([result])),
            storefront: "se"
        )
        await loadedModel.load(categoryID: "1483")
        XCTAssertEqual(loadedModel.state, .loaded([result]))

        let failedModel = PodcastCategoryResultsModel(
            service: StubApplePodcastCategoryService(outcome: .failure),
            storefront: "se"
        )
        await failedModel.load(categoryID: "1483")
        XCTAssertEqual(failedModel.state, .failed)
    }
}

private struct StubApplePodcastCategoryService: ApplePodcastCategoryFetching {
    let outcome: DirectorySearchOutcome

    func topPodcasts(
        categoryID: String,
        storefront: String,
        limit: Int
    ) async -> DirectorySearchOutcome {
        outcome
    }
}
