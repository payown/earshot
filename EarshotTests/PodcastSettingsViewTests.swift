import XCTest
import SwiftData
@testable import Earshot

/// Tests for per-podcast settings logic. Since PodcastSettingsView is a SwiftUI
/// view backed directly by the SwiftData model, these tests validate the model
/// field defaults and mutations that the view exposes — no UI host required.
@MainActor
final class PodcastSettingsViewTests: XCTestCase {

    func testInboxCapSavePublishesOnlyTheEditedPodcastAfterDurableSave() throws {
        let ctx = TestStore.freshContext()
        let podcast = makePodcast(ctx)
        try ctx.save()
        let center = NotificationCenter()
        let notice = expectation(description: "Targeted settings notification")
        notice.assertForOverFulfill = true
        let feed = podcast.feedURL
        let settingsOnlyKey = PodcastSettingsPersistence.settingsOnlyKey
        let observer = center.addObserver(
            forName: .earshotSubscriptionsDidChange, object: nil, queue: nil
        ) { notification in
            XCTAssertEqual(notification.object as? String, feed)
            XCTAssertEqual(notification.userInfo?[settingsOnlyKey] as? Bool, true)
            notice.fulfill()
        }
        defer { center.removeObserver(observer) }

        podcast.inboxMaxEpisodes = 1
        AppSettingsStore(context: ctx).setPodcastInboxCap(1, forFeedURL: feed)
        try PodcastSettingsPersistence.save(podcast, in: ctx, center: center)

        let fresh = ModelContext(ctx.container)
        let persisted = try XCTUnwrap(fresh.fetch(FetchDescriptor<Podcast>()).first)
        XCTAssertEqual(persisted.inboxMaxEpisodes, 1)
        XCTAssertEqual(AppSettingsStore(context: fresh).podcastInboxCap(forFeedURL: feed), 1)
        XCTAssertFalse(ctx.hasChanges)
        wait(for: [notice], timeout: 1)
    }

    func testPersonalNameSurvivesRefreshAndFreshContextAndRestore() throws {
        let ctx = TestStore.freshContext()
        let podcast = makePodcast(ctx)
        let episode = Episode(guid: "name-episode", title: "Episode", audioURL: "https://test.example/audio.mp3")
        episode.podcast = podcast
        episode.positionSeconds = 123
        ctx.insert(episode)
        try ctx.save()
        QueueRepository(context: ctx).add(episode)
        let id = podcast.persistentModelID
        let episodeID = episode.persistentModelID
        let queueIDs = QueueRepository(context: ctx).queue().map(\.persistentModelID)
        let names = PodcastDisplayNames.shared
        names.reload(context: ctx)
        try names.save("  My Show  ", for: podcast, context: ctx)
        XCTAssertEqual(podcast.displayName, "My Show")
        XCTAssertEqual(podcast.title, "Test Podcast")
        podcast.title = "Publisher refreshed title"
        try ctx.save()
        names.reload(context: ctx)
        XCTAssertEqual(podcast.displayName, "My Show")
        let reopened = ModelContext(ctx.container)
        names.reload(context: reopened)
        let restored = try XCTUnwrap(reopened.model(for: id) as? Podcast)
        XCTAssertEqual(restored.displayName, "My Show")
        XCTAssertEqual(restored.title, "Publisher refreshed title")
        XCTAssertEqual(QueueRepository(context: reopened).queue().map(\.persistentModelID), queueIDs)
        XCTAssertEqual((reopened.model(for: episodeID) as? Episode)?.positionSeconds, 123)
        try names.save(nil, for: restored, context: reopened)
        XCTAssertEqual(restored.displayName, "Publisher refreshed title")
        XCTAssertEqual(AppSettingsStore(context: reopened).rawValue(SettingsKey.podcastDisplayName(feedURL: podcast.feedURL)), "")
    }

    func testPersonalNameRejectsBlankAndSearchFindsBothNames() throws {
        let ctx = TestStore.freshContext()
        let podcast = makePodcast(ctx)
        try ctx.save()
        let names = PodcastDisplayNames.shared
        names.reload(context: ctx)
        XCTAssertThrowsError(try names.save(" \n ", for: podcast, context: ctx))
        XCTAssertEqual(podcast.displayName, "Test Podcast")
        let originalFeed = podcast.feedURL
        try names.save("Personal Show", for: podcast, context: ctx)
        let episode = Episode(guid: "search-name", title: "Episode", audioURL: "https://test.example/e.mp3")
        episode.podcast = podcast
        ctx.insert(episode)
        try ctx.save()
        XCTAssertTrue(EpisodeSearchFilter.matches(episode, query: "Personal"))
        XCTAssertTrue(EpisodeSearchFilter.matches(episode, query: "Test Podcast"))
        XCTAssertTrue(AppSettingScope.isMirrored(SettingsKey.podcastDisplayName(feedURL: podcast.feedURL)))
        XCTAssertEqual(podcast.feedURL, originalFeed)
        XCTAssertFalse(episode.isPlayed)
        XCTAssertTrue(podcast.isFollowed)
    }

    func testPersonalNamesReloadAndCatalogOnlyKeepsPublisherTitle() throws {
        let ctx = TestStore.freshContext()
        let podcast = makePodcast(ctx)
        try ctx.save()
        let names = PodcastDisplayNames.shared
        try names.save("Personal Show", for: podcast, context: ctx)
        podcast.subscriptionStateRaw = PodcastSubscriptionState.catalogOnly.rawValue
        XCTAssertEqual(podcast.displayName, "Test Podcast")
        XCTAssertEqual(try PodcastNamePolicy.snapshot(context: ctx)[FeedURLIdentity.canonical(podcast.feedURL)], "Personal Show")
    }

    func testDisplayNameLookupStaysBoundedWithTenThousandEpisodes() throws {
        let ctx = TestStore.freshContext()
        let podcast = makePodcast(ctx)
        var episodes: [Episode] = []
        for index in 0..<10_000 {
            let episode = Episode(guid: "name-scale-\(index)", title: "Episode", audioURL: "https://test.example/\(index).mp3")
            episode.podcast = podcast
            ctx.insert(episode)
            episodes.append(episode)
        }
        try ctx.save()
        try PodcastDisplayNames.shared.save("Personal Show", for: podcast, context: ctx)
        let start = Date()
        let matching = episodes.reduce(0) { $0 + ($1.podcast?.displayName == "Personal Show" ? 1 : 0) }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(matching, 10_000)
        XCTAssertLessThan(elapsed, 3, "Presentation lookup must stay cached and never query the episode table")
    }

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

    // MARK: Folders section (#754)
    //
    // The Folders section reads `FolderRepository.folders(containing:)` and
    // renders each folder by its `FolderLogic.pathString`, or a single
    // "Not in any folder" row when empty. These tests drive the repo the section
    // reads from and validate the display strings/labels the section produces.

    func testPodcastNotInAnyFolderShowsEmptyStateLabel() {
        let ctx = TestStore.freshContext()
        let p = makePodcast(ctx)
        let repo = FolderRepository(context: ctx)
        _ = repo.createFolder(name: "News") // a folder exists, but p isn't in it

        XCTAssertTrue(
            repo.folders(containing: p).isEmpty,
            "A podcast added to no folder must report zero containing folders"
        )
        XCTAssertEqual(
            PodcastSettingsView.notInAnyFolderText, "Not in any folder",
            "The empty-state row must read 'Not in any folder'"
        )
    }

    func testFolderRowLabelsUseFullPath() {
        let ctx = TestStore.freshContext()
        let p = makePodcast(ctx)
        let repo = FolderRepository(context: ctx)
        let news = repo.createFolder(name: "News")
        let daily = repo.createSubfolder(named: "Daily", under: news)
        repo.add(p, to: daily)

        let containing = repo.folders(containing: p)
        XCTAssertEqual(containing.count, 1, "The podcast belongs to exactly one folder")
        XCTAssertEqual(
            containing.map { FolderLogic.pathString($0) },
            ["News › Daily"],
            "A folder row must be labelled with its full breadcrumb path, not just its name"
        )
    }

    func testTogglingMembershipAddsThenRemoves() {
        let ctx = TestStore.freshContext()
        let p = makePodcast(ctx)
        let repo = FolderRepository(context: ctx)
        let folder = repo.createFolder(name: "News")

        XCTAssertTrue(repo.folders(containing: p).isEmpty, "starts in no folder")

        // Toggle on — the picker's add path.
        repo.add(p, to: folder)
        XCTAssertEqual(
            repo.folders(containing: p).map(\.name), ["News"],
            "Adding membership must place the podcast in the folder immediately"
        )

        // Toggle off — the picker's remove path.
        repo.remove(p, from: folder)
        XCTAssertTrue(
            repo.folders(containing: p).isEmpty,
            "Removing membership must take the podcast back out of the folder immediately"
        )
    }

    func testMembershipAnnouncementNamesTheFolderPath() {
        XCTAssertEqual(
            PodcastFolderPickerView.membershipAnnouncement(added: true, path: "News › Daily"),
            "Added to News › Daily"
        )
        XCTAssertEqual(
            PodcastFolderPickerView.membershipAnnouncement(added: false, path: "News"),
            "Removed from News"
        )
    }

    func testFolderManagementCopyDescribesTheMultiMembershipEditor() {
        XCTAssertEqual(PodcastFolderPickerView.navigationTitleText, "Manage folders")
        XCTAssertEqual(PodcastSettingsView.manageFoldersButtonLabel, "Manage folders…")
    }

    func testPickerHierarchyIsDepthFirstParentBeforeChild() {
        let ctx = TestStore.freshContext()
        let repo = FolderRepository(context: ctx)
        let news = repo.createFolder(name: "News")
        let daily = repo.createSubfolder(named: "Daily", under: news)
        let comedy = repo.createFolder(name: "Comedy")

        let ordered = PodcastFolderPickerView.orderedHierarchy(from: repo.folders())

        // Parent appears immediately before its child; siblings keep sortOrder
        // (News before Comedy).
        XCTAssertEqual(
            ordered.map(\.name), ["News", "Daily", "Comedy"],
            "The picker lists folders nested: a top-level root then its children before the next root"
        )
        XCTAssertEqual(daily.parent?.persistentModelID, news.persistentModelID)
        XCTAssertNil(comedy.parent)
    }
}
