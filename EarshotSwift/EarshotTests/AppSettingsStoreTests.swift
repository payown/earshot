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
}
