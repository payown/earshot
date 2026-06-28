import XCTest
@testable import Earshot

/// Unit tests for the shared HTML-strip + brief-summary helper used by both
/// ShowNotesView and the EpisodeRow VoiceOver value (#495).
final class EpisodeSummaryTests: XCTestCase {

    // MARK: plainText

    func testStripsTags() {
        XCTAssertEqual(
            EpisodeSummary.plainText("<p>Hello <b>world</b></p>"),
            "Hello world"
        )
    }

    func testDecodesCommonEntities() {
        XCTAssertEqual(
            EpisodeSummary.plainText("Tom &amp; Jerry &lt;3 &quot;quotes&quot; &#39;n&#39; spaces&nbsp;here"),
            "Tom & Jerry <3 \"quotes\" 'n' spaces here"
        )
    }

    func testCollapsesWhitespaceLeftByTags() {
        XCTAssertEqual(
            EpisodeSummary.plainText("<p>One</p>\n\n<p>Two</p>"),
            "One Two"
        )
    }

    func testNilDescriptionIsEmpty() {
        XCTAssertEqual(EpisodeSummary.plainText(nil), "")
    }

    func testEmptyDescriptionIsEmpty() {
        XCTAssertEqual(EpisodeSummary.plainText(""), "")
    }

    // MARK: shortSummary

    func testShortSummaryNilForNoDescription() {
        XCTAssertNil(EpisodeSummary.shortSummary(nil))
        XCTAssertNil(EpisodeSummary.shortSummary(""))
        XCTAssertNil(EpisodeSummary.shortSummary("<p></p>"))
    }

    func testShortSummaryReturnsFullWhenWithinCap() {
        let html = "<p>A short note.</p>"
        XCTAssertEqual(EpisodeSummary.shortSummary(html), "A short note.")
    }

    func testShortSummaryPrefersSentenceBoundary() {
        let html = "This is the first sentence. " + String(repeating: "tail ", count: 60)
        let summary = EpisodeSummary.shortSummary(html, maxLength: 140)
        XCTAssertEqual(summary, "This is the first sentence.")
    }

    func testShortSummaryTruncatesOnWordBoundaryWithEllipsis() {
        // No early sentence break; a long run of words must truncate cleanly.
        let html = String(repeating: "word ", count: 100)
        let summary = EpisodeSummary.shortSummary(html, maxLength: 40)
        let unwrapped = try? XCTUnwrap(summary)
        XCTAssertNotNil(unwrapped)
        XCTAssertTrue(summary!.hasSuffix("…"))
        XCTAssertFalse(summary!.contains("  "))
        // Cap plus the ellipsis; never wildly over the limit.
        XCTAssertLessThanOrEqual(summary!.count, 41)
    }

    func testShortSummaryCapIsRespected() {
        let html = "<p>" + String(repeating: "alpha beta gamma ", count: 50) + "</p>"
        let summary = EpisodeSummary.shortSummary(html, maxLength: 120)
        XCTAssertNotNil(summary)
        XCTAssertLessThanOrEqual(summary!.count, 121)
    }

    func testShortSummaryStripsTagsBeforeCapping() {
        let html = "<p><strong>Important:</strong> the rest of the note follows here.</p>"
        let summary = EpisodeSummary.shortSummary(html)
        XCTAssertNotNil(summary)
        XCTAssertFalse(summary!.contains("<"))
        XCTAssertTrue(summary!.contains("Important:"))
    }
}
