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
}
