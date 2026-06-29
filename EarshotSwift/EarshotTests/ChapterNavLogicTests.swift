import XCTest
@testable import Earshot

/// Unit tests for the pure manual previous/next chapter navigation logic (#508).
final class ChapterNavLogicTests: XCTestCase {

    // MARK: nextIndex

    func testNextNoChaptersIsNil() {
        XCTAssertNil(ChapterNavLogic.nextIndex(currentIndex: nil, count: 0))
        XCTAssertNil(ChapterNavLogic.nextIndex(currentIndex: 0, count: 0))
    }

    func testNextBeforeFirstChapterGoesToFirst() {
        // Position is before the first chapter starts (active index nil).
        XCTAssertEqual(ChapterNavLogic.nextIndex(currentIndex: nil, count: 4), 0)
    }

    func testNextFromMiddleStepsForward() {
        XCTAssertEqual(ChapterNavLogic.nextIndex(currentIndex: 1, count: 4), 2)
    }

    func testNextFromLastIsNilNoOp() {
        XCTAssertNil(ChapterNavLogic.nextIndex(currentIndex: 3, count: 4))
    }

    func testNextSingleChapterIsNil() {
        XCTAssertNil(ChapterNavLogic.nextIndex(currentIndex: 0, count: 1))
    }

    // MARK: previousIndex

    func testPreviousNoChaptersIsNil() {
        XCTAssertNil(ChapterNavLogic.previousIndex(
            currentIndex: nil, count: 0, positionWithinChapter: 0))
        XCTAssertNil(ChapterNavLogic.previousIndex(
            currentIndex: 1, count: 0, positionWithinChapter: 10))
    }

    func testPreviousBeforeFirstChapterGoesToFirst() {
        XCTAssertEqual(ChapterNavLogic.previousIndex(
            currentIndex: nil, count: 4, positionWithinChapter: 0), 0)
    }

    func testPreviousDeepIntoChapterRestartsCurrent() {
        // More than the threshold into chapter 2 -> restart chapter 2.
        XCTAssertEqual(ChapterNavLogic.previousIndex(
            currentIndex: 2, count: 4, positionWithinChapter: 30), 2)
    }

    func testPreviousNearChapterStartGoesToPrior() {
        // Within the threshold of chapter 2's start -> step to chapter 1.
        XCTAssertEqual(ChapterNavLogic.previousIndex(
            currentIndex: 2, count: 4, positionWithinChapter: 1), 1)
    }

    func testPreviousAtFirstChapterWithinThresholdRestartsFirst() {
        // Within the threshold of chapter 0 -> clamp to chapter 0 (restart),
        // never underflow to a negative index.
        XCTAssertEqual(ChapterNavLogic.previousIndex(
            currentIndex: 0, count: 4, positionWithinChapter: 1), 0)
    }

    func testPreviousAtFirstChapterDeepRestartsFirst() {
        XCTAssertEqual(ChapterNavLogic.previousIndex(
            currentIndex: 0, count: 4, positionWithinChapter: 30), 0)
    }

    // MARK: threshold boundary

    func testPreviousExactlyAtThresholdStepsToPrior() {
        // Boundary is exclusive: exactly `threshold` is NOT "more than", so we
        // step to the previous chapter.
        XCTAssertEqual(ChapterNavLogic.previousIndex(
            currentIndex: 2,
            count: 4,
            positionWithinChapter: ChapterNavLogic.previousRestartThreshold), 1)
    }

    func testPreviousJustOverThresholdRestartsCurrent() {
        XCTAssertEqual(ChapterNavLogic.previousIndex(
            currentIndex: 2,
            count: 4,
            positionWithinChapter: ChapterNavLogic.previousRestartThreshold + 0.01), 2)
    }
}
