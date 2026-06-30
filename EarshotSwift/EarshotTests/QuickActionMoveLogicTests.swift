import XCTest
import SwiftUI
@testable import Earshot

/// Pure-logic coverage for the non-drag (VoiceOver) reorder actions on the Quick
/// Actions settings rows (#523): which moves are offered at each index, the
/// `move(fromOffsets:toOffset:)` destination each maps to, and the resulting
/// position used for the "Moved … to position N of M" announcement.
final class QuickActionMoveLogicTests: XCTestCase {

    func testMiddleRowOffersAllFourMovesInRotorOrder() {
        let targets = QuickActionMoveLogic.targets(index: 2, count: 5)
        XCTAssertEqual(targets.map(\.label),
                       ["Move to top", "Move up", "Move down", "Move to bottom"])
    }

    func testFirstRowSuppressesUpwardMoves() {
        let targets = QuickActionMoveLogic.targets(index: 0, count: 5)
        XCTAssertEqual(targets.map(\.label), ["Move down", "Move to bottom"])
    }

    func testLastRowSuppressesDownwardMoves() {
        let targets = QuickActionMoveLogic.targets(index: 4, count: 5)
        XCTAssertEqual(targets.map(\.label), ["Move to top", "Move up"])
    }

    func testSingleElementOffersNoMoves() {
        XCTAssertTrue(QuickActionMoveLogic.targets(index: 0, count: 1).isEmpty)
    }

    func testEmptyAndOutOfRangeOfferNoMoves() {
        XCTAssertTrue(QuickActionMoveLogic.targets(index: 0, count: 0).isEmpty)
        XCTAssertTrue(QuickActionMoveLogic.targets(index: 5, count: 5).isEmpty)
        XCTAssertTrue(QuickActionMoveLogic.targets(index: -1, count: 5).isEmpty)
    }

    func testDestinationOffsetsMatchArrayMoveSemantics() {
        let targets = QuickActionMoveLogic.targets(index: 2, count: 5)
        let byLabel = Dictionary(uniqueKeysWithValues: targets.map { ($0.label, $0) })
        XCTAssertEqual(byLabel["Move to top"]?.destinationOffset, 0)
        XCTAssertEqual(byLabel["Move up"]?.destinationOffset, 1)
        XCTAssertEqual(byLabel["Move down"]?.destinationOffset, 4)
        XCTAssertEqual(byLabel["Move to bottom"]?.destinationOffset, 5)
    }

    func testResultingIndexMatchesAnnouncedPosition() {
        let targets = QuickActionMoveLogic.targets(index: 2, count: 5)
        let byLabel = Dictionary(uniqueKeysWithValues: targets.map { ($0.label, $0) })
        XCTAssertEqual(byLabel["Move to top"]?.resultingIndex, 0)
        XCTAssertEqual(byLabel["Move up"]?.resultingIndex, 1)
        XCTAssertEqual(byLabel["Move down"]?.resultingIndex, 3)
        XCTAssertEqual(byLabel["Move to bottom"]?.resultingIndex, 4)
    }

    /// The offsets must actually produce the announced order when fed to
    /// `Array.move(fromOffsets:toOffset:)`, the exact call the store makes.
    func testOffsetsDriveArrayMoveToTheResultingIndex() {
        for index in 0..<5 {
            for target in QuickActionMoveLogic.targets(index: index, count: 5) {
                var array = ["a", "b", "c", "d", "e"]
                let moved = array[index]
                array.move(fromOffsets: IndexSet(integer: index), toOffset: target.destinationOffset)
                XCTAssertEqual(array.firstIndex(of: moved), target.resultingIndex,
                               "\(target.label) from index \(index)")
            }
        }
    }
}
