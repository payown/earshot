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
            ],
            metadata: .speakersAndTimestamps
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
            segments: [TranscriptSegment(speaker: nil, text: "Café")],
            metadata: .speakersOnly
        )
        let data = try Data(contentsOf: url)
        XCTAssertEqual(String(data: data, encoding: .utf8)?.contains("Café"), true)
    }

    func testMetadataModesIncludeOnlyTheSelectedPrefixes() {
        let segment = TranscriptSegment(
            speaker: "Alice", text: "Welcome.", startSeconds: 65.8
        )

        let speakersOnly = markdown(segments: [segment], metadata: .speakersOnly)
        XCTAssertTrue(speakersOnly.contains("**Alice:** Welcome."))
        XCTAssertFalse(speakersOnly.contains("[01:05]"))

        let timestampsOnly = markdown(segments: [segment], metadata: .timestampsOnly)
        XCTAssertTrue(timestampsOnly.contains("[01:05] Welcome."))
        XCTAssertFalse(timestampsOnly.contains("**Alice:**"))

        let both = markdown(segments: [segment], metadata: .speakersAndTimestamps)
        XCTAssertTrue(both.contains("[01:05] **Alice:** Welcome."))
    }

    func testSpeakersOnlyOmnySRTExportDoesNotLeakCueTimestampsIntoText() throws {
        let sourceURL = try XCTUnwrap(URL(
            string: "https://api.omny.fm/transcript?format=SubRip&t=1786971983"
        ))
        let raw = """
        1
        00:00:04,200 --> 00:00:06,760
        Speaker 1: Hey, welcome to short stuff.

        2
        00:00:11,200 --> 00:00:13,240
        Speaker 2: Do you know who else is here?
        """
        let format = TranscriptFormat.detect(url: sourceURL, contentType: "text/plain")
        let segments = TranscriptParser.parse(raw, as: format)

        let output = markdown(segments: segments, metadata: .speakersOnly)

        XCTAssertTrue(output.contains("**Speaker 1:** Hey, welcome to short stuff."))
        XCTAssertTrue(output.contains("**Speaker 2:** Do you know who else is here?"))
        XCTAssertFalse(output.contains("00:00:04"))
        XCTAssertFalse(output.contains("-->"))
        XCTAssertFalse(output.contains("\n1\n"))
    }

    func testSegmentsRemainReadableWhenSelectedMetadataIsUnavailable() {
        let segments = [
            TranscriptSegment(speaker: "Alice", text: "Speaker only.", startSeconds: nil),
            TranscriptSegment(speaker: nil, text: "Timestamp only.", startSeconds: 3),
            TranscriptSegment(speaker: nil, text: "Plain text.", startSeconds: nil),
        ]

        for metadata in TranscriptExportMetadata.allCases {
            let output = markdown(segments: segments, metadata: metadata)
            XCTAssertTrue(output.contains("Speaker only."), metadata.title)
            XCTAssertTrue(output.contains("Timestamp only."), metadata.title)
            XCTAssertTrue(output.contains("Plain text."), metadata.title)
        }
    }

    func testViewerAndQuickActionEntryPointsHonorEveryMetadataMode() throws {
        let segments = [
            TranscriptSegment(speaker: "Alice", text: "Welcome.", startSeconds: 1),
        ]

        for metadata in TranscriptExportMetadata.allCases {
            let expected = markdown(segments: segments, metadata: metadata)
            let viewerURL = try TranscriptViewerExport.write(
                podcastTitle: "Show",
                episodeTitle: "Episode",
                publicationDate: nil,
                segments: segments,
                metadata: metadata
            )
            let quickActionURL = try EpisodeQuickActionTranscriptExport.write(
                podcastTitle: "Show",
                episodeTitle: "Episode",
                publicationDate: nil,
                segments: segments,
                metadata: metadata
            )

            XCTAssertEqual(try String(contentsOf: viewerURL, encoding: .utf8), expected)
            XCTAssertEqual(try String(contentsOf: quickActionURL, encoding: .utf8), expected)
        }
    }

    func testMetadataTitlesMatchTheVoiceOverContract() {
        XCTAssertEqual(
            TranscriptExportMetadata.allCases.map(\.title),
            ["Speakers only", "Timestamps only", "Speakers and timestamps"]
        )
    }

    func testLiveTranscriptPresentationMatchesEveryMetadataMode() {
        let segment = TranscriptSegment(
            speaker: "Alice", text: "Welcome.", startSeconds: 65
        )

        XCTAssertEqual(
            TranscriptSegmentPresentation.metadataText(for: segment, mode: .speakersOnly),
            "Alice"
        )
        XCTAssertEqual(
            TranscriptSegmentPresentation.spokenText(for: segment, mode: .speakersOnly),
            "Alice: Welcome."
        )
        XCTAssertEqual(
            TranscriptSegmentPresentation.metadataText(for: segment, mode: .timestampsOnly),
            "[01:05]"
        )
        XCTAssertEqual(
            TranscriptSegmentPresentation.spokenText(for: segment, mode: .timestampsOnly),
            "1 minute, 5 seconds: Welcome."
        )
        XCTAssertEqual(
            TranscriptSegmentPresentation.metadataText(
                for: segment, mode: .speakersAndTimestamps
            ),
            "[01:05] · Alice"
        )
        XCTAssertEqual(
            TranscriptSegmentPresentation.spokenText(
                for: segment, mode: .speakersAndTimestamps
            ),
            "1 minute, 5 seconds, Alice: Welcome."
        )
    }

    func testLiveTranscriptPresentationFallsBackToTextWhenMetadataIsMissing() {
        let segment = TranscriptSegment(speaker: nil, text: "Plain text.")

        for mode in TranscriptExportMetadata.allCases {
            XCTAssertNil(TranscriptSegmentPresentation.metadataText(for: segment, mode: mode))
            XCTAssertEqual(
                TranscriptSegmentPresentation.spokenText(for: segment, mode: mode),
                "Plain text."
            )
        }
    }

    private func markdown(
        segments: [TranscriptSegment],
        metadata: TranscriptExportMetadata
    ) -> String {
        TranscriptMarkdownExporter.markdown(
            podcastTitle: "Show",
            episodeTitle: "Episode",
            publicationDate: nil,
            segments: segments,
            metadata: metadata
        )
    }
}
