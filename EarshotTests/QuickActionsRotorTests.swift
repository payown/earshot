import XCTest
@testable import Earshot

/// `QuickActionsRotor.declarationOrder` — the single compensation point for
/// iOS emitting `.accessibilityActions` ViewBuilder children in REVERSE
/// declaration order (#572). Declaring reversed makes VoiceOver announce the
/// user's configured order.
@MainActor
final class QuickActionsRotorTests: XCTestCase {

    func testConfiguredRowDefaultUsesOnlyTheFirstEnabledApplicableAction() {
        XCTAssertEqual(
            ConfiguredRowDefault.action(
                configured: [EpisodeAction.playNow, .markPlayed],
                applicable: [.playNow, .markPlayed]
            ),
            .playNow
        )
        XCTAssertNil(ConfiguredRowDefault.action(
            configured: [EpisodeAction.removeFromInbox, .playNow],
            applicable: [.playNow]
        ), "A later action must not become the default when the first is inapplicable")
        XCTAssertNil(ConfiguredRowDefault.action(
            configured: [EpisodeAction](), applicable: [.playNow]
        ))
    }

    func testConfiguredRowDefaultCoversPodcastAndQueueWithoutActionTypeAllowlist() {
        XCTAssertEqual(ConfiguredRowDefault.action(
            configured: [PodcastAction.toggleAutoQueue, .share],
            applicable: [.toggleAutoQueue, .share]
        ), .toggleAutoQueue)
        XCTAssertNil(ConfiguredRowDefault.action(
            configured: [PodcastAction.toggleInboxInclude, .share],
            applicable: [.share]
        ))
        XCTAssertEqual(ConfiguredRowDefault.action(
            configured: [QueueItemAction.removeFromQueue, .playNow],
            applicable: [.removeFromQueue, .playNow]
        ), .removeFromQueue)
        XCTAssertNil(ConfiguredRowDefault.action(
            configured: [QueueItemAction.moveUp, .playNow],
            applicable: [.playNow]
        ))
    }

    func testPromotedActionLeavesRemainingRotorInSavedOrderWithoutDuplicate() {
        let presentations = EpisodeAction.presentations(
            [.playNow, .markPlayed, .share],
            for: Episode(guid: "rotor-default", title: "Default test", audioURL: "https://example.com/audio.mp3")
        )
        XCTAssertEqual(
            ConfiguredRowDefault.remaining(presentations, promoted: .playNow).map(\.action),
            [.markPlayed, .share]
        )
        XCTAssertEqual(
            ConfiguredRowDefault.remaining(presentations, promoted: nil).map(\.action),
            [.playNow, .markPlayed, .share]
        )
    }

    private func item(_ label: String) -> QuickActionItem {
        QuickActionItem(label: label, isDestructive: false) {}
    }

    func testDeclarationOrderIsExactReverseWhileCompensating() throws {
        // Acceptance criterion: #572 — rotor announces the saved order, so the
        // declaration handed to SwiftUI must be the exact reverse.
        try XCTSkipUnless(
            QuickActionsRotor.compensatesReversedEmission,
            "Compensation was flipped off; the reverse contract no longer applies."
        )
        let actions = ["Play now", "Download", "Share", "Unfollow this podcast"].map(item)
        let declared = QuickActionsRotor.declarationOrder(actions)
        XCTAssertEqual(
            declared.map(\.label),
            ["Unfollow this podcast", "Share", "Download", "Play now"]
        )
    }

    func testDeclarationOrderOfEmptyListIsEmpty() {
        XCTAssertTrue(QuickActionsRotor.declarationOrder([]).isEmpty)
    }

    func testDeclarationOrderOfSingleItemIsUnchanged() {
        let declared = QuickActionsRotor.declarationOrder([item("Play now")])
        XCTAssertEqual(declared.map(\.label), ["Play now"])
    }

    func testDeclarationOrderIsAPermutationEitherWay() {
        // Holds whether or not compensation is on: same items, nothing dropped,
        // nothing duplicated — only order may change.
        let actions = ["A", "B", "C", "D", "E"].map(item)
        let declared = QuickActionsRotor.declarationOrder(actions)
        XCTAssertEqual(Set(declared.map(\.label)), Set(actions.map(\.label)))
        XCTAssertEqual(declared.count, actions.count)
    }

    func testDeclaredFirstIsConfiguredLastSoDefaultTapMustNotUseIt() throws {
        // Guards the scope note on QuickActionsRotor: the default double-tap
        // derivations keep the UN-reversed `actions.first`. If anyone derives
        // the default from the declared array, this documents why that's wrong.
        try XCTSkipUnless(QuickActionsRotor.compensatesReversedEmission)
        let actions = ["Play now", "Share", "Unfollow this podcast"].map(item)
        let declared = QuickActionsRotor.declarationOrder(actions)
        XCTAssertEqual(declared.first?.label, actions.last?.label)
        XCTAssertEqual(actions.first?.label, "Play now")
    }

    func testContextMenuKeepsConfiguredOrderWithoutRotorCompensation() {
        let actions = ["Play now", "Download", "Share"].map(item)
        let declared = QuickActionsContextMenu.declarationOrder(actions)
        XCTAssertEqual(declared.map(\.label), ["Play now", "Download", "Share"])
    }

    func testContextMenuOrderPreservesDestructiveMetadata() {
        let actions = [
            item("Share"),
            QuickActionItem(label: "Unfollow", isDestructive: true) {},
        ]
        let declared = QuickActionsContextMenu.declarationOrder(actions)
        XCTAssertEqual(declared.map(\.isDestructive), [false, true])
    }

    func testPodcastSupplementalActionHasStableValueIdentity() {
        let action = PodcastRowSupplementalAction(
            id: "readFullDescription",
            label: "Read full description"
        )

        XCTAssertEqual(action.id, "readFullDescription")
        XCTAssertEqual(action.label, "Read full description")
        XCTAssertEqual(action, action)
    }

    func testPodcastSupplementalActionIsAppendedBeforeRotorCompensation() throws {
        let configured = [
            DeferredActionPresentation(
                action: PodcastAction.share,
                label: "Share podcast",
                isDestructive: false
            ),
            DeferredActionPresentation(
                action: PodcastAction.unsubscribe,
                label: "Unfollow",
                isDestructive: true
            ),
        ]
        let supplemental = [
            PodcastRowSupplementalAction(
                id: "readFullDescription",
                label: "Read full description"
            ),
        ]
        let declared = QuickActionsRotor.podcastDeclarationOrder(
            configured,
            supplementalActions: supplemental
        )

        if QuickActionsRotor.compensatesReversedEmission {
            XCTAssertEqual(
                declared.map(\.label),
                ["Read full description", "Unfollow", "Share podcast"]
            )
        } else {
            XCTAssertEqual(
                declared.map(\.label),
                ["Share podcast", "Unfollow", "Read full description"]
            )
        }
    }

    func testPodcastDeclarationOrderWithoutSupplementalMatchesExistingOrder() {
        let configured = [
            DeferredActionPresentation(
                action: PodcastAction.share,
                label: "Share podcast",
                isDestructive: false
            ),
            DeferredActionPresentation(
                action: PodcastAction.unsubscribe,
                label: "Unfollow",
                isDestructive: true
            ),
        ]

        let declared = QuickActionsRotor.podcastDeclarationOrder(
            configured,
            supplementalActions: []
        )
        XCTAssertEqual(
            declared.map(\.label),
            QuickActionsRotor.declarationOrder(configured).map(\.label)
        )
    }
}
