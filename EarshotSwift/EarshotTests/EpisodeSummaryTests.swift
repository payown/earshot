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

    func testDecodesHexEntityWithLetterDigits() {
        // #518: hex references for accented letters use a–f digits. é is U+00E9.
        XCTAssertEqual(EpisodeSummary.plainText("caf&#xe9;"), "caf\u{00E9}")
        // Uppercase hex digits decode identically.
        XCTAssertEqual(EpisodeSummary.plainText("caf&#xE9;"), "caf\u{00E9}")
    }

    func testSurrogateRangeNumericEntityKeptVerbatim() {
        // 0xD800 is a valid UInt32 but a UTF-16 surrogate, so Unicode.Scalar
        // returns nil. The shape matches yet can't resolve — keep it verbatim.
        XCTAssertEqual(EpisodeSummary.plainText("a &#xD800; b"), "a &#xD800; b")
    }

    func testNonNumericEntityShapeLeftUntouched() {
        // Tokens that don't match the numeric-reference shape (non-hex letters,
        // empty body) are not entities and must pass through unchanged.
        XCTAssertEqual(EpisodeSummary.plainText("x &#xZZ; y"), "x &#xZZ; y")
        XCTAssertEqual(EpisodeSummary.plainText("&#; here"), "&#; here")
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

    // MARK: paragraphs (#547)

    func testParagraphsSplitsOnParagraphTags() {
        let html = "<p>First paragraph.</p><p>Second paragraph.</p><p>Third.</p>"
        XCTAssertEqual(
            EpisodeSummary.paragraphs(html),
            ["First paragraph.", "Second paragraph.", "Third."]
        )
    }

    func testParagraphsSplitsOnLineBreaks() {
        // <br> variants all count as paragraph boundaries.
        let html = "Line one<br>Line two<br/>Line three<br />Line four"
        XCTAssertEqual(
            EpisodeSummary.paragraphs(html),
            ["Line one", "Line two", "Line three", "Line four"]
        )
    }

    func testParagraphsDropsEmptyChunks() {
        // Consecutive breaks / empty paragraphs must not yield blank elements.
        let html = "<p>Only content.</p><p></p><p>   </p>"
        XCTAssertEqual(EpisodeSummary.paragraphs(html), ["Only content."])
    }

    func testParagraphsStripsInlineTagsAndDecodesEntities() {
        let html = "<p><strong>Bold</strong> &amp; <em>italic</em> &#8217;fun&#8217;</p><p>Next.</p>"
        XCTAssertEqual(
            EpisodeSummary.paragraphs(html),
            ["Bold & italic \u{2019}fun\u{2019}", "Next."]
        )
    }

    func testParagraphsSplitsPlainTextOnNewlines() {
        // A plain-text (no-HTML) description with real newlines still splits.
        let text = "Intro line.\n\nBody line.\nClosing line."
        XCTAssertEqual(
            EpisodeSummary.paragraphs(text),
            ["Intro line.", "Body line.", "Closing line."]
        )
    }

    func testParagraphsSingleBlockReturnsOneElement() {
        // No block boundaries -> one paragraph (still better than nothing, and the
        // caller renders it as a single Text).
        XCTAssertEqual(
            EpisodeSummary.paragraphs("Just one continuous sentence with no breaks."),
            ["Just one continuous sentence with no breaks."]
        )
    }

    func testParagraphsNilAndEmptyReturnEmptyArray() {
        XCTAssertEqual(EpisodeSummary.paragraphs(nil), [])
        XCTAssertEqual(EpisodeSummary.paragraphs(""), [])
    }

    func testParagraphsSplitsOnListAndHeadingTags() {
        let html = "<h2>Topics</h2><ul><li>One</li><li>Two</li></ul>"
        XCTAssertEqual(
            EpisodeSummary.paragraphs(html),
            ["Topics", "One", "Two"]
        )
    }
}
