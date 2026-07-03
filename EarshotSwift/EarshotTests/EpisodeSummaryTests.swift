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

    // MARK: attributedParagraphs (#565)

    /// The visible plain-text string of an attributed paragraph, ignoring runs.
    private func plainString(_ attributed: AttributedString) -> String {
        String(attributed.characters)
    }

    /// The first run in `attributed` carrying a `.link`, or nil if none.
    private func firstLinkRun(
        in attributed: AttributedString
    ) -> AttributedString.Runs.Run? {
        attributed.runs.first { $0.link != nil }
    }

    /// The visible text of a specific run.
    private func text(
        of run: AttributedString.Runs.Run,
        in attributed: AttributedString
    ) -> String {
        String(attributed[run.range].characters)
    }

    /// The inline presentation intent applied to the run whose visible text is
    /// exactly `text`, or nil if no such run exists.
    private func intent(
        forText text: String,
        in attributed: AttributedString
    ) -> InlinePresentationIntent? {
        for run in attributed.runs where self.text(of: run, in: attributed) == text {
            return run.inlinePresentationIntent
        }
        return nil
    }

    // Acceptance criterion: paragraph count/order matches paragraphs(_:) — the
    // #547 lockstep guarantee — across the full spread of block boundaries.
    func testAttributedParagraphsMatchParagraphsCountAndOrder() {
        let inputs = [
            "<p>First paragraph.</p><p>Second paragraph.</p><p>Third.</p>",
            "Line one<br>Line two<br/>Line three<br />Line four",
            "<div>Div one</div><div>Div two</div>",
            "<ul><li>One</li><li>Two</li></ul>",
            "<h2>Topics</h2><p>Body copy here.</p>",
            "Intro line.\n\nBody line.\nClosing line.",
            "<p>Visit <a href=\"https://example.com\">the site</a> now.</p><p><strong>Bold</strong> tail.</p>",
            "<p>Only content.</p><p></p><p>   </p>",
        ]
        for html in inputs {
            let plain = EpisodeSummary.paragraphs(html)
            let attributed = EpisodeSummary.attributedParagraphs(html)
            XCTAssertEqual(
                attributed.count, plain.count,
                "count mismatch for \(html)"
            )
            XCTAssertEqual(
                attributed.map(plainString), plain,
                "order/text mismatch for \(html)"
            )
        }
    }

    // Acceptance criterion: an <a href="https://…"> produces a run whose .link is
    // that URL and whose visible text is the anchor text.
    func testAttributedHTTPSLinkKeepsURLAndVisibleText() throws {
        let result = EpisodeSummary.attributedParagraphs(
            "<p>See <a href=\"https://example.com\">text</a> here</p>"
        )
        let para = try XCTUnwrap(result.first)
        let run = try XCTUnwrap(firstLinkRun(in: para))
        XCTAssertEqual(run.link, try XCTUnwrap(URL(string: "https://example.com")))
        XCTAssertEqual(text(of: run, in: para), "text")
        XCTAssertEqual(plainString(para), "See text here")
    }

    // Acceptance criterion: mailto links are kept tappable.
    func testAttributedMailtoLinkKept() throws {
        let result = EpisodeSummary.attributedParagraphs(
            "<p>Email <a href=\"mailto:me@example.com\">me</a> today</p>"
        )
        let para = try XCTUnwrap(result.first)
        let run = try XCTUnwrap(firstLinkRun(in: para))
        XCTAssertEqual(run.link, try XCTUnwrap(URL(string: "mailto:me@example.com")))
        XCTAssertEqual(text(of: run, in: para), "me")
    }

    // Acceptance criterion: hrefs entity-encode ampersands; the query must survive.
    func testAttributedLinkDecodesAmpEntityInHref() throws {
        let result = EpisodeSummary.attributedParagraphs(
            "<p><a href=\"https://example.com/?a=1&amp;b=2\">q</a></p>"
        )
        let para = try XCTUnwrap(result.first)
        let run = try XCTUnwrap(firstLinkRun(in: para))
        XCTAssertEqual(
            run.link,
            try XCTUnwrap(URL(string: "https://example.com/?a=1&b=2"))
        )
    }

    // Acceptance criterion: <strong>/<b> apply .stronglyEmphasized and <em>/<i>
    // apply .emphasized inline presentation intent.
    func testAttributedBoldAndItalicApplyIntents() {
        let result = EpisodeSummary.attributedParagraphs(
            "<p><strong>bold</strong> <b>bee</b> <em>ital</em> <i>eye</i> plain</p>"
        )
        XCTAssertEqual(result.count, 1)
        let para = result[0]
        XCTAssertEqual(intent(forText: "bold", in: para)?.contains(.stronglyEmphasized), true)
        XCTAssertEqual(intent(forText: "bee", in: para)?.contains(.stronglyEmphasized), true)
        XCTAssertEqual(intent(forText: "ital", in: para)?.contains(.emphasized), true)
        XCTAssertEqual(intent(forText: "eye", in: para)?.contains(.emphasized), true)
        // Plain text carries no emphasis intent.
        let plainIntent = intent(forText: "plain", in: para)
        XCTAssertNotEqual(plainIntent?.contains(.stronglyEmphasized), true)
        XCTAssertNotEqual(plainIntent?.contains(.emphasized), true)
    }

    // Acceptance criterion: javascript:, an unknown scheme, and a scheme-less
    // relative href each produce NO .link; the anchor text renders plain.
    func testAttributedUnsafeSchemesDropLinkButKeepText() {
        let cases = [
            "<p><a href=\"javascript:alert(1)\">jsx</a></p>",
            "<p><a href=\"ftp://host/file\">ftpx</a></p>",
            "<p><a href=\"/relative/path\">relx</a></p>",
        ]
        let expectedText = ["jsx", "ftpx", "relx"]
        for (html, expected) in zip(cases, expectedText) {
            let result = EpisodeSummary.attributedParagraphs(html)
            let hasLink = result.contains { firstLinkRun(in: $0) != nil }
            XCTAssertFalse(hasLink, "\(html) must not produce a tappable link")
            XCTAssertEqual(
                result.map(plainString).joined(), expected,
                "anchor text must survive as plain text for \(html)"
            )
        }
    }

    // Acceptance criterion: named + numeric entities decode identically to plainText.
    func testAttributedEntitiesDecodeIdenticallyToPlainText() {
        let inputs = [
            "<p>Tom &amp; Jerry</p>",
            "<p>It&#8217;s a &#x201C;great&#x201D; show</p>",
            "<p>&lt;tag&gt; &quot;quote&quot; spaces&nbsp;here</p>",
        ]
        for html in inputs {
            let attributed = EpisodeSummary.attributedParagraphs(html).map(plainString)
            let plain = EpisodeSummary.paragraphs(html)
            XCTAssertEqual(attributed, plain, "entity mismatch for \(html)")
        }
    }

    // Acceptance criterion: malformed HTML (unclosed tags) does not crash and
    // yields non-empty text via the fallback.
    func testAttributedMalformedHTMLDoesNotCrashAndKeepsText() throws {
        let result = EpisodeSummary.attributedParagraphs(
            "<p>Unclosed <strong>bold and <em>ital text</p>"
        )
        let para = try XCTUnwrap(result.first)
        let visible = plainString(para)
        XCTAssertFalse(visible.isEmpty)
        XCTAssertTrue(visible.contains("bold"))
        XCTAssertTrue(visible.contains("ital text"))
    }

    // Acceptance criterion: an <a> with no href yields no .link and renders plain.
    func testAttributedAnchorWithNoHrefRendersPlain() throws {
        let result = EpisodeSummary.attributedParagraphs("<p><a>bare anchor</a> follows</p>")
        let para = try XCTUnwrap(result.first)
        XCTAssertNil(firstLinkRun(in: para))
        XCTAssertEqual(plainString(para), "bare anchor follows")
    }

    // Acceptance criterion: nil/empty input returns an empty array.
    func testAttributedNilAndEmptyReturnEmptyArray() {
        XCTAssertTrue(EpisodeSummary.attributedParagraphs(nil).isEmpty)
        XCTAssertTrue(EpisodeSummary.attributedParagraphs("").isEmpty)
    }
}
