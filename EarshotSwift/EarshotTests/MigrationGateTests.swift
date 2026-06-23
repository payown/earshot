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
            migrationComplete: true, podcastCount: 0, episodeStateRestored: false, flutterHasData: true
        ))
    }

    func testSelfHealTriggersWhenShowsPresentButStateNotRestored() {
        // Shells imported (podcastCount > 0) but the per-episode overlay never
        // ran or failed: state is still missing, so self-heal fires (#426).
        XCTAssertTrue(MigrationGate.shouldSelfHeal(
            migrationComplete: true, podcastCount: 5, episodeStateRestored: false, flutterHasData: true
        ))
    }

    func testSelfHealDoesNotTriggerWhenStateAlreadyRestored() {
        XCTAssertFalse(MigrationGate.shouldSelfHeal(
            migrationComplete: true, podcastCount: 5, episodeStateRestored: true, flutterHasData: true
        ))
    }

    func testSelfHealDoesNotTriggerWhenNoFlutterData() {
        // No recoverable data on disk: nothing to re-restore, even if state is
        // unrestored and the store is empty.
        XCTAssertFalse(MigrationGate.shouldSelfHeal(
            migrationComplete: true, podcastCount: 0, episodeStateRestored: false, flutterHasData: false
        ))
    }

    func testSelfHealDoesNotTriggerBeforeMigrationComplete() {
        // Not yet migrated: the normal import path handles it, not self-heal.
        XCTAssertFalse(MigrationGate.shouldSelfHeal(
            migrationComplete: false, podcastCount: 0, episodeStateRestored: false, flutterHasData: true
        ))
    }
}
