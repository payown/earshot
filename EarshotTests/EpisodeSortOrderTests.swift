import XCTest
@testable import Earshot

/// Unit tests for the pure ``EpisodeSortOrder`` ordering logic (#459).
///
/// Ordering is pure and testable without a model context (mirrors
/// ``EpisodeListFilterTests`` and ``LibrarySortTests``). Covers date
/// ascending/descending, undated-last behavior,
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
        XCTAssertEqual(EpisodeSortOrder.latestFirst.title, "Newest to oldest")
        XCTAssertEqual(EpisodeSortOrder.latestLast.title, "Oldest to newest")
    }

    // MARK: announcement

    func testAnnouncementWording() {
        XCTAssertEqual(EpisodeSortOrder.latestFirst.announcement, "Sorted by Newest to oldest")
        XCTAssertEqual(EpisodeSortOrder.latestLast.announcement, "Sorted by Oldest to newest")
    }

    // MARK: rawValue round-trip

    func testRawValuesRoundTrip() {
        for order in [EpisodeSortOrder.latestFirst, .latestLast] {
            XCTAssertEqual(EpisodeSortOrder(rawValue: order.rawValue), order)
        }
    }

    // MARK: chronological toggle

    func testChronologicalToggleIsReversible() {
        XCTAssertEqual(EpisodeSortOrder.latestFirst.chronologicalToggleTarget, .latestLast)
        XCTAssertEqual(EpisodeSortOrder.latestFirst.chronologicalToggleTitle, "Sort oldest to newest")
        XCTAssertEqual(EpisodeSortOrder.latestLast.chronologicalToggleTarget, .latestFirst)
        XCTAssertEqual(EpisodeSortOrder.latestLast.chronologicalToggleTitle, "Sort newest to oldest")
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
        for order in [EpisodeSortOrder.latestFirst, .latestLast] {
            XCTAssertTrue(order.sorted([]).isEmpty)
        }
    }
}
