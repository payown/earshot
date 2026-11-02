import XCTest
@testable import Earshot

final class TransportActionTests: XCTestCase {
    func testAdditionalIntervalsHaveFullVoiceOverLabelsAndCompactButtonTitles() {
        XCTAssertEqual(TransportAction.skipBack30.label, "Skip back 30 seconds")
        XCTAssertEqual(TransportAction.skipBack30.buttonTitle, "−30s")
        XCTAssertEqual(TransportAction.skipForward120.label, "Skip forward 2 minutes")
        XCTAssertEqual(TransportAction.skipForward120.buttonTitle, "+2m")
        XCTAssertEqual(TransportAction.skipForward300.label, "Skip forward 5 minutes")
        XCTAssertEqual(TransportAction.skipForward300.buttonTitle, "+5m")
    }

    func testPlayerButtonRotorActionsKeepExistingVoiceOverLabels() {
        XCTAssertEqual(PlayerButtonRotorAction.previousChapter.label, "Previous chapter")
        XCTAssertEqual(PlayerButtonRotorAction.nextChapter.label, "Next chapter")
        XCTAssertEqual(PlayerButtonRotorAction.previousInQueue.label, "Previous in Queue")
        XCTAssertEqual(PlayerButtonRotorAction.nextInQueue.label, "Next in Queue")
        XCTAssertEqual(
            PlayerButtonRotorAction.markPlayedAndNextInQueue.label,
            "Mark as played and next in Queue"
        )
    }

    func testVisibilityHidesOnlyThePrimaryIntervalForEachDirection() {
        let actions: [TransportAction] = [
            .skipBack15, .skipBack30, .skipForward30, .skipForward120,
        ]

        XCTAssertEqual(
            TransportActionVisibility.visible(actions, backSeconds: 15, forwardSeconds: 30),
            [.skipBack30, .skipForward120]
        )
        XCTAssertEqual(
            TransportActionVisibility.visible(actions, backSeconds: 10, forwardSeconds: 15),
            actions
        )
    }

    func testAHiddenPrimaryDuplicateReturnsWhenTheDefaultChanges() {
        let actions: [TransportAction] = [.skipForward30, .skipForward120]

        XCTAssertEqual(
            TransportActionVisibility.visible(actions, backSeconds: 15, forwardSeconds: 30),
            [.skipForward120]
        )
        XCTAssertEqual(
            TransportActionVisibility.visible(actions, backSeconds: 15, forwardSeconds: 45),
            actions
        )
    }

    func testVisibleReorderingLeavesHiddenPrimaryDuplicateInItsSlot() {
        let all: [TransportAction] = [
            .skipBack10, .skipBack15, .skipForward30, .skipBack30,
        ]
        let visible: [TransportAction] = [.skipBack10, .skipBack30]

        let result = TransportActionVisibility.movingVisible(
            all, visibleActions: visible, from: IndexSet(integer: 1), to: 0
        )

        XCTAssertEqual(result, [.skipBack30, .skipBack15, .skipForward30, .skipBack10])
    }

    func testAvailableReorderingMovesVisibleActionAroundHiddenPrimaryDefaults() {
        let available: [TransportAction] = [
            .skipBack15, .skipBack30, .skipForward30, .skipForward120,
        ]
        let visibleAvailable = TransportActionVisibility.visible(
            available, backSeconds: 15, forwardSeconds: 30
        )

        let result = TransportActionVisibility.movingVisible(
            available, visibleActions: visibleAvailable, from: IndexSet(integer: 1), to: 0
        )

        XCTAssertEqual(visibleAvailable, [.skipBack30, .skipForward120])
        XCTAssertEqual(result, [.skipBack15, .skipForward120, .skipForward30, .skipBack30])
    }
}
