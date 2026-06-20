import XCTest
@testable import Earshot

final class MigrationGateTests: XCTestCase {

    func testPromptsOnlyAfterOnboardingAndWhenNotComplete() {
        XCTAssertTrue(MigrationGate.shouldPrompt(onboardingComplete: true, migrationComplete: false))
        XCTAssertFalse(MigrationGate.shouldPrompt(onboardingComplete: false, migrationComplete: false))
        XCTAssertFalse(MigrationGate.shouldPrompt(onboardingComplete: true, migrationComplete: true))
        XCTAssertFalse(MigrationGate.shouldPrompt(onboardingComplete: false, migrationComplete: true))
    }

    func testRemindLaterDisappearsAfterCap() {
        XCTAssertTrue(MigrationGate.canRemindLater(reminderCount: 0))
        XCTAssertTrue(MigrationGate.canRemindLater(reminderCount: 2))
        XCTAssertFalse(MigrationGate.canRemindLater(reminderCount: 3))
        XCTAssertFalse(MigrationGate.canRemindLater(reminderCount: 4))
    }
}
