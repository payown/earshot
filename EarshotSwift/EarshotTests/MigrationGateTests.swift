import XCTest
@testable import Earshot

final class MigrationGateTests: XCTestCase {

    func testImportRunsOnlyUntilComplete() {
        XCTAssertTrue(MigrationGate.shouldImport(migrationComplete: false))
        XCTAssertFalse(MigrationGate.shouldImport(migrationComplete: true))
    }

    // MARK: retry budget (#426)

    func testGiveUpOnlyAfterBudgetExhausted() {
        XCTAssertFalse(MigrationGate.shouldGiveUp(attempts: 1, maxAttempts: 3))
        XCTAssertFalse(MigrationGate.shouldGiveUp(attempts: 2, maxAttempts: 3))
        XCTAssertTrue(MigrationGate.shouldGiveUp(attempts: 3, maxAttempts: 3))
        XCTAssertTrue(MigrationGate.shouldGiveUp(attempts: 4, maxAttempts: 3))
    }

    // MARK: self-heal (#426)

    func testSelfHealTriggersWhenMigratedButStoreEmptyAndFlutterHasData() {
        XCTAssertTrue(MigrationGate.shouldSelfHeal(
            migrationComplete: true, podcastCount: 0, flutterHasData: true
        ))
    }

    func testSelfHealDoesNotTriggerWhenStoreHasData() {
        XCTAssertFalse(MigrationGate.shouldSelfHeal(
            migrationComplete: true, podcastCount: 5, flutterHasData: true
        ))
    }

    func testSelfHealDoesNotTriggerWhenNoFlutterData() {
        XCTAssertFalse(MigrationGate.shouldSelfHeal(
            migrationComplete: true, podcastCount: 0, flutterHasData: false
        ))
    }

    func testSelfHealDoesNotTriggerBeforeMigrationComplete() {
        // Not yet migrated: the normal import path handles it, not self-heal.
        XCTAssertFalse(MigrationGate.shouldSelfHeal(
            migrationComplete: false, podcastCount: 0, flutterHasData: true
        ))
    }
}
