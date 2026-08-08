import XCTest
@testable import Earshot

final class CloudSyncStatusPresentationTests: XCTestCase {
    func testEveryAccountAvailabilityHasPlainTextStatus() {
        let expected: [(CloudSyncAvailability, String)] = [
            (.disabled, "Unavailable in this build"),
            (.checking, "Checking iCloud"),
            (.available, "Available"),
            (.signedOut, "Signed out"),
            (.restricted, "Restricted"),
            (.temporarilyUnavailable, "Temporarily unavailable"),
            (.accountChanged, "Paused after account change"),
        ]
        for (availability, status) in expected {
            XCTAssertEqual(
                CloudSyncStatusPresentation.status(
                    availability: availability,
                    event: nil
                ),
                status
            )
            XCTAssertFalse(
                CloudSyncStatusPresentation.explanation(
                    availability: availability,
                    event: nil
                ).isEmpty
            )
        }
    }

    func testInFlightAndFailedEventsHaveDistinctTextStates() {
        let inFlight = event(endDate: nil, succeeded: false)
        XCTAssertEqual(
            CloudSyncStatusPresentation.status(availability: .available, event: inFlight),
            "Syncing"
        )
        let failed = event(endDate: Date(), succeeded: false)
        XCTAssertEqual(
            CloudSyncStatusPresentation.status(availability: .available, event: failed),
            "Needs attention"
        )
        XCTAssertTrue(
            CloudSyncStatusPresentation.explanation(
                availability: .available,
                event: failed
            ).contains("local changes remain saved")
        )
    }

    private func event(endDate: Date?, succeeded: Bool) -> CloudKitEventSnapshot {
        CloudKitEventSnapshot(
            identifier: UUID(),
            storeIdentifier: "store",
            kind: .import,
            startDate: Date(),
            endDate: endDate,
            succeeded: succeeded,
            errorDescription: succeeded ? nil : "offline"
        )
    }
}
