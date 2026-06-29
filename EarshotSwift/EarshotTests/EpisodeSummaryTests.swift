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

    func testPodcastLevelHTMLAndAmpEntity() {
        XCTAssertEqual(
            EpisodeSummary.plainText("<p>Hello &amp; bye</p>"),
            "Hello & bye"
        )
    }

    func testDecodesDecimalNumericEntity() {
        // &#8217; is the right single quotation mark (curly apostrophe).
        XCTAssertEqual(EpisodeSummary.plainText("&#8217;"), "\u{2019}")
    }

    func testDecodesHexNumericEntity() {
        // &#x2019; is the same character expressed in hex.
        XCTAssertEqual(EpisodeSummary.plainText("&#x2019;"), "\u{2019}")
        // Uppercase X form must decode the same way.
        XCTAssertEqual(EpisodeSummary.plainText("&#X2019;"), "\u{2019}")
    }

    func testPlainTextInputPassesThroughTrimmed() {
        // Clean input with no tags or entities is returned trimmed/unchanged.
        XCTAssertEqual(
            EpisodeSummary.plainText("  Just a normal sentence.  "),
            "Just a normal sentence."
        )
    }

    func testNumericEntitiesInSentence() {
        XCTAssertEqual(
            EpisodeSummary.plainText("It&#8217;s a &#x201C;great&#x201D; show"),
            "It\u{2019}s a \u{201C}great\u{201D} show"
        )
    }

    func testMalformedNumericEntityKeptVerbatim() {
        // Matches the numeric-entity shape but 0xFFFFFF is past the valid Unicode
        // range, so it can't resolve — keep the token as-is rather than drop it.
        XCTAssertEqual(EpisodeSummary.plainText("a &#xFFFFFF; b"), "a &#xFFFFFF; b")
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
