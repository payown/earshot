import XCTest
@testable import Earshot

final class SearchOPMLTests: XCTestCase {

    // MARK: SearchLogic

    func testMatchesIsCaseInsensitiveContains() {
        XCTAssertTrue(SearchLogic.matches("The Daily Show", query: "daily"))
        XCTAssertFalse(SearchLogic.matches("The Daily Show", query: "weekly"))
    }

    func testEmptyQueryMatchesNothing() {
        XCTAssertFalse(SearchLogic.matches("anything", query: ""))
        XCTAssertFalse(SearchLogic.matches("anything", query: "   "))
    }

    func testFilterReturnsOnlyMatches() {
        let items = ["Swift Talk", "Accidental Tech", "Swift over Coffee"]
        XCTAssertEqual(SearchLogic.filter(items, query: "swift", text: { $0 }),
                       ["Swift Talk", "Swift over Coffee"])
    }

    func testFilterEmptyQueryReturnsEmpty() {
        XCTAssertEqual(SearchLogic.filter(["a", "b"], query: "  ", text: { $0 }), [])
    }

    // MARK: OPML groups (nested folders)

    func testGroupsParsesFlatFeedsAsUngrouped() {
        let opml = """
        <opml><body>
        <outline type="rss" text="A" xmlUrl="https://a.com/feed"/>
        <outline type="rss" text="B" xmlUrl="https://b.com/feed"/>
        </body></opml>
        """
        let groups = OPMLDocument.groups(from: opml)
        XCTAssertEqual(groups.count, 1)
        XCTAssertNil(groups[0].folder)
        XCTAssertEqual(groups[0].feedURLs, ["https://a.com/feed", "https://b.com/feed"])
    }

    func testGroupsMapsNestedOutlineToFolder() {
        let opml = """
        <opml><body>
        <outline text="News">
            <outline type="rss" text="A" xmlUrl="https://a.com/feed"/>
            <outline type="rss" text="B" xmlUrl="https://b.com/feed"/>
        </outline>
        <outline type="rss" text="C" xmlUrl="https://c.com/feed"/>
        </body></opml>
        """
        let groups = OPMLDocument.groups(from: opml)
        let news = groups.first { $0.folder == "News" }
        XCTAssertEqual(news?.feedURLs, ["https://a.com/feed", "https://b.com/feed"])
        let ungrouped = groups.first { $0.folder == nil }
        XCTAssertEqual(ungrouped?.feedURLs, ["https://c.com/feed"])
    }
}
