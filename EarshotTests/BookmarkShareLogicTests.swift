import XCTest
@testable import Earshot

/// Unit tests for the pure bookmark share-text builder (#372).
final class BookmarkShareLogicTests: XCTestCase {

    func testFullBookmarkWithNoteAndURL() {
        let text = BookmarkShareLogic.shareText(
            episodeTitle: "The Big Episode",
            positionSeconds: 90,
            note: "Great point about owls",
            audioURL: "https://cdn.example.com/audio/ep.mp3"
        )
        XCTAssertEqual(text, """
        The Big Episode
        Bookmarked at 1:30
        Great point about owls
        https://cdn.example.com/audio/ep.mp3
        """)
    }

    func testEmptyNoteIsOmitted() {
        let text = BookmarkShareLogic.shareText(
            episodeTitle: "Show",
            positionSeconds: 65,
            note: "",
            audioURL: "https://x.com/a.mp3"
        )
        XCTAssertEqual(text, """
        Show
        Bookmarked at 1:05
        https://x.com/a.mp3
        """)
    }

    func testWhitespaceOnlyNoteIsOmitted() {
        let text = BookmarkShareLogic.shareText(
            episodeTitle: "Show",
            positionSeconds: 0,
            note: "   \n  ",
            audioURL: "https://x.com/a.mp3"
        )
        XCTAssertEqual(text, """
        Show
        Bookmarked at 0:00
        https://x.com/a.mp3
        """)
    }

    func testZeroPositionFormatsAsClockZero() {
        let text = BookmarkShareLogic.shareText(
            episodeTitle: "Show",
            positionSeconds: 0,
            note: "start",
            audioURL: nil
        )
        XCTAssertEqual(text, """
        Show
        Bookmarked at 0:00
        start
        """)
    }

    func testNegativePositionClampsToZero() {
        let text = BookmarkShareLogic.shareText(
            episodeTitle: "Show",
            positionSeconds: -50,
            note: "",
            audioURL: nil
        )
        XCTAssertEqual(text, """
        Show
        Bookmarked at 0:00
        """)
    }

    func testHourLongPositionUsesHMMSS() {
        let text = BookmarkShareLogic.shareText(
            episodeTitle: "Show",
            positionSeconds: 3725, // 1:02:05
            note: "",
            audioURL: nil
        )
        XCTAssertEqual(text, """
        Show
        Bookmarked at 1:02:05
        """)
    }

    func testNilAudioURLIsOmitted() {
        let text = BookmarkShareLogic.shareText(
            episodeTitle: "Show",
            positionSeconds: 30,
            note: "note",
            audioURL: nil
        )
        XCTAssertEqual(text, """
        Show
        Bookmarked at 0:30
        note
        """)
    }

    func testBlankAudioURLIsOmitted() {
        let text = BookmarkShareLogic.shareText(
            episodeTitle: "Show",
            positionSeconds: 30,
            note: "note",
            audioURL: "   "
        )
        XCTAssertEqual(text, """
        Show
        Bookmarked at 0:30
        note
        """)
    }

    func testBlankTitleFallsBackToBookmark() {
        let text = BookmarkShareLogic.shareText(
            episodeTitle: "   ",
            positionSeconds: 30,
            note: "",
            audioURL: nil
        )
        XCTAssertEqual(text, """
        Bookmark
        Bookmarked at 0:30
        """)
    }

    func testTitleAndNoteAreTrimmed() {
        let text = BookmarkShareLogic.shareText(
            episodeTitle: "  Trimmed Title  ",
            positionSeconds: 30,
            note: "  trimmed note  ",
            audioURL: nil
        )
        XCTAssertEqual(text, """
        Trimmed Title
        Bookmarked at 0:30
        trimmed note
        """)
    }

    func testLongTitleIsPreservedInFull() {
        let longTitle = String(repeating: "A really long episode title ", count: 10)
            .trimmingCharacters(in: .whitespaces)
        let text = BookmarkShareLogic.shareText(
            episodeTitle: longTitle,
            positionSeconds: 30,
            note: "",
            audioURL: nil
        )
        XCTAssertTrue(text.hasPrefix(longTitle))
        XCTAssertTrue(text.contains("Bookmarked at 0:30"))
    }

    func testMinimalBookmarkIsTitleAndTimestampOnly() {
        let text = BookmarkShareLogic.shareText(
            episodeTitle: "Show",
            positionSeconds: 30,
            note: "",
            audioURL: nil
        )
        XCTAssertEqual(text, """
        Show
        Bookmarked at 0:30
        """)
    }
}
