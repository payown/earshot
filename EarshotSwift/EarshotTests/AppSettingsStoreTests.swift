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
        XCTAssertEqual(store.int(SettingsKey.autoDownloadCount, default: SettingsDefault.autoDownloadCount), 3)
        XCTAssertEqual(store.bool(SettingsKey.wifiOnlyDownloads, default: SettingsDefault.wifiOnlyDownloads), true)
        XCTAssertEqual(store.double(SettingsKey.globalSpeed, default: SettingsDefault.globalSpeed), 1.0)
        XCTAssertEqual(store.launchScreen(), .inbox)
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

        let rows = try context.fetch(FetchDescriptor<AppSetting>())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(store.int(SettingsKey.autoDownloadCount, default: 0), 3)
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

    // MARK: Group queue by podcast (#444)

    func testGroupQueueEpisodesDefaultsToFalse() throws {
        let store = try makeStore()
        XCTAssertEqual(store.bool(SettingsKey.groupQueueEpisodes, default: SettingsDefault.groupQueueEpisodes), false)
        XCTAssertEqual(SettingsDefault.groupQueueEpisodes, false)
    }

    func testGroupQueueEpisodesRoundTrips() throws {
        let store = try makeStore()
        store.setBool(true, for: SettingsKey.groupQueueEpisodes)
        XCTAssertEqual(store.bool(SettingsKey.groupQueueEpisodes, default: false), true)
        store.setBool(false, for: SettingsKey.groupQueueEpisodes)
        XCTAssertEqual(store.bool(SettingsKey.groupQueueEpisodes, default: true), false)
    }

    /// The queue display toggle and the App Settings toggle both flow through
    /// SettingsStore.groupQueueEpisodes, which must persist and reload from the
    /// shared key so the choice survives navigation and relaunch.
    func testSettingsStorePersistsGroupQueueEpisodes() throws {
        let context = TestStore.freshContext()

        let settings = SettingsStore()
        settings.configure(context: context)
        XCTAssertEqual(settings.groupQueueEpisodes, false)

        settings.groupQueueEpisodes = true

        // A fresh store over the same context (simulating relaunch) reads it back.
        let reloaded = SettingsStore()
        reloaded.configure(context: context)
        XCTAssertEqual(reloaded.groupQueueEpisodes, true)

        // And the raw key matches what the queue toolbar Toggle writes.
        let raw = AppSettingsStore(context: context)
        XCTAssertEqual(raw.bool(SettingsKey.groupQueueEpisodes, default: false), true)
    }

    // MARK: Migration status (#429)

    func testMigrationStatusDefaultsToNotAttempted() throws {
        let store = try makeStore()
        XCTAssertEqual(store.migrationStatus(), .notAttempted)
    }

    func testMigrationStatusFallsBackWhenUnparseable() throws {
        let store = try makeStore()
        // A stale / unknown raw value must read as the safe default, never crash.
        store.setRawValue("garbage", for: SettingsKey.migrationStatus)
        XCTAssertEqual(store.migrationStatus(), .notAttempted)
    }

    func testMigrationStatusRoundTrips() throws {
        let store = try makeStore()
        store.setMigrationStatus(.succeeded)
        XCTAssertEqual(store.migrationStatus(), .succeeded)
        store.setMigrationStatus(.failed)
        XCTAssertEqual(store.migrationStatus(), .failed)
    }

    func testMigrationLastAttemptDateNilWhenUnset() throws {
        let store = try makeStore()
        XCTAssertNil(store.migrationLastAttemptDate())
    }

    func testMigrationLastAttemptDateRoundTrips() throws {
        let store = try makeStore()
        let when = Date(timeIntervalSince1970: 1_700_500_000)
        store.setMigrationLastAttemptDate(when)
        let read = store.migrationLastAttemptDate()
        XCTAssertNotNil(read)
        XCTAssertEqual(read!.timeIntervalSince1970, when.timeIntervalSince1970, accuracy: 0.001)
    }
}
