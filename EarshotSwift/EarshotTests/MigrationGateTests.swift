import XCTest
@testable import Earshot

final class MigrationGateTests: XCTestCase {

    func testImportRunsOnlyUntilComplete() {
        XCTAssertTrue(MigrationGate.shouldImport(migrationComplete: false))
        XCTAssertFalse(MigrationGate.shouldImport(migrationComplete: true))
    }
}
