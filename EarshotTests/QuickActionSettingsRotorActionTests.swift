import XCTest
@testable import Earshot

final class QuickActionSettingsRotorActionTests: XCTestCase {
    func testEnabledActionHasExactlyOneRemoveAndKeepsMoveActions() {
        let actions = QuickActionSettingsRotorActionBuilder.actions(
            state: .enabled,
            index: 1,
            count: 3
        )

        XCTAssertEqual(actions.filter { $0.label == "Remove" }.count, 1)
        XCTAssertEqual(
            actions.map(\.label),
            ["Remove", "Move to top", "Move up", "Move down", "Move to bottom"]
        )
        XCTAssertEqual(Set(actions.map(\.id)).count, actions.count)
        XCTAssertTrue(actions.first?.isDestructive == true)
    }

    func testPlayerTransportActionsUseHorizontalMoveLabels() {
        let actions = QuickActionSettingsRotorActionBuilder.actions(
            state: .enabled,
            index: 1,
            count: 3,
            allowsEmptyEnabled: true,
            moveDirection: .horizontal
        )

        XCTAssertEqual(actions.map(\.label), [
            "Remove", "Move to far left", "Move left", "Move right", "Move to far right"
        ])
    }

    func testAvailableActionHasExactlyOneAdd() {
        let actions = QuickActionSettingsRotorActionBuilder.actions(
            state: .available,
            index: 0,
            count: 4
        )

        XCTAssertEqual(actions.map(\.label), ["Add"])
        XCTAssertEqual(Set(actions.map(\.id)).count, actions.count)
        XCTAssertFalse(actions[0].isDestructive)
    }

    func testSingleEnabledActionCanStillBeRemovedWithoutMoveActions() {
        let actions = QuickActionSettingsRotorActionBuilder.actions(
            state: .enabled,
            index: 0,
            count: 1,
            allowsEmptyEnabled: true
        )

        XCTAssertEqual(actions.map(\.label), ["Remove"])
    }

    func testLastRequiredActionCannotBeRemoved() {
        let actions = QuickActionSettingsRotorActionBuilder.actions(
            state: .enabled,
            index: 0,
            count: 1
        )

        XCTAssertTrue(actions.isEmpty)
    }
}
