import XCTest
@testable import Earshot

/// Tests for ``TranscriptFormat/detect(url:contentType:)`` (#451): URL extension
/// precedence, Content-Type MIME mapping, charset stripping, and the plain-text
/// default. Pure and side-effect-free, so no networking is involved.
final class TranscriptFormatTests: XCTestCase {

    private func url(_ string: String) -> URL {
        guard let url = URL(string: string) else {
            fatalError("bad test URL: \(string)")
        }
        return url
    }

    // MARK: Extension precedence

    func test_detect_vttExtension_returnsWebVTT() {
        XCTAssertEqual(
            TranscriptFormat.detect(url: url("https://x.com/t.vtt"), contentType: nil),
            .webVTT
        )
    }

    func test_detect_srtExtension_returnsSRT() {
        XCTAssertEqual(
            TranscriptFormat.detect(url: url("https://x.com/t.srt"), contentType: nil),
            .srt
        )
    }

    func test_detect_jsonExtension_returnsJSON() {
        XCTAssertEqual(
            TranscriptFormat.detect(url: url("https://x.com/t.json"), contentType: nil),
            .json
        )
    }

    func test_detect_htmlExtension_returnsHTML() {
        XCTAssertEqual(
            TranscriptFormat.detect(url: url("https://x.com/t.html"), contentType: nil),
            .html
        )
    }

    func test_detect_htmExtension_returnsHTML() {
        XCTAssertEqual(
            TranscriptFormat.detect(url: url("https://x.com/t.htm"), contentType: nil),
            .html
        )
    }

    func test_detect_txtExtension_returnsPlainText() {
        XCTAssertEqual(
            TranscriptFormat.detect(url: url("https://x.com/t.txt"), contentType: nil),
            .plainText
        )
    }

    func test_detect_extensionCaseInsensitive_returnsWebVTT() {
        XCTAssertEqual(
            TranscriptFormat.detect(url: url("https://x.com/T.VTT"), contentType: nil),
            .webVTT
        )
    }

    /// URL extension wins over a conflicting Content-Type.
    func test_detect_extensionBeatsContentType() {
        XCTAssertEqual(
            TranscriptFormat.detect(url: url("https://x.com/t.vtt"), contentType: "application/json"),
            .webVTT
        )
    }

    // MARK: Content-Type MIME mapping (no useful extension)

    func test_detect_textVttContentType_returnsWebVTT() {
        XCTAssertEqual(
            TranscriptFormat.detect(url: url("https://x.com/t"), contentType: "text/vtt"),
            .webVTT
        )
    }

    func test_detect_xSubripContentType_returnsSRT() {
        XCTAssertEqual(
            TranscriptFormat.detect(url: url("https://x.com/t"), contentType: "application/x-subrip"),
            .srt
        )
    }

    func test_detect_applicationSrtContentType_returnsSRT() {
        XCTAssertEqual(
            TranscriptFormat.detect(url: url("https://x.com/t"), contentType: "application/srt"),
            .srt
        )
    }

    func test_detect_applicationJsonContentType_returnsJSON() {
        XCTAssertEqual(
            TranscriptFormat.detect(url: url("https://x.com/t"), contentType: "application/json"),
            .json
        )
    }

    func test_detect_textHtmlContentType_returnsHTML() {
        XCTAssertEqual(
            TranscriptFormat.detect(url: url("https://x.com/t"), contentType: "text/html"),
            .html
        )
    }

    func test_detect_xhtmlContentType_returnsHTML() {
        XCTAssertEqual(
            TranscriptFormat.detect(url: url("https://x.com/t"), contentType: "application/xhtml+xml"),
            .html
        )
    }

    func test_detect_textPlainContentType_returnsPlainText() {
        XCTAssertEqual(
            TranscriptFormat.detect(url: url("https://x.com/t"), contentType: "text/plain"),
            .plainText
        )
    }

    // MARK: Charset parameter stripping

    func test_detect_contentTypeWithCharset_stripsParameterAndMaps() {
        XCTAssertEqual(
            TranscriptFormat.detect(url: url("https://x.com/t"), contentType: "text/vtt; charset=utf-8"),
            .webVTT
        )
    }

    func test_detect_contentTypeCaseAndWhitespaceInsensitive() {
        XCTAssertEqual(
            TranscriptFormat.detect(url: url("https://x.com/t"), contentType: "  TEXT/VTT ; charset=UTF-8"),
            .webVTT
        )
    }

    // MARK: Default

    func test_detect_noExtensionNoContentType_defaultsToPlainText() {
        XCTAssertEqual(
            TranscriptFormat.detect(url: url("https://x.com/transcript"), contentType: nil),
            .plainText
        )
    }

    func test_detect_unknownContentType_defaultsToPlainText() {
        XCTAssertEqual(
            TranscriptFormat.detect(url: url("https://x.com/transcript"), contentType: "application/octet-stream"),
            .plainText
        )
    }
}
