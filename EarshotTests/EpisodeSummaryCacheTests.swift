import XCTest
@testable import Earshot

/// Tests the per-episode summary cache that keeps the HTML strip off the
/// VoiceOver focus-move path (#495). A fresh cache is used per test so results
/// don't leak across cases.
@MainActor
final class EpisodeSummaryCacheTests: XCTestCase {

    private func makeEpisode(guid: String = "ep1", description: String?) -> Episode {
        Episode(
            guid: guid,
            title: "Episode",
            audioURL: "https://example.com/\(guid).mp3",
            episodeDescription: description
        )
    }

    func testReturnsStrippedSummary() {
        let cache = EpisodeSummaryCache()
        let episode = makeEpisode(description: "<p>Hello <b>there</b>.</p>")
        XCTAssertEqual(cache.summary(for: episode), "Hello there.")
    }

    func testReturnsNilForNoDescription() {
        let cache = EpisodeSummaryCache()
        XCTAssertNil(cache.summary(for: makeEpisode(description: nil)))
        XCTAssertNil(cache.summary(for: makeEpisode(guid: "ep2", description: "")))
    }

    func testRepeatedLookupIsStable() {
        let cache = EpisodeSummaryCache()
        let episode = makeEpisode(description: "<p>Cached value.</p>")
        let first = cache.summary(for: episode)
        let second = cache.summary(for: episode)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first, "Cached value.")
    }

    func testNilResultIsAlsoStableOnRepeatLookup() {
        let cache = EpisodeSummaryCache()
        let episode = makeEpisode(description: nil)
        XCTAssertNil(cache.summary(for: episode))
        // Second lookup hits the cached "no summary" sentinel, still nil.
        XCTAssertNil(cache.summary(for: episode))
    }

    func testMatchesSharedHelper() {
        let cache = EpisodeSummaryCache()
        let html = "<p>This is a slightly longer description that should be capped at some point for terseness.</p>"
        let episode = makeEpisode(description: html)
        XCTAssertEqual(cache.summary(for: episode), EpisodeSummary.shortSummary(html))
    }
}
