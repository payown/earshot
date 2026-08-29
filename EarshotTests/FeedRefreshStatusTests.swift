import SwiftData
import XCTest
@testable import Earshot

@MainActor
final class FeedRefreshStatusTests: XCTestCase {
    func testNeverRunAndRunningStatusExactSpeech() {
        XCTAssertEqual(
            FeedRefreshStatusPresentation.summary(FeedRefreshStatusSnapshot()) { _ in "today" },
            "Automatic refresh has not run on this device."
        )
        var running = FeedRefreshStatusSnapshot()
        running.state = .running
        running.checked = 18
        running.total = 64
        running.newEpisodes = 2
        XCTAssertEqual(
            FeedRefreshStatusPresentation.summary(running) { _ in "today" },
            "Refreshing podcasts. 18 of 64 checked. 2 new episodes found."
        )
    }

    func testCompletedAndInterruptedStatusExactSpeech() {
        var completed = FeedRefreshStatusSnapshot()
        completed.state = .completed
        completed.trigger = .backgroundTask
        completed.endedAt = Date(timeIntervalSince1970: 1)
        completed.checked = 64
        completed.total = 64
        completed.newEpisodes = 3
        completed.unchangedFeeds = 61
        XCTAssertEqual(
            FeedRefreshStatusPresentation.summary(completed) { _ in "today at 9:42 AM" },
            "Last automatic refresh completed today at 9:42 AM. Checked 64 of 64 podcasts. Found 3 new episodes. 61 feeds were unchanged."
        )

        var interrupted = completed
        interrupted.state = .interrupted
        interrupted.checked = 18
        interrupted.newEpisodes = 2
        XCTAssertEqual(
            FeedRefreshStatusPresentation.summary(interrupted) { _ in "today at 9:42 AM" },
            "Last automatic refresh was interrupted today at 9:42 AM. Checked 18 of 64 podcasts. Found 2 new episodes. Earshot will resume with the least recently checked podcasts."
        )
    }

    func testScheduledStatusExplainsIOSControlsTiming() {
        XCTAssertEqual(
            FeedRefreshStatusPresentation.scheduled(Date(timeIntervalSince1970: 1)) { _ in "10:15 AM" },
            "Next background check requested after 10:15 AM. iOS decides when Earshot runs."
        )
    }

    func testAllRefreshTriggersHaveReachablePresentation() {
        let cases: [(FeedRefreshTrigger, String)] = [
            (.manualToolbar, "Manual"),
            (.manualPullToRefresh, "Manual"),
            (.coldLaunch, "App launch"),
            (.foreground, "App opened"),
            (.backgroundTask, "Background"),
            (.unspecified, "Unknown"),
        ]
        for (trigger, expected) in cases {
            XCTAssertEqual(FeedRefreshStatusPresentation.trigger(trigger), expected)
        }
    }

    func testStaleRunningStatusBecomesInterruptedOnLaunch() throws {
        let context = TestStore.freshContext()
        var running = FeedRefreshStatusSnapshot()
        running.state = .running
        running.checked = 12
        running.total = 64
        try FeedRefreshStatusStore.save(running, in: context)

        let monitor = FeedRefreshStatusMonitor()
        let stoppedAt = Date(timeIntervalSince1970: 200)
        monitor.configure(context: context, now: stoppedAt)

        XCTAssertEqual(monitor.snapshot.state, .interrupted)
        XCTAssertEqual(monitor.snapshot.endedAt, stoppedAt)
        XCTAssertEqual(FeedRefreshStatusStore.load(from: context), monitor.snapshot)
    }

    func testSkippedOpportunityPersistsWithoutReplacingLastRefresh() {
        let context = TestStore.freshContext()
        let monitor = FeedRefreshStatusMonitor()
        monitor.configure(context: context)
        monitor.start(trigger: .backgroundTask, total: 1)
        monitor.finish(SubscriptionRefreshReport(
            notifications: [], attempted: 1, total: 1, succeeded: 1,
            failed: 0, cancelled: false, intendedInsertions: 0,
            durableInsertions: 0
        ))
        let completion = monitor.snapshot.endedAt
        let skippedAt = Date(timeIntervalSince1970: 300)

        monitor.recordSkipped(trigger: .foreground, now: skippedAt)

        XCTAssertEqual(monitor.snapshot.state, .completed)
        XCTAssertEqual(monitor.snapshot.endedAt, completion)
        XCTAssertEqual(monitor.snapshot.lastSkippedAt, skippedAt)
        XCTAssertEqual(monitor.snapshot.lastSkippedTrigger, .foreground)
        XCTAssertEqual(FeedRefreshStatusStore.load(from: context), monitor.snapshot)
    }

    func testStatusEnvelopeIsLocalOnlyAndMalformedDataIsSafe() throws {
        let context = TestStore.freshContext()
        context.insert(LocalAppSetting(key: "feed_refresh_status", value: "not-json"))
        try context.save()

        XCTAssertNil(FeedRefreshStatusStore.load(from: context))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AppSetting>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LocalAppSetting>()), 1)
    }
}
