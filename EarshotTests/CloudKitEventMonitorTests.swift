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

    func testSuccessfulCompletedImportPostsRefreshNotificationOnce() {
        let center = NotificationCenter()
        let monitor = CloudKitEventMonitor(center: center)
        var refreshCount = 0
        let observer = center.addObserver(
            forName: .earshotCloudKitImportDidFinish,
            object: nil,
            queue: nil
        ) { _ in
            refreshCount += 1
        }
        defer { center.removeObserver(observer) }

        monitor.record(snapshot(kind: .import, second: 1))
        monitor.record(snapshot(kind: .export, second: 2))

        XCTAssertEqual(refreshCount, 1)
    }

    func testUnfinishedOrFailedImportDoesNotPostRefreshNotification() {
        let center = NotificationCenter()
        let monitor = CloudKitEventMonitor(center: center)
        var refreshCount = 0
        let observer = center.addObserver(
            forName: .earshotCloudKitImportDidFinish,
            object: nil,
            queue: nil
        ) { _ in
            refreshCount += 1
        }
        defer { center.removeObserver(observer) }

        monitor.record(CloudKitEventSnapshot(
            identifier: UUID(),
            storeIdentifier: "FutureMirrored",
            kind: .import,
            startDate: Date(timeIntervalSince1970: 1),
            endDate: nil,
            succeeded: false,
            errorDescription: nil
        ))
        monitor.record(CloudKitEventSnapshot(
            identifier: UUID(),
            storeIdentifier: "FutureMirrored",
            kind: .import,
            startDate: Date(timeIntervalSince1970: 2),
            endDate: Date(timeIntervalSince1970: 3),
            succeeded: false,
            errorDescription: "failed"
        ))

        XCTAssertEqual(refreshCount, 0)
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
