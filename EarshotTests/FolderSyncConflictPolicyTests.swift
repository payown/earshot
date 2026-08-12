import XCTest
@testable import Earshot

final class FolderSyncConflictPolicyTests: XCTestCase {
    func testAcyclicHierarchyIsUnchanged() {
        let input: [String: String?] = ["a": nil, "b": "a", "c": "b"]
        XCTAssertEqual(
            FolderSyncConflictPolicy.repairCycles(in: input),
            FolderParentRepair(parents: input, detachedFolderIDs: [])
        )
    }

    func testCycleDetachesLexicographicallyGreatestFolder() {
        let result = FolderSyncConflictPolicy.repairCycles(
            in: ["a": "b", "b": "c", "c": "a"]
        )
        XCTAssertEqual(result.detachedFolderIDs, ["c"])
        XCTAssertNil(result.parents["c"]!)
        XCTAssertEqual(result.parents["a"]!, "b")
        XCTAssertEqual(result.parents["b"]!, "c")
    }

    func testMultipleCyclesConvergeDeterministically() {
        let result = FolderSyncConflictPolicy.repairCycles(
            in: ["a": "b", "b": "a", "x": "y", "y": "x"]
        )
        XCTAssertEqual(result.detachedFolderIDs, ["b", "y"])
    }
}
