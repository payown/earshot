import XCTest
import Synchronization
@testable import Earshot

@MainActor
final class CloudKitEventMonitorTests: XCTestCase {
    private var defaults: UserDefaults!
    private var defaultsSuiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        defaultsSuiteName = "CloudKitEventMonitorTests.\(UUID())"
        defaults = UserDefaults(suiteName: defaultsSuiteName)!
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defaults = nil
        defaultsSuiteName = nil
        try await super.tearDown()
    }

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
        let refreshCount = Mutex(0)
        let observer = center.addObserver(
            forName: .earshotCloudKitImportDidFinish,
            object: nil,
            queue: nil
        ) { _ in
            refreshCount.withLock { $0 += 1 }
        }
        defer { center.removeObserver(observer) }

        monitor.record(snapshot(kind: .import, second: 1))
        monitor.record(snapshot(kind: .export, second: 2))

        XCTAssertEqual(refreshCount.withLock { $0 }, 1)
    }

    func testUnfinishedOrFailedImportDoesNotPostRefreshNotification() {
        let center = NotificationCenter()
        let monitor = CloudKitEventMonitor(center: center)
        let refreshCount = Mutex(0)
        let observer = center.addObserver(
            forName: .earshotCloudKitImportDidFinish,
            object: nil,
            queue: nil
        ) { _ in
            refreshCount.withLock { $0 += 1 }
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

        XCTAssertEqual(refreshCount.withLock { $0 }, 0)
    }

    func testNewestSuccessfulCompletionPersistsAcrossMonitorRestart() {
        let older = snapshot(kind: .import, second: 10)
        let newer = snapshot(kind: .export, second: 20)
        let monitor = CloudKitEventMonitor(defaults: defaults)

        monitor.record(newer)
        monitor.record(older)

        XCTAssertEqual(
            monitor.lastSuccessfulEventDate,
            Date(timeIntervalSince1970: 21)
        )
        XCTAssertEqual(
            CloudKitEventMonitor(defaults: defaults).lastSuccessfulEventDate,
            Date(timeIntervalSince1970: 21)
        )
    }

    func testFailedAndInFlightEventsDoNotReplaceLastSuccessfulCompletion() {
        let monitor = CloudKitEventMonitor(defaults: defaults)
        monitor.record(snapshot(kind: .setup, second: 10))
        monitor.record(CloudKitEventSnapshot(
            identifier: UUID(),
            storeIdentifier: "FutureMirrored",
            kind: .export,
            startDate: Date(timeIntervalSince1970: 20),
            endDate: nil,
            succeeded: false,
            errorDescription: nil
        ))
        monitor.record(CloudKitEventSnapshot(
            identifier: UUID(),
            storeIdentifier: "FutureMirrored",
            kind: .export,
            startDate: Date(timeIntervalSince1970: 30),
            endDate: Date(timeIntervalSince1970: 31),
            succeeded: false,
            errorDescription: "failed"
        ))

        XCTAssertEqual(
            monitor.lastSuccessfulEventDate,
            Date(timeIntervalSince1970: 11)
        )
    }

    func testAccountChangeClearRemovesPersistedCompletion() {
        let monitor = CloudKitEventMonitor(defaults: defaults)
        monitor.record(snapshot(kind: .import, second: 10))

        monitor.clearLastSuccessfulEventDate()

        XCTAssertNil(monitor.lastSuccessfulEventDate)
        XCTAssertNil(CloudKitEventMonitor(defaults: defaults).lastSuccessfulEventDate)
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
