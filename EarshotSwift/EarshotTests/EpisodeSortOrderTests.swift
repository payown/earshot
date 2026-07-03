import XCTest
@testable import Earshot

/// Unit tests for the pure ``EpisodeSortOrder`` ordering logic (#459).
///
/// Ordering is pure and testable without a model context (mirrors
/// ``EpisodeListFilterTests`` and ``LibrarySortTests``). Covers alphabetical
/// article-stripping reuse, date ascending/descending, undated-last behavior,
/// deterministic tie-breaking, and the label/announcement strings.
@MainActor
final class EpisodeSortOrderTests: XCTestCase {

    // MARK: Fixtures

    /// Reference epoch so date offsets are readable. 2020-01-01T00:00:00Z.
    private static let epoch = Date(timeIntervalSince1970: 1_577_836_800)

    private func makeEpisode(
        _ guid: String,
        title: String,
        daysAfterEpoch: Int? = nil
    ) -> Episode {
        let date = daysAfterEpoch.map {
            Self.epoch.addingTimeInterval(TimeInterval($0) * 86_400)
        }
        return Episode(
            guid: guid,
            title: title,
            audioURL: "https://example.com/\(guid).mp3",
            pubDate: date
        )
    }

    // MARK: title

    func testTitles() {
        XCTAssertEqual(EpisodeSortOrder.alphabetical.title, "Alphabetical")
        XCTAssertEqual(EpisodeSortOrder.latestFirst.title, "Latest first")
        XCTAssertEqual(EpisodeSortOrder.latestLast.title, "Latest last")
    }

    // MARK: announcement

    func testAnnouncementWording() {
        XCTAssertEqual(EpisodeSortOrder.alphabetical.announcement, "Sorted by Alphabetical")
        XCTAssertEqual(EpisodeSortOrder.latestFirst.announcement, "Sorted by Latest first")
        XCTAssertEqual(EpisodeSortOrder.latestLast.announcement, "Sorted by Latest last")
    }

    // MARK: rawValue round-trip

    func testRawValuesRoundTrip() {
        for order in EpisodeSortOrder.allCases {
            XCTAssertEqual(EpisodeSortOrder(rawValue: order.rawValue), order)
        }
    }

    // MARK: alphabetical — reuses LibrarySort (leading articles ignored)

    func testAlphabeticalIgnoresLeadingArticle() {
        // "The Daily" must file under D, so it sorts after "Comedy" and
        // before "Economics" — proving the leading article is stripped the
        // same way the Library list treats it.
        let episodes = [
            makeEpisode("1", title: "Economics"),
            makeEpisode("2", title: "The Daily"),
            makeEpisode("3", title: "Comedy"),
        ]
        let sorted = EpisodeSortOrder.alphabetical.sorted(episodes)
        XCTAssertEqual(sorted.map(\.title), ["Comedy", "The Daily", "Economics"])
    }

    func testAlphabeticalUsesNaturalNumberOrder() {
        // localizedStandardCompare (via LibrarySort) orders 2 before 10.
        let episodes = [
            makeEpisode("1", title: "Episode 10"),
            makeEpisode("2", title: "Episode 2"),
            makeEpisode("3", title: "Episode 1"),
        ]
        let sorted = EpisodeSortOrder.alphabetical.sorted(episodes)
        XCTAssertEqual(sorted.map(\.title), ["Episode 1", "Episode 2", "Episode 10"])
    }

    // MARK: latestFirst — pubDate descending

    func testLatestFirstIsDateDescending() {
        let episodes = [
            makeEpisode("mid", title: "Mid", daysAfterEpoch: 5),
            makeEpisode("old", title: "Old", daysAfterEpoch: 1),
            makeEpisode("new", title: "New", daysAfterEpoch: 10),
        ]
        let sorted = EpisodeSortOrder.latestFirst.sorted(episodes)
        XCTAssertEqual(sorted.map(\.guid), ["new", "mid", "old"])
    }

    // MARK: latestLast — pubDate ascending

    func testLatestLastIsDateAscending() {
        let episodes = [
            makeEpisode("mid", title: "Mid", daysAfterEpoch: 5),
            makeEpisode("old", title: "Old", daysAfterEpoch: 1),
            makeEpisode("new", title: "New", daysAfterEpoch: 10),
        ]
        let sorted = EpisodeSortOrder.latestLast.sorted(episodes)
        XCTAssertEqual(sorted.map(\.guid), ["old", "mid", "new"])
    }

    // MARK: nil pubDate always sorts last, in both directions

    func testNilPubDateSortsLastInLatestFirst() {
        let episodes = [
            makeEpisode("undated", title: "Undated", daysAfterEpoch: nil),
            makeEpisode("new", title: "New", daysAfterEpoch: 10),
            makeEpisode("old", title: "Old", daysAfterEpoch: 1),
        ]
        let sorted = EpisodeSortOrder.latestFirst.sorted(episodes)
        XCTAssertEqual(sorted.map(\.guid), ["new", "old", "undated"])
        XCTAssertEqual(sorted.last?.guid, "undated")
    }

    func testNilPubDateSortsLastInLatestLast() {
        // Even in ascending order, an undated episode must NOT jump to the top.
        let episodes = [
            makeEpisode("undated", title: "Undated", daysAfterEpoch: nil),
            makeEpisode("new", title: "New", daysAfterEpoch: 10),
            makeEpisode("old", title: "Old", daysAfterEpoch: 1),
        ]
        let sorted = EpisodeSortOrder.latestLast.sorted(episodes)
        XCTAssertEqual(sorted.map(\.guid), ["old", "new", "undated"])
        XCTAssertEqual(sorted.last?.guid, "undated")
    }

    func testMultipleNilPubDatesOrderAlphabeticallyAtEnd() {
        // Two undated episodes both sort last, tie-broken by article-aware title.
        let episodes = [
            makeEpisode("z", title: "The Beta", daysAfterEpoch: nil),
            makeEpisode("dated", title: "Dated", daysAfterEpoch: 3),
            makeEpisode("a", title: "Alpha", daysAfterEpoch: nil),
        ]
        let sorted = EpisodeSortOrder.latestFirst.sorted(episodes)
        // Dated first, then the two undated in article-aware alpha order
        // ("Alpha" before "The Beta" -> Beta).
        XCTAssertEqual(sorted.map(\.guid), ["dated", "a", "z"])
    }

    // MARK: equal pubDate ties break alphabetically (deterministic)

    func testEqualDatesTieBreakAlphabeticallyLatestFirst() {
        let episodes = [
            makeEpisode("charlie", title: "Charlie", daysAfterEpoch: 5),
            makeEpisode("alpha", title: "Alpha", daysAfterEpoch: 5),
            makeEpisode("bravo", title: "Bravo", daysAfterEpoch: 5),
        ]
        let sorted = EpisodeSortOrder.latestFirst.sorted(episodes)
        XCTAssertEqual(sorted.map(\.title), ["Alpha", "Bravo", "Charlie"])
    }

    func testEqualDatesTieBreakAlphabeticallyLatestLast() {
        // Same tie-break regardless of direction — deterministic ordering.
        let episodes = [
            makeEpisode("charlie", title: "Charlie", daysAfterEpoch: 5),
            makeEpisode("alpha", title: "Alpha", daysAfterEpoch: 5),
            makeEpisode("bravo", title: "Bravo", daysAfterEpoch: 5),
        ]
        let sorted = EpisodeSortOrder.latestLast.sorted(episodes)
        XCTAssertEqual(sorted.map(\.title), ["Alpha", "Bravo", "Charlie"])
    }

    func testEqualDateTieBreakIgnoresLeadingArticle() {
        // Tie-break reuses LibrarySort, so "The Apple" files under A.
        let episodes = [
            makeEpisode("banana", title: "Banana", daysAfterEpoch: 7),
            makeEpisode("apple", title: "The Apple", daysAfterEpoch: 7),
        ]
        let sorted = EpisodeSortOrder.latestFirst.sorted(episodes)
        XCTAssertEqual(sorted.map(\.guid), ["apple", "banana"])
    }

    // MARK: empty input

    func testEmptyListStaysEmpty() {
        for order in EpisodeSortOrder.allCases {
            XCTAssertTrue(order.sorted([]).isEmpty)
        }
    }
}
