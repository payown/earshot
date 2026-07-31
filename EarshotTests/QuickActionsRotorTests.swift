import XCTest
@testable import Earshot

/// `QuickActionsRotor.declarationOrder` — the single compensation point for
/// iOS emitting `.accessibilityActions` ViewBuilder children in REVERSE
/// declaration order (#572). Declaring reversed makes VoiceOver announce the
/// user's configured order.
@MainActor
final class QuickActionsRotorTests: XCTestCase {

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
}
