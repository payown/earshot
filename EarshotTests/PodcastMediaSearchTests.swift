import XCTest
@testable import Earshot

final class PodcastMediaSearchTests: XCTestCase {
    private func episode(_ id: String, title: String, show: String = "Daily Show", date: Date? = nil) -> SearchContent {
        SearchContent(id: id, feedURL: "https://example.com/feed", guid: id,
            title: title, showName: show, summary: "", date: date, duration: nil)
    }

    func testFullTitleAndSingleWordFindSameEpisode() {
        let record = episode("one", title: "The dangers of AI")
        XCTAssertEqual(PodcastMediaSearch.matches([record], query: "The dangers of AI"), [record])
        XCTAssertEqual(PodcastMediaSearch.matches([record], query: "Dangers"), [record])
        XCTAssertTrue(PodcastMediaSearch.matches([record], query: "dangerous unrelated story").isEmpty)
    }

    func testMatchesShowAndTitleAcrossPunctuationAndAccents() {
        let record = episode("one", title: "Café: Today's News", show: "Daily Stories")
        XCTAssertEqual(PodcastMediaSearch.matches([record], query: "daily cafe"), [record])
    }

    func testUnspecifiedReturnsNewestEpisodesWithStableTiesAndLimit() {
        let records = (0..<30).map { episode(String(format: "%02d", $0), title: "Episode", date: Date(timeIntervalSince1970: Double($0))) }
        let result = PodcastMediaSearch.matches(records.reversed(), query: nil)
        XCTAssertEqual(result.count, 20)
        XCTAssertEqual(result.first?.id, "29")
        XCTAssertEqual(result.last?.id, "10")
        let tied = [episode("b", title: "Same"), episode("a", title: "Same")]
        XCTAssertEqual(PodcastMediaSearch.matches(tied, query: nil).map(\.id), ["a", "b"])
    }
    private func show(_ id: String, title: String) -> SearchContent {
        SearchContent(id: id, feedURL: "https://example.com/\(id)", guid: nil,
            title: title, showName: "", summary: "", date: nil, duration: nil)
    }

    func testLatestRequestReturnsShowEvenWithoutGloballyIndexedEpisodes() {
        let doubleTap = show("double-tap", title: "Double Tap")
        let unrelated = episode("news", title: "The Latest Episode of Double Tap", show: "Other Show")
        for phrase in ["play the latest episode of Double Tap in Earshot",
                       "the latest episode of Double Tap", "latest episode from Double Tap",
                       "newest episode of Double Tap", "Double Tap latest episode"] {
            XCTAssertEqual(PodcastMediaSearch.audioMatches([doubleTap], query: phrase), [doubleTap])
        }
        XCTAssertEqual(PodcastMediaSearch.audioMatches([doubleTap, unrelated], query: "Double Tap"), [doubleTap])
        XCTAssertTrue(PodcastMediaSearch.audioMatches([doubleTap], query: "latest episode of Missing Show").isEmpty)
    }

    func testExactNamesWinAndAmbiguousShowsRemainSeparate() {
        let first = show("one", title: "Double Tap")
        let duplicate = show("two", title: "Double Tap")
        let extended = show("three", title: "Double Tap Weekly")
        XCTAssertEqual(PodcastMediaSearch.shows([extended, duplicate, first], matching: "Double Tap").map(\.id), ["one", "two"])
        let titled = episode("literal", title: "The latest episode of Double Tap")
        XCTAssertEqual(PodcastMediaSearch.audioMatches([first, titled], query: titled.title), [titled])
    }

}
