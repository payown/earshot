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

    func testLastCompletedTextCoversUnavailableEmptyAndDatedStates() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(
            CloudSyncStatusPresentation.lastCompleted(
                availability: .signedOut,
                date: date
            ),
            "Unavailable"
        )
        XCTAssertEqual(
            CloudSyncStatusPresentation.lastCompleted(
                availability: .available,
                date: nil
            ),
            "Not yet recorded"
        )
        XCTAssertEqual(
            CloudSyncStatusPresentation.lastCompleted(
                availability: .available,
                date: date
            ),
            date.formatted(date: .abbreviated, time: .shortened)
        )
    }

    func testRoutineSuccessfulAndInFlightEventsRemainSilent() {
        let successful = event(endDate: Date(), succeeded: true)
        let inFlight = event(endDate: nil, succeeded: false)

        XCTAssertNil(CloudSyncAnnouncement.eventFailure(previous: nil, current: successful))
        XCTAssertNil(CloudSyncAnnouncement.eventFailure(previous: successful, current: inFlight))
        XCTAssertNil(CloudSyncAnnouncement.availabilityFailure(
            previous: .checking,
            current: .available
        ))
    }

    func testCompletedFailureIsAnnouncedOnlyOncePerEvent() {
        let failed = event(endDate: Date(), succeeded: false)

        XCTAssertEqual(
            CloudSyncAnnouncement.eventFailure(previous: nil, current: failed),
            "iCloud sync needs attention. Your local changes remain saved and Earshot will try again."
        )
        XCTAssertNil(CloudSyncAnnouncement.eventFailure(previous: failed, current: failed))
    }

    func testEveryPersistentAvailabilityFailureHasOneTimeMessage() {
        let failures: [(CloudSyncAvailability, String)] = [
            (.signedOut, "iCloud is signed out. Your local library remains available."),
            (.restricted, "iCloud access is restricted. Your local library remains available."),
            (.temporarilyUnavailable, "iCloud is temporarily unavailable. Your local changes remain saved and Earshot will try again."),
        ]
        for (availability, message) in failures {
            XCTAssertEqual(
                CloudSyncAnnouncement.availabilityFailure(
                    previous: .available,
                    current: availability
                ),
                message
            )
            XCTAssertNil(CloudSyncAnnouncement.availabilityFailure(
                previous: availability,
                current: availability
            ))
        }
    }

    func testAccountConnectionResultIsExplicitForSuccessAndFailure() {
        XCTAssertEqual(
            CloudSyncAnnouncement.accountConnectionResult(availability: .available),
            "Connected to the current iCloud account"
        )
        XCTAssertEqual(
            CloudSyncAnnouncement.accountConnectionResult(
                availability: .temporarilyUnavailable
            ),
            "Couldn't connect to the current iCloud account. Your local library remains available."
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
