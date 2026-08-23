import XCTest
@testable import Earshot

final class TranscriptMarkdownExporterTests: XCTestCase {
    func testMarkdownIncludesMetadataTimestampsSpeakersAndPlainSegments() {
        let date = Date(timeIntervalSince1970: 1_725_580_800) // 2024-09-06 UTC
        let markdown = TranscriptMarkdownExporter.markdown(
            podcastTitle: "Access Show",
            episodeTitle: "Braille Today",
            publicationDate: date,
            segments: [
                TranscriptSegment(speaker: "Alice", text: "Welcome.", startSeconds: 1.9),
                TranscriptSegment(speaker: nil, text: "Untimed closing."),
            ]
        )

        XCTAssertTrue(markdown.contains("# Braille Today"))
        XCTAssertTrue(markdown.contains("**Podcast:** Access Show"))
        XCTAssertTrue(markdown.contains("**Published:** 2024-09-06"))
        XCTAssertTrue(markdown.contains("[00:01] **Alice:** Welcome."))
        XCTAssertTrue(markdown.contains("Untimed closing."))
    }

    func testTimestampFormatsMinuteAndHourDurations() {
        XCTAssertEqual(TranscriptMarkdownExporter.timestamp(65.8), "01:05")
        XCTAssertEqual(TranscriptMarkdownExporter.timestamp(3_723), "1:02:03")
    }

    func testFilenameIsSafeMarkdownPathComponent() {
        XCTAssertEqual(
            TranscriptMarkdownExporter.fileName(
                podcastTitle: "Show/Name",
                episodeTitle: "Episode: One?"
            ),
            "Show Name - Episode One.md"
        )
    }

    func testWriteCreatesUTF8MarkdownFile() throws {
        let url = try TranscriptMarkdownExporter.write(
            podcastTitle: nil,
            episodeTitle: "Test",
            publicationDate: nil,
            segments: [TranscriptSegment(speaker: nil, text: "Café")]
        )
        let data = try Data(contentsOf: url)
        XCTAssertEqual(String(data: data, encoding: .utf8)?.contains("Café"), true)
    }
}
