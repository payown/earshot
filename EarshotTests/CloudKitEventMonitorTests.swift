import XCTest
@testable import Earshot

@MainActor
final class CloudKitEventMonitorTests: XCTestCase {
    func testMonitorKeepsOnlyItsBoundedNewestEvents() {
        let monitor = CloudKitEventMonitor(capacity: 2)
        let first = snapshot(kind: .setup, second: 1)
        let second = snapshot(kind: .export, second: 2)
        let third = snapshot(kind: .import, second: 3)

        monitor.record(first)
        monitor.record(second)
        monitor.record(third)

        XCTAssertEqual(monitor.events, [second, third])
    }

    func testStartAndStopAreIdempotentWithoutPolling() {
        let center = NotificationCenter()
        let monitor = CloudKitEventMonitor(center: center)
        monitor.start()
        monitor.start()
        monitor.stop()
        monitor.stop()
        XCTAssertTrue(monitor.events.isEmpty)
    }

    private func snapshot(
        kind: CloudKitEventSnapshot.Kind,
        second: TimeInterval
    ) -> CloudKitEventSnapshot {
        CloudKitEventSnapshot(
            identifier: UUID(),
            storeIdentifier: "FutureMirrored",
            kind: kind,
            startDate: Date(timeIntervalSince1970: second),
            endDate: Date(timeIntervalSince1970: second + 1),
            succeeded: true,
            errorDescription: nil
        )
    }
}
