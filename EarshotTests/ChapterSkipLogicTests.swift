import XCTest
@testable import Earshot

/// Unit tests for the pure auto-skip / fast-forward decision logic (issue #373).
final class ChapterSkipLogicTests: XCTestCase {

    private func makeChapters(_ count: Int) -> [Chapter] {
        (0..<count).map { Chapter(index: $0, startTime: Double($0) * 60, title: "Chapter \($0)") }
    }

    // MARK: decision()

    func testNoChaptersIsNone() {
        XCTAssertEqual(
            ChapterSkipLogic.decision(chapters: [], skipped: [0], activeIndex: 0),
            .none
        )
    }

    func testNilActiveIndexIsNone() {
        let chapters = makeChapters(3)
        XCTAssertEqual(
            ChapterSkipLogic.decision(chapters: chapters, skipped: [0], activeIndex: nil),
            .none
        )
    }

    func testActiveChapterNotSkippedIsNone() {
        let chapters = makeChapters(3)
        XCTAssertEqual(
            ChapterSkipLogic.decision(chapters: chapters, skipped: [2], activeIndex: 1),
            .none
        )
    }

    func testSkippedChapterSeeksToNext() {
        let chapters = makeChapters(3)
        XCTAssertEqual(
            ChapterSkipLogic.decision(chapters: chapters, skipped: [1], activeIndex: 1),
            .seek(targetIndex: 2, startTime: 120, targetTitle: "Chapter 2")
        )
    }

    func testConsecutiveSkippedChaptersJumpPastAllOfThem() {
        let chapters = makeChapters(5)
        // 1, 2, 3 all skipped; active is 1 -> land on 4.
        XCTAssertEqual(
            ChapterSkipLogic.decision(chapters: chapters, skipped: [1, 2, 3], activeIndex: 1),
            .seek(targetIndex: 4, startTime: 240, targetTitle: "Chapter 4")
        )
    }

    func testLastChapterSkippedIsEndOfEpisode() {
        let chapters = makeChapters(3)
        XCTAssertEqual(
            ChapterSkipLogic.decision(chapters: chapters, skipped: [2], activeIndex: 2),
            .endOfEpisode
        )
    }

    func testAllChaptersFromActiveSkippedIsEndOfEpisode() {
        let chapters = makeChapters(4)
        // Active 1, and 1,2,3 skipped -> nothing left to land on.
        XCTAssertEqual(
            ChapterSkipLogic.decision(chapters: chapters, skipped: [1, 2, 3], activeIndex: 1),
            .endOfEpisode
        )
    }

    func testAllChaptersSkippedFromStartIsEndOfEpisode() {
        let chapters = makeChapters(3)
        XCTAssertEqual(
            ChapterSkipLogic.decision(chapters: chapters, skipped: [0, 1, 2], activeIndex: 0),
            .endOfEpisode
        )
    }

    func testActiveIndexOutOfBoundsIsNone() {
        let chapters = makeChapters(2)
        XCTAssertEqual(
            ChapterSkipLogic.decision(chapters: chapters, skipped: [5], activeIndex: 5),
            .none
        )
    }

    // MARK: shouldAutoSkip() — loop guard

    func testShouldAutoSkipFiresForSkippedChapter() {
        XCTAssertTrue(
            ChapterSkipLogic.shouldAutoSkip(activeIndex: 1, skipped: [1], lastAutoSkipFromIndex: nil)
        )
    }

    func testShouldAutoSkipFalseWhenNotSkipped() {
        XCTAssertFalse(
            ChapterSkipLogic.shouldAutoSkip(activeIndex: 1, skipped: [2], lastAutoSkipFromIndex: nil)
        )
    }

    func testShouldAutoSkipFalseWhenNilActive() {
        XCTAssertFalse(
            ChapterSkipLogic.shouldAutoSkip(activeIndex: nil, skipped: [0], lastAutoSkipFromIndex: nil)
        )
    }

    func testLoopGuardBlocksRepeatFromSameChapter() {
        // Already auto-skipped from index 1 this boundary; do not fire again.
        XCTAssertFalse(
            ChapterSkipLogic.shouldAutoSkip(activeIndex: 1, skipped: [1], lastAutoSkipFromIndex: 1)
        )
    }

    func testLoopGuardAllowsNewSkippedChapter() {
        // Last skip was from 1; we've now landed in another skipped chapter 3.
        XCTAssertTrue(
            ChapterSkipLogic.shouldAutoSkip(activeIndex: 3, skipped: [3], lastAutoSkipFromIndex: 1)
        )
    }

    func testFastForwardRateIsFour() {
        XCTAssertEqual(ChapterSkipLogic.fastForwardRate, 4.0)
    }
}
