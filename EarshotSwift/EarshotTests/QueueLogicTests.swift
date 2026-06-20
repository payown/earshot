import XCTest
@testable import Earshot

/// Unit tests for the pure queue ordering + grouping rules. No SwiftData, no UI.
/// These operate on plain ordered arrays so the repository can apply the result
/// by reassigning positions 0..N-1 (compaction).
final class QueueLogicTests: XCTestCase {

    // MARK: moveToTop

    func testMoveToTopMovesItemToFront() {
        XCTAssertEqual(QueueLogic.moveToTop([1, 2, 3, 4], 3), [3, 1, 2, 4])
    }

    func testMoveToTopOnFirstItemIsNoOp() {
        XCTAssertEqual(QueueLogic.moveToTop([1, 2, 3], 1), [1, 2, 3])
    }

    func testMoveToTopOnMissingItemIsNoOp() {
        XCTAssertEqual(QueueLogic.moveToTop([1, 2, 3], 9), [1, 2, 3])
    }

    // MARK: moveToBottom

    func testMoveToBottomMovesItemToEnd() {
        XCTAssertEqual(QueueLogic.moveToBottom([1, 2, 3, 4], 2), [1, 3, 4, 2])
    }

    func testMoveToBottomOnLastItemIsNoOp() {
        XCTAssertEqual(QueueLogic.moveToBottom([1, 2, 3], 3), [1, 2, 3])
    }

    // MARK: moveUp / moveDown

    func testMoveUpSwapsWithPreviousNeighbor() {
        XCTAssertEqual(QueueLogic.moveUp([1, 2, 3, 4], 3), [1, 3, 2, 4])
    }

    func testMoveUpOnFirstItemIsNoOp() {
        XCTAssertEqual(QueueLogic.moveUp([1, 2, 3], 1), [1, 2, 3])
    }

    func testMoveDownSwapsWithNextNeighbor() {
        XCTAssertEqual(QueueLogic.moveDown([1, 2, 3, 4], 2), [1, 3, 2, 4])
    }

    func testMoveDownOnLastItemIsNoOp() {
        XCTAssertEqual(QueueLogic.moveDown([1, 2, 3], 3), [1, 2, 3])
    }

    // MARK: move(toIndex:)

    func testMoveToIndexForward() {
        XCTAssertEqual(QueueLogic.move([1, 2, 3, 4], 1, toIndex: 2), [2, 3, 1, 4])
    }

    func testMoveToIndexBackward() {
        XCTAssertEqual(QueueLogic.move([1, 2, 3, 4], 4, toIndex: 0), [4, 1, 2, 3])
    }

    func testMoveToIndexClampsOutOfRange() {
        XCTAssertEqual(QueueLogic.move([1, 2, 3], 1, toIndex: 99), [2, 3, 1])
    }

    // MARK: bringToFront (Play group)

    func testBringToFrontPreservesSubsetOrderAndRemainder() {
        // subset given in [3, 1] order; remainder keeps original relative order.
        XCTAssertEqual(QueueLogic.bringToFront([1, 2, 3, 4, 5], [3, 1]), [3, 1, 2, 4, 5])
    }

    func testBringToFrontIgnoresIdsNotInQueue() {
        XCTAssertEqual(QueueLogic.bringToFront([1, 2, 3], [9, 2]), [2, 1, 3])
    }

    // MARK: grouping by podcast

    func testGroupOrdersByFirstAppearanceAndKeepsQueueOrderWithinGroup() {
        let items: [(id: Int, key: String)] = [
            (1, "A"), (2, "B"), (3, "A"), (4, "C"), (5, "B"),
        ]
        let groups = QueueLogic.group(items)
        XCTAssertEqual(groups, [
            QueueLogic.Group(key: "A", ids: [1, 3]),
            QueueLogic.Group(key: "B", ids: [2, 5]),
            QueueLogic.Group(key: "C", ids: [4]),
        ])
    }

    func testGroupOnEmptyIsEmpty() {
        let items: [(id: Int, key: String)] = []
        XCTAssertTrue(QueueLogic.group(items).isEmpty)
    }

    // MARK: within-group moves

    func testMoveUpWithinGroupSwapsWithPreviousSameGroupItem() {
        // Move id 3 (group A) up: swaps with id 1 (the previous A), not id 2 (B).
        let items: [(id: Int, key: String)] = [(1, "A"), (2, "B"), (3, "A")]
        XCTAssertEqual(QueueLogic.moveUpWithinGroup(items, id: 3), [3, 2, 1])
    }

    func testMoveUpWithinGroupIsNoOpWhenFirstInGroup() {
        let items: [(id: Int, key: String)] = [(1, "A"), (2, "B"), (3, "A")]
        XCTAssertEqual(QueueLogic.moveUpWithinGroup(items, id: 1), [1, 2, 3])
    }

    func testMoveDownWithinGroupSwapsWithNextSameGroupItem() {
        let items: [(id: Int, key: String)] = [(1, "A"), (2, "B"), (3, "A")]
        XCTAssertEqual(QueueLogic.moveDownWithinGroup(items, id: 1), [3, 2, 1])
    }

    func testMoveDownWithinGroupIsNoOpWhenLastInGroup() {
        let items: [(id: Int, key: String)] = [(1, "A"), (2, "B"), (3, "A")]
        XCTAssertEqual(QueueLogic.moveDownWithinGroup(items, id: 3), [1, 2, 3])
    }
}
