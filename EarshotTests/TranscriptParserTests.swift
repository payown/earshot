import XCTest
@testable import Earshot

/// Tests for the pure ``TranscriptParser`` (#451): one section per format plus
/// malformed-input safety. The parser never throws — malformed input must yield a
/// best-effort (possibly empty) array, never a crash.
final class TranscriptParserTests: XCTestCase {

    // MARK: - WebVTT

    func test_webVTT_dropsHeaderAndCueNumbers_keepsCueText() {
        let raw = """
        WEBVTT

        1
        00:00:00.000 --> 00:00:02.000
        Hello world

        2
        00:00:02.000 --> 00:00:04.000
        Second cue
        """
        let segments = TranscriptParser.parse(raw, as: .webVTT)
        XCTAssertEqual(segments.map(\.text), ["Hello world", "Second cue"])
        XCTAssertEqual(segments.map(\.startSeconds), [0, 2])
        XCTAssertNil(segments.first?.speaker)
    }

    func test_webVTT_voiceSpanSpeaker_extractedAndTagStripped() {
        let raw = """
        WEBVTT

        00:00:00.000 --> 00:00:02.000
        <v Bob>Hello there</v>
        """
        let segments = TranscriptParser.parse(raw, as: .webVTT)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?.speaker, "Bob")
        XCTAssertEqual(segments.first?.text, "Hello there")
    }

    func test_webVTT_classedVoiceSpan_extractsSpeaker() {
        let raw = """
        WEBVTT

        00:00:00.000 --> 00:00:02.000
        <v.loud Alice>Watch out</v>
        """
        let segments = TranscriptParser.parse(raw, as: .webVTT)
        XCTAssertEqual(segments.first?.speaker, "Alice")
        XCTAssertEqual(segments.first?.text, "Watch out")
    }

    func test_webVTT_multiLineCue_mergedIntoOneSegment() {
        let raw = """
        WEBVTT

        00:00:00.000 --> 00:00:03.000
        First line
        second line
        """
        let segments = TranscriptParser.parse(raw, as: .webVTT)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?.text, "First line second line")
    }

    func test_webVTT_entitiesDecodedInCueText() {
        let raw = """
        WEBVTT

        00:00:00.000 --> 00:00:02.000
        Tom &amp; Jerry
        """
        let segments = TranscriptParser.parse(raw, as: .webVTT)
        XCTAssertEqual(segments.first?.text, "Tom & Jerry")
    }

    func test_webVTT_empty_returnsNoSegments() {
        XCTAssertTrue(TranscriptParser.parse("WEBVTT\n\n", as: .webVTT).isEmpty)
    }

    // MARK: - SRT

    func test_srt_dropsIndexAndCommaTimestamp_keepsText() {
        let raw = """
        1
        00:00:01,000 --> 00:00:04,000
        Hello

        2
        00:00:05,000 --> 00:00:07,000
        World
        """
        let segments = TranscriptParser.parse(raw, as: .srt)
        XCTAssertEqual(segments.map(\.text), ["Hello", "World"])
        XCTAssertEqual(segments.map(\.startSeconds), [1, 5])
    }

    func test_srt_colonSpeakerPrefix_extracted() {
        let raw = """
        1
        00:00:01,000 --> 00:00:04,000
        Bob: Hello there
        """
        let segments = TranscriptParser.parse(raw, as: .srt)
        XCTAssertEqual(segments.first?.speaker, "Bob")
        XCTAssertEqual(segments.first?.text, "Hello there")
    }

    /// A URL inside the cue must not be mistaken for a `Speaker:` label because
    /// there is no space after the colon in `https://`.
    func test_srt_urlNotMistakenForSpeaker() {
        let raw = """
        1
        00:00:01,000 --> 00:00:04,000
        Visit https://example.com today
        """
        let segments = TranscriptParser.parse(raw, as: .srt)
        XCTAssertNil(segments.first?.speaker)
        XCTAssertEqual(segments.first?.text, "Visit https://example.com today")
    }

    func test_srt_malformed_noTimingLines_returnsEmpty() {
        // No `-->` timing markers anywhere: nothing is a cue, best-effort empty.
        let raw = "just\nsome\nlines\nwith no timings"
        XCTAssertTrue(TranscriptParser.parse(raw, as: .srt).isEmpty)
    }

    // MARK: - JSON

    func test_json_segmentsWithSpeakerAndBody_parsed() {
        let raw = """
        { "segments": [
          { "speaker": "Alice", "startTime": 0.0, "body": "Hello" },
          { "speaker": "Bob", "startTime": 1.0, "body": "Hi back" }
        ] }
        """
        let segments = TranscriptParser.parse(raw, as: .json)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].speaker, "Alice")
        XCTAssertEqual(segments[0].text, "Hello")
        XCTAssertEqual(segments[0].startSeconds, 0)
        XCTAssertEqual(segments[1].speaker, "Bob")
        XCTAssertEqual(segments[1].text, "Hi back")
        XCTAssertEqual(segments[1].startSeconds, 1)
    }

    func test_json_textKeyFallback_whenNoBody() {
        let raw = """
        { "segments": [ { "speaker": "A", "text": "From text key" } ] }
        """
        let segments = TranscriptParser.parse(raw, as: .json)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?.text, "From text key")
    }

    func test_json_missingAndGarbageKeys_skippedWithoutCrashing() {
        // First entry has neither body nor text (skipped); second is well-formed.
        let raw = """
        { "segments": [
          { "speaker": "A", "startTime": 0 },
          { "body": 42 },
          { "body": "Kept" }
        ] }
        """
        let segments = TranscriptParser.parse(raw, as: .json)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?.text, "Kept")
    }

    func test_json_sameSpeakerConsecutive_coalesced() {
        let raw = """
        { "segments": [
          { "speaker": "A", "body": "Hello" },
          { "speaker": "A", "body": "world" }
        ] }
        """
        let segments = TranscriptParser.parse(raw, as: .json)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?.speaker, "A")
        XCTAssertEqual(segments.first?.text, "Hello world")
    }

    func test_json_differentSpeakers_notCoalesced() {
        let raw = """
        { "segments": [
          { "speaker": "A", "body": "Hello" },
          { "speaker": "B", "body": "world" }
        ] }
        """
        let segments = TranscriptParser.parse(raw, as: .json)
        XCTAssertEqual(segments.count, 2)
    }

    func test_json_malformed_returnsEmpty() {
        XCTAssertTrue(TranscriptParser.parse("this is not json", as: .json).isEmpty)
    }

    func test_json_noSegmentsKey_returnsEmpty() {
        XCTAssertTrue(TranscriptParser.parse("{ \"foo\": 1 }", as: .json).isEmpty)
    }

    func test_json_segmentsNotArray_returnsEmpty() {
        XCTAssertTrue(TranscriptParser.parse("{ \"segments\": \"nope\" }", as: .json).isEmpty)
    }

    // MARK: - HTML

    func test_html_paragraphSegmentation_speakerNil() {
        let raw = "<p>First paragraph</p><p>Second paragraph</p>"
        let segments = TranscriptParser.parse(raw, as: .html)
        XCTAssertEqual(segments.map(\.text), ["First paragraph", "Second paragraph"])
        XCTAssertTrue(segments.allSatisfy { $0.speaker == nil })
    }

    func test_html_entitiesDecoded() {
        let raw = "<p>Tom &amp; Jerry</p>"
        let segments = TranscriptParser.parse(raw, as: .html)
        XCTAssertEqual(segments.first?.text, "Tom & Jerry")
    }

    func test_html_semanticCueTimesStructuredWithoutDeletingSpokenClockText() {
        let raw = """
        <time>0:01</time>
        <p>Meet me at 10:30 tomorrow.</p>
        <time datetime="PT34S">0:34</time>
        <p>Second paragraph.</p>
        <p>Published <time datetime="2026-08-23">August 23</time>.</p>
        """
        let segments = TranscriptParser.parse(raw, as: .html)
        XCTAssertEqual(segments.map(\.text), [
            "Meet me at 10:30 tomorrow.",
            "Second paragraph.",
            "Published August 23."
        ])
        XCTAssertEqual(segments.map(\.startSeconds), [1, 34, nil])
    }

    func test_html_empty_returnsEmpty() {
        XCTAssertTrue(TranscriptParser.parse("", as: .html).isEmpty)
    }

    // MARK: - Plain text

    func test_plainText_blankLineSplit() {
        let raw = "First block.\n\nSecond block."
        let segments = TranscriptParser.parse(raw, as: .plainText)
        XCTAssertEqual(segments.map(\.text), ["First block.", "Second block."])
        XCTAssertTrue(segments.allSatisfy { $0.speaker == nil })
    }

    func test_plainText_intraParagraphNewlinesCollapsed() {
        let raw = "line one\nline two\n\nnext block"
        let segments = TranscriptParser.parse(raw, as: .plainText)
        XCTAssertEqual(segments.map(\.text), ["line one line two", "next block"])
    }

    func test_plainText_whitespaceOnlyLineTreatedAsBlankBoundary() {
        let raw = "a\n \nb"
        let segments = TranscriptParser.parse(raw, as: .plainText)
        XCTAssertEqual(segments.map(\.text), ["a", "b"])
    }

    func test_plainText_empty_returnsEmpty() {
        XCTAssertTrue(TranscriptParser.parse("", as: .plainText).isEmpty)
        XCTAssertTrue(TranscriptParser.parse("   \n\n   ", as: .plainText).isEmpty)
    }
}
