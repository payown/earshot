import XCTest
import SwiftData
@testable import Earshot

/// Tests for per-podcast settings logic. Since PodcastSettingsView is a SwiftUI
/// view backed directly by the SwiftData model, these tests validate the model
/// field defaults and mutations that the view exposes — no UI host required.
@MainActor
final class PodcastSettingsViewTests: XCTestCase {

    // MARK: Helpers

    private func makePodcast(_ ctx: ModelContext) -> Podcast {
        let p = Podcast(feedURL: "https://test.example/feed.xml", title: "Test Podcast")
        ctx.insert(p)
        return p
    }

    // MARK: Speed override

    func testSpeedOverrideDefaultsToNil() {
        let ctx = TestStore.freshContext()
        let p = makePodcast(ctx)
        XCTAssertNil(p.speedOverride, "Speed override should be nil (use global) by default")
    }

    func testSpeedOverrideCanBeSet() {
        let ctx = TestStore.freshContext()
        let p = makePodcast(ctx)
        p.speedOverride = 1.5
        XCTAssertEqual(p.speedOverride, 1.5)
    }

    func testSpeedOverrideCanBeCleared() {
        let ctx = TestStore.freshContext()
        let p = makePodcast(ctx)
        p.speedOverride = 2.0
        p.speedOverride = nil
        XCTAssertNil(p.speedOverride, "Clearing speed override returns to global setting")
    }

    // MARK: Auto-queue

    func testAutoQueueDefaultsToFalse() {
        let ctx = TestStore.freshContext()
        let p = makePodcast(ctx)
        XCTAssertFalse(p.autoQueue)
    }

    func testAutoQueueCanBeEnabled() {
        let ctx = TestStore.freshContext()
        let p = makePodcast(ctx)
        p.autoQueue = true
        XCTAssertTrue(p.autoQueue)
    }

    func testAutoQueueToggle() {
        let ctx = TestStore.freshContext()
        let p = makePodcast(ctx)
        p.autoQueue = true
        p.autoQueue.toggle()
        XCTAssertFalse(p.autoQueue)
    }

    // MARK: Queue age limit

    func testQueueAgeLimitDefaultsToNil() {
        let ctx = TestStore.freshContext()
        let p = makePodcast(ctx)
        XCTAssertNil(p.queueAgeLimitDays, "Queue age limit should default to nil (no limit)")
    }

    func testQueueAgeLimitCanBeSet() {
        let ctx = TestStore.freshContext()
        let p = makePodcast(ctx)
        p.queueAgeLimitDays = 7
        XCTAssertEqual(p.queueAgeLimitDays, 7)
    }

    func testQueueAgeLimitCanBeCleared() {
        let ctx = TestStore.freshContext()
        let p = makePodcast(ctx)
        p.queueAgeLimitDays = 14
        p.queueAgeLimitDays = nil
        XCTAssertNil(p.queueAgeLimitDays)
    }

    // MARK: Inbox episode max

    func testInboxMaxEpisodesDefaultsToNil() {
        let ctx = TestStore.freshContext()
        let p = makePodcast(ctx)
        XCTAssertNil(p.inboxMaxEpisodes, "Inbox max episodes should default to nil (no limit)")
    }

    func testInboxMaxEpisodesCanBeSet() {
        let ctx = TestStore.freshContext()
        let p = makePodcast(ctx)
        p.inboxMaxEpisodes = 5
        XCTAssertEqual(p.inboxMaxEpisodes, 5)
    }

    // MARK: Inbox age limit (hours)

    func testInboxAgeLimitDefaultsToNil() {
        let ctx = TestStore.freshContext()
        let p = makePodcast(ctx)
        XCTAssertNil(p.inboxAgeLimitHours, "Inbox age limit should default to nil (no limit)")
    }

    func testInboxAgeLimitCanBeSetInHours() {
        let ctx = TestStore.freshContext()
        let p = makePodcast(ctx)
        // 1 day = 24 hours
        p.inboxAgeLimitHours = 24
        XCTAssertEqual(p.inboxAgeLimitHours, 24)
    }

    func testInboxAgeLimitTwoDays() {
        let ctx = TestStore.freshContext()
        let p = makePodcast(ctx)
        p.inboxAgeLimitHours = 48
        XCTAssertEqual(p.inboxAgeLimitHours, 48)
    }

    func testInboxAgeLimitOneWeek() {
        let ctx = TestStore.freshContext()
        let p = makePodcast(ctx)
        p.inboxAgeLimitHours = 168 // 7 * 24
        XCTAssertEqual(p.inboxAgeLimitHours, 168)
    }

    // MARK: Notification toggle

    func testNotificationEnabledDefaultsToNilOff() {
        let ctx = TestStore.freshContext()
        let p = makePodcast(ctx)
        // nil = off (#425); readers coalesce nil to false.
        XCTAssertNil(p.notificationEnabled)
        XCTAssertFalse(p.notificationEnabled ?? false)
    }

    func testNotificationEnabledCanBeToggled() {
        let ctx = TestStore.freshContext()
        let p = makePodcast(ctx)
        p.notificationEnabled = true
        XCTAssertEqual(p.notificationEnabled, true)
        p.notificationEnabled = false
        XCTAssertEqual(p.notificationEnabled, false)
    }

    // MARK: Multiple settings on the same podcast

    func testAllSettingsCanBeConfiguredIndependently() {
        let ctx = TestStore.freshContext()
        let p = makePodcast(ctx)
        p.speedOverride = 1.25
        p.autoQueue = true
        p.queueAgeLimitDays = 3
        p.inboxMaxEpisodes = 10
        p.inboxAgeLimitHours = 48
        p.notificationEnabled = true

        XCTAssertEqual(p.speedOverride, 1.25)
        XCTAssertTrue(p.autoQueue)
        XCTAssertEqual(p.queueAgeLimitDays, 3)
        XCTAssertEqual(p.inboxMaxEpisodes, 10)
        XCTAssertEqual(p.inboxAgeLimitHours, 48)
        XCTAssertEqual(p.notificationEnabled, true)
    }

    func testSettingsArePersisted() throws {
        let ctx = TestStore.freshContext()
        let p = makePodcast(ctx)
        p.speedOverride = 0.75
        p.autoQueue = true
        try ctx.save()

        let fetched = try ctx.fetch(FetchDescriptor<Podcast>()).first
        XCTAssertEqual(fetched?.speedOverride, 0.75)
        XCTAssertTrue(fetched?.autoQueue ?? false)
    }

    // MARK: Speed option list validation

    func testSpeedOptionsIncludeNilForGlobal() {
        // Validate the static option list matches the spec so if it changes we notice.
        let nilOption = PodcastSettingsView.speedOptionsForTesting.first { $0.value == nil }
        XCTAssertNotNil(nilOption, "Speed options must include a nil (Use global) option")
        XCTAssertEqual(nilOption?.label, "Use global")
    }

    func testSpeedOptionsIncludeHalfSpeed() {
        let halfSpeed = PodcastSettingsView.speedOptionsForTesting.first { $0.value == 0.5 }
        XCTAssertNotNil(halfSpeed, "Speed options must include 0.5×")
    }

    func testSpeedOptionsIncludeThreeX() {
        let threeX = PodcastSettingsView.speedOptionsForTesting.first { $0.value == 3.0 }
        XCTAssertNotNil(threeX, "Speed options must include 3.0×")
    }
}
