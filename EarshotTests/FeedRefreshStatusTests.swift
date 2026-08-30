import SwiftData
import XCTest
@testable import Earshot

@MainActor
final class FeedRefreshStatusTests: XCTestCase {
    func testRefreshCompletionHapticPlanIsExactlyTwoShortLightTaps() {
        let expected = RefreshCompletionHapticPlan(
            style: .light,
            impactCount: 2,
            spacingMilliseconds: 120
        )

        for trigger in [
            FeedRefreshTrigger.manualToolbar,
            .manualPullToRefresh,
            .coldLaunch,
            .foreground,
        ] {
            XCTAssertEqual(
                RefreshCompletionHaptics.plan(
                    trigger: trigger,
                    succeeded: true,
                    applicationIsActive: true,
                    enabled: true
                ),
                expected
            )
        }
    }

    func testRefreshCompletionHapticIsSilentForFailureBackgroundAndInactiveApp() {
        XCTAssertNil(RefreshCompletionHaptics.plan(
            trigger: .manualToolbar,
            succeeded: false,
            applicationIsActive: true,
            enabled: true
        ))
        XCTAssertNil(RefreshCompletionHaptics.plan(
            trigger: .backgroundTask,
            succeeded: true,
            applicationIsActive: true,
            enabled: true
        ))
        XCTAssertNil(RefreshCompletionHaptics.plan(
            trigger: .unspecified,
            succeeded: true,
            applicationIsActive: true,
            enabled: true
        ))
        XCTAssertNil(RefreshCompletionHaptics.plan(
            trigger: .foreground,
            succeeded: true,
            applicationIsActive: false,
            enabled: true
        ))
        XCTAssertNil(RefreshCompletionHaptics.plan(
            trigger: .manualPullToRefresh,
            succeeded: true,
            applicationIsActive: true,
            enabled: false
        ))
    }

    func testPlaybackStartHapticIsOneRoundedPulseWithFallback() {
        let custom = PlaybackStartHaptics.plan(
            enabled: true,
            applicationIsActive: true,
            supportsCustomHaptics: true
        )
        XCTAssertEqual(custom?.mode, .customMechanicalPress)
        XCTAssertEqual(custom?.totalDurationMilliseconds, 210)
        XCTAssertEqual(custom?.pressIntensity, 0.95)
        XCTAssertEqual(custom?.pressSharpness, 0.38)
        XCTAssertEqual(custom?.tailStartMilliseconds, 10)
        XCTAssertEqual(custom?.tailDurationMilliseconds, 200)
        XCTAssertEqual(custom?.tailIntensity, 0.46)
        XCTAssertEqual(custom?.tailSharpness, 0.02)
        XCTAssertEqual(custom?.tailDecay, 0.52)
        XCTAssertEqual(
            (custom?.tailStartMilliseconds ?? 0) + (custom?.tailDurationMilliseconds ?? 0),
            custom?.totalDurationMilliseconds
        )

        XCTAssertEqual(
            PlaybackStartHaptics.plan(
                enabled: true,
                applicationIsActive: true,
                supportsCustomHaptics: false
            )?.mode,
            .heavyImpactFallback
        )
    }

    func testPlaybackStartHapticIsSilentWhenDisabledOrInactive() {
        XCTAssertNil(PlaybackStartHaptics.plan(
            enabled: false,
            applicationIsActive: true,
            supportsCustomHaptics: true
        ))
        XCTAssertNil(PlaybackStartHaptics.plan(
            enabled: true,
            applicationIsActive: false,
            supportsCustomHaptics: true
        ))
    }

    func testPlaybackPauseHapticIsOneShortMechanicalReleaseWithFallback() {
        let custom = PlaybackPauseHaptics.plan(
            enabled: true,
            applicationIsActive: true,
            supportsCustomHaptics: true
        )
        XCTAssertEqual(custom?.mode, .customMechanicalRelease)
        XCTAssertEqual(custom?.totalDurationMilliseconds, 80)
        XCTAssertEqual(custom?.leadDurationMilliseconds, 72)
        XCTAssertEqual(custom?.leadIntensity, 0.18)
        XCTAssertEqual(custom?.leadSharpness, 0.05)
        XCTAssertEqual(custom?.releaseStartMilliseconds, 72)
        XCTAssertEqual(custom?.releaseIntensity, 0.62)
        XCTAssertEqual(custom?.releaseSharpness, 0.9)
        XCTAssertLessThan(
            custom?.totalDurationMilliseconds ?? .max,
            PlaybackStartHaptics.plan(
                enabled: true,
                applicationIsActive: true,
                supportsCustomHaptics: true
            )?.totalDurationMilliseconds ?? 0
        )

        XCTAssertEqual(
            PlaybackPauseHaptics.plan(
                enabled: true,
                applicationIsActive: true,
                supportsCustomHaptics: false
            )?.mode,
            .rigidImpactFallback
        )
    }

    func testPlaybackPauseHapticIsSilentWhenDisabledOrInactive() {
        XCTAssertNil(PlaybackPauseHaptics.plan(
            enabled: false,
            applicationIsActive: true,
            supportsCustomHaptics: true
        ))
        XCTAssertNil(PlaybackPauseHaptics.plan(
            enabled: true,
            applicationIsActive: false,
            supportsCustomHaptics: true
        ))
    }

    func testSnapshotDecodesStoredVersionWithoutFailureDetails() throws {
        let data = Data(#"{"state":"completed","trigger":"backgroundTask","checked":64,"total":64,"newEpisodes":3,"unchangedFeeds":61,"failedFeeds":0}"#.utf8)

        let snapshot = try JSONDecoder().decode(FeedRefreshStatusSnapshot.self, from: data)

        XCTAssertEqual(snapshot.state, .completed)
        XCTAssertEqual(snapshot.checked, 64)
        XCTAssertEqual(snapshot.failureDetails, [])
    }

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

    func testCompletedWithErrorsIsNotInterruptedAndPersistsFeedIdentity() {
        let context = TestStore.freshContext()
        let monitor = FeedRefreshStatusMonitor()
        monitor.configure(context: context)
        let failure = FeedRefreshFailure(
            feedURL: "https://example.com/feed.xml",
            podcastTitle: "Example Show",
            reason: "Could not download or read this feed."
        )
        let finishedAt = Date(timeIntervalSince1970: 400)

        monitor.start(trigger: .backgroundTask, total: 3)
        monitor.finish(SubscriptionRefreshReport(
            notifications: [], attempted: 3, total: 3, succeeded: 2,
            failed: 1, cancelled: false, intendedInsertions: 0,
            durableInsertions: 0, failures: [failure]
        ), now: finishedAt)

        XCTAssertEqual(monitor.snapshot.state, .completedWithErrors)
        XCTAssertEqual(monitor.snapshot.lastCompletedAt, finishedAt)
        XCTAssertEqual(monitor.snapshot.failureDetails, [failure])
        XCTAssertEqual(FeedRefreshStatusStore.load(from: context), monitor.snapshot)
        XCTAssertEqual(
            FeedRefreshStatusPresentation.summary(monitor.snapshot) { _ in "today at 9:42 AM" },
            "Last automatic refresh completed with errors today at 9:42 AM. Checked 3 of 3 podcasts. Found 0 new episodes. 1 feed failed."
        )
    }

    func testCancelledPartialPassRemainsInterrupted() {
        let monitor = FeedRefreshStatusMonitor()
        monitor.finish(SubscriptionRefreshReport(
            notifications: [], attempted: 2, total: 3, succeeded: 2,
            failed: 0, cancelled: true, intendedInsertions: 0,
            durableInsertions: 0
        ))

        XCTAssertEqual(monitor.snapshot.state, .interrupted)
    }

    func testInlineStatusSpeechVisibilityAndEntryFocus() {
        var snapshot = FeedRefreshStatusSnapshot()
        XCTAssertFalse(FeedRefreshInlineStatus.shouldShow(snapshot))
        XCTAssertEqual(FeedRefreshStatusPresentation.entryFocus(snapshot), .heading)

        snapshot.state = .running
        snapshot.checked = 18
        snapshot.total = 64
        snapshot.newEpisodes = 2
        XCTAssertTrue(FeedRefreshInlineStatus.shouldShow(snapshot))
        XCTAssertEqual(FeedRefreshStatusPresentation.entryFocus(snapshot), .refreshStatus)
        XCTAssertEqual(
            FeedRefreshInlineStatus(snapshot: snapshot).spokenText,
            "Refreshing podcasts. 18 of 64 checked. 2 new episodes found."
        )

        snapshot.state = .completedWithErrors
        snapshot.failedFeeds = 2
        XCTAssertTrue(FeedRefreshInlineStatus.shouldShow(snapshot))
        XCTAssertEqual(FeedRefreshStatusPresentation.entryFocus(snapshot), .heading)
        XCTAssertEqual(
            FeedRefreshInlineStatus(snapshot: snapshot).spokenText,
            "Refresh completed with 2 feed errors."
        )
    }

    func testRemovingFailedFeedUpdatesPersistedStatus() {
        let context = TestStore.freshContext()
        let monitor = FeedRefreshStatusMonitor()
        monitor.configure(context: context)
        let first = FeedRefreshFailure(
            feedURL: "HTTPS://EXAMPLE.COM/one.xml",
            podcastTitle: "One",
            reason: "Failed."
        )
        let second = FeedRefreshFailure(
            feedURL: "https://example.com/two.xml",
            podcastTitle: "Two",
            reason: "Failed."
        )
        monitor.finish(SubscriptionRefreshReport(
            notifications: [], attempted: 3, total: 3, succeeded: 1,
            failed: 2, cancelled: false, intendedInsertions: 0,
            durableInsertions: 0, failures: [first, second]
        ))

        monitor.removeFailure(feedURL: "https://example.com/one.xml")

        XCTAssertEqual(monitor.snapshot.failedFeeds, 2)
        XCTAssertEqual(monitor.snapshot.failureDetails, [second])
        XCTAssertEqual(FeedRefreshStatusStore.load(from: context), monitor.snapshot)
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

    func testStoredThrottleSkippedRunningAttemptRestoresCompletedState() throws {
        let context = TestStore.freshContext()
        var stale = FeedRefreshStatusSnapshot()
        stale.state = .running
        stale.trigger = .foreground
        stale.startedAt = Date(timeIntervalSince1970: 200)
        stale.lastSkippedAt = Date(timeIntervalSince1970: 201)
        stale.lastSkippedTrigger = .foreground
        stale.lastCompletedAt = Date(timeIntervalSince1970: 100)
        try FeedRefreshStatusStore.save(stale, in: context)

        let monitor = FeedRefreshStatusMonitor()
        monitor.configure(context: context, now: Date(timeIntervalSince1970: 300))

        XCTAssertEqual(monitor.snapshot.state, .completed)
        XCTAssertNil(monitor.snapshot.startedAt)
        XCTAssertEqual(monitor.snapshot.endedAt, stale.lastCompletedAt)
        XCTAssertFalse(FeedRefreshInlineStatus.shouldShow(monitor.snapshot))
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
