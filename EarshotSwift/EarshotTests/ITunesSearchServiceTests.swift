import XCTest
@testable import Earshot

/// Tests ``ITunesSearchService`` end to end through ``MockURLProtocol`` so the
/// iTunes directory path never touches the real network. Covers the three
/// distinct outcomes (results, empty, failure) plus result-mapping rules.
final class ITunesSearchServiceTests: XCTestCase {

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func makeService() -> ITunesSearchService {
        ITunesSearchService(session: MockURLProtocol.makeSession())
    }

    // MARK: Success with results

    func test_successfulDecode_returnsMappedResults() async {
        let body = Data("""
        {"resultCount":1,"results":[
          {"collectionName":"Swift Talk","artistName":"objc.io",
           "feedUrl":"https://talk.objc.io/feed","artworkUrl600":"https://img/600.jpg",
           "artworkUrl100":"https://img/100.jpg"}
        ]}
        """.utf8)
        MockURLProtocol.setOutcomes([.response(statusCode: 200, data: body)])

        let outcome = await makeService().search("swift")

        guard case .results(let results) = outcome else {
            return XCTFail("Expected .results, got \(outcome)")
        }
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].title, "Swift Talk")
        XCTAssertEqual(results[0].author, "objc.io")
        XCTAssertEqual(results[0].feedURL, "https://talk.objc.io/feed")
        XCTAssertEqual(results[0].artworkURL, "https://img/600.jpg")
    }

    // MARK: Result mapping fallbacks

    func test_missingCollectionName_fallsBackToTrackName() async {
        let body = Data("""
        {"results":[
          {"trackName":"Fallback Show","artistName":"Host",
           "feedUrl":"https://x.com/feed"}
        ]}
        """.utf8)
        MockURLProtocol.setOutcomes([.response(statusCode: 200, data: body)])

        let outcome = await makeService().search("fallback")

        guard case .results(let results) = outcome else {
            return XCTFail("Expected .results, got \(outcome)")
        }
        XCTAssertEqual(results.first?.title, "Fallback Show")
    }

    func test_missingFeedURL_isDropped() async {
        let body = Data("""
        {"results":[
          {"collectionName":"No Feed Show","artistName":"Host"},
          {"collectionName":"Good Show","feedUrl":"https://good.com/feed"}
        ]}
        """.utf8)
        MockURLProtocol.setOutcomes([.response(statusCode: 200, data: body)])

        let outcome = await makeService().search("feeds")

        guard case .results(let results) = outcome else {
            return XCTFail("Expected .results, got \(outcome)")
        }
        XCTAssertEqual(results.map(\.title), ["Good Show"])
    }

    // MARK: Dedupe by feed URL (pure helper)

    /// iTunes can return the same show more than once under different collection
    /// entries that share a `feedUrl`. Later duplicates are dropped and the first
    /// occurrence (highest relevance) is kept, so the result `id`s stay unique and
    /// the "result N of M" count is honest (#501).
    func test_dedupe_collapsesDuplicateFeedURLs_keepingFirstOccurrence() {
        let input = [
            PodcastSearchResult(id: "https://a.com/feed", title: "A (primary)", author: "x",
                                artworkURL: nil, feedURL: "https://a.com/feed"),
            PodcastSearchResult(id: "https://b.com/feed", title: "B", author: "y",
                                artworkURL: nil, feedURL: "https://b.com/feed"),
            PodcastSearchResult(id: "https://a.com/feed", title: "A (duplicate)", author: "x",
                                artworkURL: nil, feedURL: "https://a.com/feed"),
        ]

        let deduped = ITunesSearchService.dedupedByFeedURL(input)

        XCTAssertEqual(deduped.map(\.feedURL), ["https://a.com/feed", "https://b.com/feed"])
        // First occurrence wins: the "primary" A is kept, the later duplicate dropped.
        XCTAssertEqual(deduped.map(\.title), ["A (primary)", "B"])
        XCTAssertEqual(deduped.count, 2)
    }

    /// Relevance order is preserved across a dedupe: surviving rows stay in their
    /// original first-seen positions, only later duplicates are removed.
    func test_dedupe_preservesRelevanceOrder() {
        let input = ["c", "a", "b", "a", "c", "d"].enumerated().map { offset, key in
            PodcastSearchResult(id: "https://\(key).com/feed", title: "\(key)\(offset)",
                                author: nil, artworkURL: nil, feedURL: "https://\(key).com/feed")
        }

        let deduped = ITunesSearchService.dedupedByFeedURL(input)

        XCTAssertEqual(
            deduped.map(\.feedURL),
            ["https://c.com/feed", "https://a.com/feed", "https://b.com/feed", "https://d.com/feed"]
        )
    }

    /// Input with no duplicates is returned unchanged (same elements, same order).
    func test_dedupe_noDuplicates_returnsInputUnchanged() {
        let input = (0..<5).map { i in
            PodcastSearchResult(id: "https://\(i).com/feed", title: "Show \(i)", author: nil,
                                artworkURL: nil, feedURL: "https://\(i).com/feed")
        }

        let deduped = ITunesSearchService.dedupedByFeedURL(input)

        XCTAssertEqual(deduped, input)
    }

    /// An empty input yields an empty output.
    func test_dedupe_emptyInput_returnsEmpty() {
        XCTAssertEqual(ITunesSearchService.dedupedByFeedURL([]), [])
    }

    /// End to end through the decode path: a response carrying the same feed twice
    /// collapses to a single result, so the displayed count matches the unique
    /// show count rather than the raw iTunes hit count.
    func test_search_dedupesDuplicateFeedsFromResponse() async {
        let body = Data("""
        {"resultCount":3,"results":[
          {"collectionName":"Daily News","feedUrl":"https://news.com/feed"},
          {"collectionName":"Tech Weekly","feedUrl":"https://tech.com/feed"},
          {"collectionName":"Daily News (rerun listing)","feedUrl":"https://news.com/feed"}
        ]}
        """.utf8)
        MockURLProtocol.setOutcomes([.response(statusCode: 200, data: body)])

        let outcome = await makeService().search("news")

        guard case .results(let results) = outcome else {
            return XCTFail("Expected .results, got \(outcome)")
        }
        XCTAssertEqual(results.map(\.feedURL), ["https://news.com/feed", "https://tech.com/feed"])
        XCTAssertEqual(results.count, 2)
    }

    // MARK: Success but empty

    func test_emptyResults_returnsEmptyResultsOutcome() async {
        let body = Data(#"{"resultCount":0,"results":[]}"#.utf8)
        MockURLProtocol.setOutcomes([.response(statusCode: 200, data: body)])

        let outcome = await makeService().search("nothingmatchesthis")

        XCTAssertEqual(outcome, .results([]))
    }

    // MARK: Network failure

    func test_networkError_returnsFailure() async {
        MockURLProtocol.setOutcomes([.failure(URLError(.notConnectedToInternet))])

        let outcome = await makeService().search("swift")

        XCTAssertEqual(outcome, .failure)
    }

    // MARK: Decode failure

    func test_malformedBody_returnsFailure() async {
        let body = Data("this is not json".utf8)
        MockURLProtocol.setOutcomes([.response(statusCode: 200, data: body)])

        let outcome = await makeService().search("swift")

        XCTAssertEqual(outcome, .failure)
    }

    // MARK: Query encoding / parameter-injection hardening

    func test_searchTerm_isConfinedToTermParameter_noInjection() async {
        let body = Data(#"{"results":[]}"#.utf8)
        MockURLProtocol.setOutcomes([.response(statusCode: 200, data: body)])

        // A term laden with query delimiters must not be able to inject extra
        // parameters into the request. With naive `.urlQueryAllowed` encoding the
        // `&` and `=` would survive and add a second `limit`/`evil` parameter.
        _ = await makeService().search("swift&limit=200&evil=1")

        let url = try? XCTUnwrap(MockURLProtocol.requestedURLs.first)
        let components = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        let items = components?.queryItems ?? []

        XCTAssertEqual(components?.host, "itunes.apple.com")
        // limit appears exactly once and is still 25 (not overridden to 200).
        XCTAssertEqual(items.filter { $0.name == "limit" }.map(\.value), ["25"])
        // No stray "evil" parameter leaked out of the term.
        XCTAssertFalse(items.contains { $0.name == "evil" })
        // The whole hostile string is preserved as the single term value.
        XCTAssertEqual(items.first { $0.name == "term" }?.value, "swift&limit=200&evil=1")
    }

    // MARK: Empty query short-circuits

    func test_whitespaceQuery_returnsEmptyWithoutNetworking() async {
        // No outcomes queued: if the service hit the network it would surface a
        // failure instead of an empty success.
        let outcome = await makeService().search("   ")

        XCTAssertEqual(outcome, .results([]))
    }
}
