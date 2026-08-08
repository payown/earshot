import XCTest
@testable import Earshot

final class CloudAccountContinuityTests: XCTestCase {
    func testFirstAccountIsAccepted() {
        XCTAssertEqual(
            CloudAccountContinuityDecision.evaluate(previous: nil, current: "one"),
            .firstAccount
        )
    }

    func testSameAccountIsAccepted() {
        XCTAssertEqual(
            CloudAccountContinuityDecision.evaluate(previous: "one", current: "one"),
            .unchanged
        )
    }

    func testDifferentAccountIsBlockedBeforeProjectionOpens() {
        XCTAssertEqual(
            CloudAccountContinuityDecision.evaluate(previous: "one", current: "two"),
            .changed
        )
    }
}
