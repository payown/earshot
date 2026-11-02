import XCTest
@testable import Earshot

final class InterruptedLibraryResetScreenTests: XCTestCase {
    @MainActor
    func testRecoveryHeadingAndErrorExplanationsRemainAvailableAsText() {
        let cases: [(InterruptedLibraryResetReason, String)] = [
            (
                .cloudAccountUnavailable,
                "The library reset is waiting for the iCloud account used when it began. Connect to iCloud with that account, then try again."
            ),
            (
                .cloudAccountChanged,
                "The library reset began with a different iCloud account. Switch back to that account, then try again so the reset does not affect the wrong library."
            ),
            (
                .recoveryFailed,
                "The library reset could not finish. Your reset is saved and will be checked again when you retry."
            ),
            (
                .intentUnreadable,
                "Earshot could not read the saved library reset state. Your library has not been opened. Contact support before continuing."
            ),
        ]

        XCTAssertEqual(
            InterruptedLibraryResetScreen.headingAccessibilityIdentifier,
            "interruptedLibraryReset.heading"
        )
        for (reason, expectedMessage) in cases {
            XCTAssertEqual(reason.title, "Library reset needs attention")
            XCTAssertEqual(reason.message, expectedMessage)
        }
    }
}
