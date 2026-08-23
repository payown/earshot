import XCTest
import SwiftData
@testable import Earshot

@MainActor
final class AppSettingsStoreTests: XCTestCase {

    private func makeStore() throws -> AppSettingsStore {
        AppSettingsStore(context: TestStore.freshContext())
    }

    func testReturnsDefaultsWhenUnset() throws {
        let store = try makeStore()
        XCTAssertEqual(store.int(SettingsKey.autoDownloadCount, default: SettingsDefault.autoDownloadCount), 0)
        XCTAssertEqual(store.bool(SettingsKey.wifiOnlyDownloads, default: SettingsDefault.wifiOnlyDownloads), true)
        XCTAssertFalse(
            store.bool(
                SettingsKey.downloadCompletionNotifications,
                default: SettingsDefault.downloadCompletionNotifications
            )
        )
        XCTAssertEqual(store.double(SettingsKey.globalSpeed, default: SettingsDefault.globalSpeed), 1.0)
        XCTAssertEqual(store.launchScreen(), .inbox)
        XCTAssertFalse(
            store.bool(
                SettingsKey.dismissPlayerWhenPlaybackEnds,
                default: SettingsDefault.dismissPlayerWhenPlaybackEnds
            )
        )
    }

    func testDismissPlayerWhenPlaybackEndsPersistsAndMirrors() throws {
        let context = TestStore.freshContext()
        let settings = SettingsStore()
        settings.configure(context: context)

        XCTAssertFalse(settings.dismissPlayerWhenPlaybackEnds)
        settings.dismissPlayerWhenPlaybackEnds = true

        let reloaded = SettingsStore()
        reloaded.configure(context: context)
        XCTAssertTrue(reloaded.dismissPlayerWhenPlaybackEnds)
        XCTAssertFalse(AppSettingScope.isLocal(SettingsKey.dismissPlayerWhenPlaybackEnds))
    }

    func testRoundTripsTypedValues() throws {
        let store = try makeStore()
        store.setInt(5, for: SettingsKey.autoDownloadCount)
        store.setBool(false, for: SettingsKey.wifiOnlyDownloads)
        store.setDouble(1.5, for: SettingsKey.globalSpeed)
        store.setLaunchScreen(.queue)

        XCTAssertEqual(store.int(SettingsKey.autoDownloadCount, default: 3), 5)
        XCTAssertEqual(store.bool(SettingsKey.wifiOnlyDownloads, default: true), false)
        XCTAssertEqual(store.double(SettingsKey.globalSpeed, default: 1.0), 1.5)
        XCTAssertEqual(store.launchScreen(), .queue)
    }

    func testOverwritingKeyKeepsSingleRow() throws {
        let context = TestStore.freshContext()
        let store = AppSettingsStore(context: context)
        store.setInt(1, for: SettingsKey.autoDownloadCount)
        store.setInt(2, for: SettingsKey.autoDownloadCount)
        store.setInt(3, for: SettingsKey.autoDownloadCount)

        let rows = try context.fetch(FetchDescriptor<LocalAppSetting>())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(store.int(SettingsKey.autoDownloadCount, default: 0), 3)
    }

    func testDeviceLocalWriteOverridesLegacyMirroredValue() throws {
        let context = TestStore.freshContext()
        context.insert(AppSetting(key: SettingsKey.autoDownloadCount, value: "1"))
        context.insert(AppSetting(key: SettingsKey.autoDownloadCount, value: "2"))

        AppSettingsStore(context: context).setRawValue("7", for: SettingsKey.autoDownloadCount)

        let rows = try context.fetch(FetchDescriptor<LocalAppSetting>())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.value, "7")
        XCTAssertEqual(
            AppSettingsStore(context: context).int(SettingsKey.autoDownloadCount, default: 0),
            7
        )
    }

    func testDownloadPreferencesAreDeviceLocalWhilePlaybackSpeedMirrors() {
        for key in [
            SettingsKey.autoDownloadCount,
            SettingsKey.downloadRetentionDays,
            SettingsKey.wifiOnlyDownloads,
            SettingsKey.downloadCompletionNotifications,
            SettingsKey.deleteDownloadAfterPlayed,
            SettingsKey.autoDownloadQueued,
            SettingsKey.downloadsPlayedFilter,
        ] {
            XCTAssertTrue(AppSettingScope.isLocal(key), key)
        }
        XCTAssertFalse(AppSettingScope.isLocal(SettingsKey.globalSpeed))
    }

    func testAccessibilitySpeechPreferencesAreDeviceLocal() {
        for key in [
            SettingsKey.spokenEpisodePodcastName,
            SettingsKey.spokenEpisodePublishedDate,
            SettingsKey.spokenEpisodeDownloadStatus,
            SettingsKey.spokenEpisodeDuration,
            SettingsKey.spokenEpisodeDescriptionMode,
            SettingsKey.spokenPodcastDescriptionMode,
        ] {
            XCTAssertTrue(AppSettingScope.isLocal(key), key)
        }
    }

    func testPerPodcastWriteMergesLegacyURLKeyVariants() throws {
        let context = TestStore.freshContext()
        context.insert(
            AppSetting(
                key: SettingsKey.podcastFilterPrefix + "HTTPS://Example.COM:443/feed.xml#old",
                value: EpisodeListFilter.all.rawValue
            )
        )
        context.insert(
            AppSetting(
                key: SettingsKey.podcastFilterPrefix + "https://example.com/feed.xml",
                value: EpisodeListFilter.unheard.rawValue
            )
        )

        AppSettingsStore(context: context).setEpisodeListFilter(
            .all,
            forFeedURL: "https://example.com/feed.xml"
        )

        let rows = try context.fetch(FetchDescriptor<AppSetting>())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(
            rows.first?.key,
            SettingsKey.podcastFilterPrefix + "https://example.com/feed.xml"
        )
        XCTAssertEqual(rows.first?.value, EpisodeListFilter.all.rawValue)
    }

    func testOptionalIntNullSentinel() throws {
        let store = try makeStore()
        store.setOptionalInt(nil, for: SettingsKey.historyRetentionDays)
        XCTAssertNil(store.optionalInt(SettingsKey.historyRetentionDays))
        store.setOptionalInt(90, for: SettingsKey.historyRetentionDays)
        XCTAssertEqual(store.optionalInt(SettingsKey.historyRetentionDays), 90)
    }

    func testDateIsNilWhenUnset() throws {
        let store = try makeStore()
        XCTAssertNil(store.date(SettingsKey.lastFeedRefresh))
    }

    func testDateRoundTrips() throws {
        let store = try makeStore()
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        store.setDate(when, for: SettingsKey.lastFeedRefresh)
        let read = store.date(SettingsKey.lastFeedRefresh)
        XCTAssertNotNil(read)
        // Stored as epoch seconds; sub-second precision is intentionally dropped.
        XCTAssertEqual(read!.timeIntervalSince1970, when.timeIntervalSince1970, accuracy: 0.001)
    }

    // MARK: Inbox seed-on-subscribe count

    func testInboxDefaultCountDefaultsToThree() throws {
        let store = try makeStore()
        XCTAssertEqual(store.inboxDefaultCount(), 3)
        XCTAssertEqual(SettingsDefault.inboxDefaultCount, 3)
    }

    func testInboxDefaultCountRoundTrips() throws {
        let store = try makeStore()
        store.setInboxDefaultCount(5)
        XCTAssertEqual(store.inboxDefaultCount(), 5)
        // The "All" sentinel persists distinctly from 0 (none).
        store.setInboxDefaultCount(SettingsDefault.inboxDefaultCountAll)
        XCTAssertEqual(store.inboxDefaultCount(), -1)
        store.setInboxDefaultCount(0)
        XCTAssertEqual(store.inboxDefaultCount(), 0)
    }

    // MARK: Queue grouping (#444, #762)

    func testQueueGroupingDefaultsToNone() throws {
        let store = try makeStore()
        XCTAssertEqual(store.queueGrouping(), .none)
        XCTAssertEqual(SettingsDefault.queueGrouping, .none)
    }

    func testQueueGroupingRoundTripsAllModes() throws {
        let store = try makeStore()
        for mode in QueueGrouping.allCases {
            store.setQueueGrouping(mode)
            XCTAssertEqual(store.queueGrouping(), mode)
        }
    }

    func testQueueGroupingMigratesLegacyBooleanValues() throws {
        let store = try makeStore()
        store.setBool(true, for: SettingsKey.groupQueueEpisodes)
        XCTAssertEqual(store.queueGrouping(), .podcast)
        store.setBool(false, for: SettingsKey.groupQueueEpisodes)
        XCTAssertEqual(store.queueGrouping(), .none)
    }

    /// The Queue menu and Playback settings both flow through
    /// SettingsStore.queueGrouping, which must persist and reload from the
    /// shared key so the choice survives navigation and relaunch.
    func testSettingsStorePersistsQueueGrouping() throws {
        let context = TestStore.freshContext()

        let settings = SettingsStore()
        settings.configure(context: context)
        XCTAssertEqual(settings.queueGrouping, .none)

        settings.queueGrouping = .folder

        // A fresh store over the same context (simulating relaunch) reads it back.
        let reloaded = SettingsStore()
        reloaded.configure(context: context)
        XCTAssertEqual(reloaded.queueGrouping, .folder)

        // And the raw key matches what the Queue and Settings Pickers write.
        let raw = AppSettingsStore(context: context)
        XCTAssertEqual(raw.rawValue(SettingsKey.groupQueueEpisodes), QueueGrouping.folder.rawValue)
    }

    // MARK: Chapter navigation buttons (#515)

    func testChapterNavButtonsDefaultToVisible() throws {
        let store = try makeStore()
        XCTAssertEqual(store.bool(SettingsKey.chapterNavButtonsVisible, default: SettingsDefault.chapterNavButtonsVisible), true)
        XCTAssertEqual(SettingsDefault.chapterNavButtonsVisible, true)
    }

    func testChapterNavButtonsRoundTrips() throws {
        let store = try makeStore()
        store.setBool(false, for: SettingsKey.chapterNavButtonsVisible)
        XCTAssertEqual(store.bool(SettingsKey.chapterNavButtonsVisible, default: true), false)
        store.setBool(true, for: SettingsKey.chapterNavButtonsVisible)
        XCTAssertEqual(store.bool(SettingsKey.chapterNavButtonsVisible, default: false), true)
    }

    /// The Settings toggle flows through SettingsStore.chapterNavButtonsVisible,
    /// which must default visible and persist/reload so the player honors it
    /// across relaunch (#515).
    func testSettingsStorePersistsChapterNavButtonsVisible() throws {
        let context = TestStore.freshContext()

        let settings = SettingsStore()
        settings.configure(context: context)
        XCTAssertEqual(settings.chapterNavButtonsVisible, true)

        settings.chapterNavButtonsVisible = false

        let reloaded = SettingsStore()
        reloaded.configure(context: context)
        XCTAssertEqual(reloaded.chapterNavButtonsVisible, false)

        let raw = AppSettingsStore(context: context)
        XCTAssertEqual(raw.bool(SettingsKey.chapterNavButtonsVisible, default: true), false)
    }

    // MARK: Podcast cap grandfathering (#635)

    func testPodcastCapGatingDefaultsWhenUnset() throws {
        let store = try makeStore()
        XCTAssertFalse(store.podcastCapGatingIntroduced())
        XCTAssertEqual(store.grandfatheredPodcastCount(), 0)
    }

    func testIntroducePodcastCapGatingIfNeededSetsBothKeysOnFirstCall() throws {
        let store = try makeStore()
        store.introducePodcastCapGatingIfNeeded(currentPodcastCount: 17)

        XCTAssertTrue(store.podcastCapGatingIntroduced())
        XCTAssertEqual(store.grandfatheredPodcastCount(), 17)
    }

    /// A second call is a true no-op — the grandfathered count is a one-time
    /// snapshot and must never be overwritten by a later podcast count.
    func testIntroducePodcastCapGatingIfNeededIsNoOpOnSecondCall() throws {
        let store = try makeStore()
        store.introducePodcastCapGatingIfNeeded(currentPodcastCount: 17)
        store.introducePodcastCapGatingIfNeeded(currentPodcastCount: 42)

        XCTAssertTrue(store.podcastCapGatingIntroduced())
        XCTAssertEqual(store.grandfatheredPodcastCount(), 17, "The second call's argument (42) must never overwrite the first snapshot")
    }

    func testIntroducePodcastCapGatingIfNeededOnFreshInstallSnapshotsZero() throws {
        let store = try makeStore()
        store.introducePodcastCapGatingIfNeeded(currentPodcastCount: 0)

        XCTAssertTrue(store.podcastCapGatingIntroduced())
        XCTAssertEqual(store.grandfatheredPodcastCount(), 0)
    }

}
