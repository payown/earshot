import XCTest
@testable import Earshot

/// Unit tests for the Library alphabetical sort. Pure string logic, no SwiftData.
final class LibrarySortTests: XCTestCase {

    // MARK: sortKey — leading-article stripping

    func testStripsLeadingThe() {
        XCTAssertEqual(LibrarySort.sortKey(for: "The Archers"), "Archers")
    }

    func testStripsLeadingA() {
        XCTAssertEqual(LibrarySort.sortKey(for: "A History of Rome"), "History of Rome")
    }

    func testStripsLeadingAn() {
        XCTAssertEqual(LibrarySort.sortKey(for: "An Oral History"), "Oral History")
    }

    func testIsCaseInsensitiveForArticle() {
        XCTAssertEqual(LibrarySort.sortKey(for: "THE Daily"), "Daily")
    }

    func testDoesNotStripArticleInsideWord() {
        // "Theatre" must not become "atre" — only whole leading words match.
        XCTAssertEqual(LibrarySort.sortKey(for: "Theatre Talk"), "Theatre Talk")
        XCTAssertEqual(LibrarySort.sortKey(for: "Anomaly"), "Anomaly")
    }

    func testTrimsWhitespace() {
        XCTAssertEqual(LibrarySort.sortKey(for: "  The   Daily  "), "Daily")
    }

    func testArticleOnlyTitleIsPreserved() {
        // Nothing left after the article — keep the original so it still sorts.
        XCTAssertEqual(LibrarySort.sortKey(for: "The"), "The")
    }

    func testNoArticleUnchanged() {
        XCTAssertEqual(LibrarySort.sortKey(for: "Radiolab"), "Radiolab")
    }

    // MARK: titlesInOrder — full ordering

    func testTheArchersFilesUnderA() {
        // "The Archers" (-> Archers) sorts before "Bananas", after "Apples".
        XCTAssertTrue(LibrarySort.titlesInOrder("The Archers", "Bananas"))
        XCTAssertFalse(LibrarySort.titlesInOrder("The Archers", "Apples"))
    }

    func testCaseInsensitiveOrdering() {
        XCTAssertTrue(LibrarySort.titlesInOrder("apple", "Banana"))
        XCTAssertTrue(LibrarySort.titlesInOrder("Apple", "banana"))
    }

    func testNumbersSortNaturally() {
        // localizedStandardCompare orders 2 before 10, not lexically.
        XCTAssertTrue(LibrarySort.titlesInOrder("Episode 2", "Episode 10"))
    }

    func testSortingAListMatchesExpectedOrder() {
        let input = ["The Daily", "Zürich Stories", "an apple a day", "Radiolab", "99% Invisible"]
        let sorted = input.sorted(by: LibrarySort.titlesInOrder)
        XCTAssertEqual(sorted, ["99% Invisible", "an apple a day", "The Daily", "Radiolab", "Zürich Stories"])
    }

    // MARK: LibrarySortOrder

    func testSortOrderTitles() {
        XCTAssertEqual(LibrarySortOrder.alphabetical.title, "Alphabetical")
        XCTAssertEqual(LibrarySortOrder.lastPublished.title, "Last published")
    }

    func testSortOrderRoundTripsThroughRawValue() {
        for order in LibrarySortOrder.allCases {
            XCTAssertEqual(LibrarySortOrder(rawValue: order.rawValue), order)
        }
    }
}
