import XCTest
@testable import Earshot

/// Tests for the once-per-search directory count announcement. Individual rows
/// deliberately omit repeated "result N of M" speech to stay concise.
final class SearchResultPositionTests: XCTestCase {

    /// A multi-result count is pluralised: "50 directory results".
    func testCountAnnouncementPlural() {
        XCTAssertEqual(SearchResultPosition.countAnnouncement(50), "50 directory results")
        XCTAssertEqual(SearchResultPosition.countAnnouncement(2), "2 directory results")
    }

    /// Exactly one result reads in the singular: "1 directory result".
    func testCountAnnouncementSingular() {
        XCTAssertEqual(SearchResultPosition.countAnnouncement(1), "1 directory result")
    }

    /// Zero (the empty case is announced separately, but the helper must still be
    /// well-formed) reads as the plural "0 directory results".
    func testCountAnnouncementZeroIsPlural() {
        XCTAssertEqual(SearchResultPosition.countAnnouncement(0), "0 directory results")
    }
}
