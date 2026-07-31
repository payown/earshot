import XCTest
@testable import Earshot

final class OptionStepLogicTests: XCTestCase {

    func testLowBoundIncrementMovesUp() {
        XCTAssertEqual(OptionStepLogic.steppedIndex(count: 5, current: 0, delta: 1), 1)
    }

    func testHighBoundIncrementIsNoOp() {
        XCTAssertEqual(OptionStepLogic.steppedIndex(count: 5, current: 4, delta: 1), 4)
    }

    func testLowBoundDecrementIsNoOp() {
        XCTAssertEqual(OptionStepLogic.steppedIndex(count: 5, current: 0, delta: -1), 0)
    }

    func testMidRangeStepsByOne() {
        XCTAssertEqual(OptionStepLogic.steppedIndex(count: 5, current: 2, delta: 1), 3)
        XCTAssertEqual(OptionStepLogic.steppedIndex(count: 5, current: 2, delta: -1), 1)
    }

    func testSingleOptionStaysPut() {
        XCTAssertEqual(OptionStepLogic.steppedIndex(count: 1, current: 0, delta: 1), 0)
        XCTAssertEqual(OptionStepLogic.steppedIndex(count: 1, current: 0, delta: -1), 0)
    }

    func testEmptyOptionsReturnsZero() {
        XCTAssertEqual(OptionStepLogic.steppedIndex(count: 0, current: 0, delta: 1), 0)
    }

    func testOutOfRangeCurrentIsClampedFirst() {
        // current beyond the end: clamp to last, then a decrement steps back one.
        XCTAssertEqual(OptionStepLogic.steppedIndex(count: 5, current: 99, delta: -1), 3)
        // negative current: clamp to 0, then an increment steps to 1.
        XCTAssertEqual(OptionStepLogic.steppedIndex(count: 5, current: -3, delta: 1), 1)
    }
}
