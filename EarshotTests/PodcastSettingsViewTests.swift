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

    // MARK: Intro skip (#456)

    func testIntroSkipSecondsDefaultsToNil() {
        let ctx = TestStore.freshContext()
        let p = makePodcast(ctx)
        XCTAssertNil(p.introSkipSeconds, "Intro skip should default to nil (off) by default")
    }

    func testIntroSkipSecondsCanBeSet() {
        let ctx = TestStore.freshContext()
        let p = makePodcast(ctx)
        p.introSkipSeconds = 30
        XCTAssertEqual(p.introSkipSeconds, 30)
    }

    func testIntroSkipSecondsCanBeCleared() {
        let ctx = TestStore.freshContext()
        let p = makePodcast(ctx)
        p.introSkipSeconds = 45
        p.introSkipSeconds = nil
        XCTAssertNil(p.introSkipSeconds, "Clearing intro skip turns it off")
    }

    func testIntroSkipOptionsIncludeNilForOff() {
        let offOption = PodcastSettingsView.introSkipOptionsForTesting.first { $0.value == nil }
        XCTAssertNotNil(offOption, "Intro skip options must include a nil (Off) option")
        XCTAssertEqual(offOption?.label, "Off")
    }

    func testIntroSkipOptionsIncludeThirtySeconds() {
        let thirty = PodcastSettingsView.introSkipOptionsForTesting.first { $0.value == 30 }
        XCTAssertNotNil(thirty, "Intro skip options must include 30 seconds")
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

    // MARK: Inbox include toggle (#668)
    //
    // Mirrors the Auto-queue section above: PodcastSettingsView now binds a
    // `Toggle("Include in Inbox", isOn: $podcast.inboxIncluded)` the same way
    // it binds `autoQueue`, so this field gets the same default/set/toggle/
    // persist coverage rather than relying solely on the InboxRepository-level
    // membership tests in DownloadsInboxLogicTests.

    func testInboxIncludedDefaultsToFalse() {
        let ctx = TestStore.freshContext()
        let p = makePodcast(ctx)
        XCTAssertFalse(p.inboxIncluded, "a podcast is not opted into the inbox until the user explicitly includes it")
    }

    func testInboxIncludedCanBeEnabled() {
        let ctx = TestStore.freshContext()
        let p = makePodcast(ctx)
        p.inboxIncluded = true
        XCTAssertTrue(p.inboxIncluded)
    }

    func testInboxIncludedToggle() {
        let ctx = TestStore.freshContext()
        let p = makePodcast(ctx)
        p.inboxIncluded = true
        p.inboxIncluded.toggle()
        XCTAssertFalse(p.inboxIncluded, "toggling the settings switch off must flip the model field back")
    }

    func testInboxIncludedIsPersisted() throws {
        let ctx = TestStore.freshContext()
        let p = makePodcast(ctx)
        p.inboxIncluded = true
        try ctx.save()

        let fetched = try ctx.fetch(FetchDescriptor<Podcast>()).first
        XCTAssertEqual(
            fetched?.inboxIncluded, true,
            "the settings Toggle binding must round-trip through the model and survive a save/fetch cycle"
        )
    }

    // MARK: Inbox exclude toggle (#671)
    //
    // Mirrors the Inbox include toggle above: PodcastSettingsView now also binds
    // a `Toggle("Exclude from Inbox", isOn: $podcast.inboxExcluded)` for normal
    // (non-opt-in) mode, the companion gap #668 deliberately left out of scope.
    // Same default/set/toggle/persist coverage.

    func testInboxExcludedDefaultsToFalse() {
        let ctx = TestStore.freshContext()
        let p = makePodcast(ctx)
        XCTAssertFalse(p.inboxExcluded, "a podcast is not excluded from the inbox until the user explicitly excludes it")
    }

    func testInboxExcludedCanBeEnabled() {
        let ctx = TestStore.freshContext()
        let p = makePodcast(ctx)
        p.inboxExcluded = true
        XCTAssertTrue(p.inboxExcluded)
    }

    func testInboxExcludedToggle() {
        let ctx = TestStore.freshContext()
        let p = makePodcast(ctx)
        p.inboxExcluded = true
        p.inboxExcluded.toggle()
        XCTAssertFalse(p.inboxExcluded, "toggling the settings switch off must flip the model field back")
    }

    func testInboxExcludedIsPersisted() throws {
        let ctx = TestStore.freshContext()
        let p = makePodcast(ctx)
        p.inboxExcluded = true
        try ctx.save()

        let fetched = try ctx.fetch(FetchDescriptor<Podcast>()).first
        XCTAssertEqual(
            fetched?.inboxExcluded, true,
            "the settings Toggle binding must round-trip through the model and survive a save/fetch cycle"
        )
    }

    // MARK: Multiple settings on the same podcast

    func testAllSettingsCanBeConfiguredIndependently() {
        let ctx = TestStore.freshContext()
        let p = makePodcast(ctx)
        p.speedOverride = 1.25
        p.introSkipSeconds = 15
        p.autoQueue = true
        p.queueAgeLimitDays = 3
        p.inboxMaxEpisodes = 10
        p.inboxAgeLimitHours = 48
        p.notificationEnabled = true

        XCTAssertEqual(p.speedOverride, 1.25)
        XCTAssertEqual(p.introSkipSeconds, 15)
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
