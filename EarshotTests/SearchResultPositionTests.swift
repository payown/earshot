import XCTest
@testable import Earshot

/// Tests for ``SearchResultPosition`` — the pure position-in-set and count
/// formatting that gives a VoiceOver user orientation in a long directory result
/// list (#501). Covers the one-based index mapping, the "Following, …" value
/// composition layered onto #499's subscribed state, out-of-range clamping, and
/// singular/plural handling of the settled-result count announcement.
final class SearchResultPositionTests: XCTestCase {

    // MARK: - phrase(index:total:)

    /// Zero-based array index maps to a one-based human position: the first row
    /// (index 0) is "result 1 of 50", not "result 0".
    func testPhraseMapsZeroBasedIndexToOneBased() {
        XCTAssertEqual(SearchResultPosition.phrase(index: 0, total: 50), "result 1 of 50")
        XCTAssertEqual(SearchResultPosition.phrase(index: 3, total: 50), "result 4 of 50")
    }

    /// The last row's one-based position equals the total.
    func testPhraseLastRowEqualsTotal() {
        XCTAssertEqual(SearchResultPosition.phrase(index: 49, total: 50), "result 50 of 50")
    }

    /// A single-result list reads "result 1 of 1".
    func testPhraseSingleResult() {
        XCTAssertEqual(SearchResultPosition.phrase(index: 0, total: 1), "result 1 of 1")
    }

    /// A negative index (e.g. a stale value during a list update) is clamped up to
    /// 1 so VoiceOver never speaks "result 0 of …".
    func testPhraseClampsNegativeIndexToOne() {
        XCTAssertEqual(SearchResultPosition.phrase(index: -5, total: 50), "result 1 of 50")
    }

    /// An index past the end is clamped to the total so VoiceOver never speaks a
    /// position beyond the list length.
    func testPhraseClampsOverflowIndexToTotal() {
        XCTAssertEqual(SearchResultPosition.phrase(index: 99, total: 50), "result 50 of 50")
    }

    /// A non-positive total is floored to 1 so the phrase never reads "of 0" or a
    /// negative count, even if called with an empty set.
    func testPhraseFloorsTotalToOne() {
        XCTAssertEqual(SearchResultPosition.phrase(index: 0, total: 0), "result 1 of 1")
        XCTAssertEqual(SearchResultPosition.phrase(index: 0, total: -3), "result 1 of 1")
    }

    // MARK: - rowValue(subscribed:index:total:)

    /// An un-subscribed row's value is the bare position phrase — no leading
    /// "Following," and never an empty string (which #499 omitted to avoid
    /// VoiceOver dead air; the position phrase keeps it non-empty here).
    func testRowValueUnsubscribedIsPositionOnly() {
        XCTAssertEqual(
            SearchResultPosition.rowValue(subscribed: false, index: 3, total: 50),
            "result 4 of 50"
        )
    }

    /// A subscribed row keeps #499's "Following" state, with the position appended
    /// after it: "Following, result 4 of 50".
    func testRowValueSubscribedPrefixesFollowing() {
        XCTAssertEqual(
            SearchResultPosition.rowValue(subscribed: true, index: 3, total: 50),
            "Following, result 4 of 50"
        )
    }

    /// The value is never empty in either subscription state, so VoiceOver never
    /// speaks an empty value as a dead-air pause.
    func testRowValueNeverEmpty() {
        XCTAssertFalse(SearchResultPosition.rowValue(subscribed: true, index: 0, total: 1).isEmpty)
        XCTAssertFalse(SearchResultPosition.rowValue(subscribed: false, index: 0, total: 1).isEmpty)
    }

    /// The title is not part of the value — the value is position (and optional
    /// state) only, so the row's `accessibilityLabel` (the title) is never buried.
    func testRowValueCarriesNoTitle() {
        let value = SearchResultPosition.rowValue(subscribed: true, index: 0, total: 10)
        XCTAssertEqual(value, "Following, result 1 of 10")
    }

    // MARK: - countAnnouncement(_:)

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
