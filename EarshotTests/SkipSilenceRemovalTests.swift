import XCTest
import SwiftData
@testable import Earshot

/// Regression coverage for reviving silence trimming in #570 while preserving
/// the original persisted key from the removed #369 stub.
@MainActor
final class SkipSilenceSettingsTests: XCTestCase {

    func test_skipSilenceKey_stillExistsInSettingsKey_forDataCompatibility() {
        XCTAssertEqual(SettingsKey.skipSilenceEnabled, "skip_silence_enabled")
    }

    func test_skipSilenceDefault_stillExistsInSettingsDefault_andIsFalse() {
        XCTAssertFalse(SettingsDefault.skipSilenceEnabled)
    }

    func test_skipSilenceKey_canBeReadFromAppSettingsStore_returnsDefault() {
        let store = AppSettingsStore(context: TestStore.freshContext())
        let value = store.bool(SettingsKey.skipSilenceEnabled, default: SettingsDefault.skipSilenceEnabled)
        XCTAssertFalse(value, "Default should be false when key is absent")
    }

    func test_skipSilenceKey_writtenByOldBuild_canBeReadByCurrentBuild() {
        let ctx = TestStore.freshContext()
        let store = AppSettingsStore(context: ctx)
        store.setBool(true, for: SettingsKey.skipSilenceEnabled)
        let readBack = store.bool(SettingsKey.skipSilenceEnabled, default: false)
        XCTAssertTrue(readBack, "Persisted legacy value should activate the revived feature")
    }

    func test_settingsStoreLoadsAndPersistsSkipSilenceEnabled() {
        let ctx = TestStore.freshContext()
        AppSettingsStore(context: ctx).setBool(true, for: SettingsKey.skipSilenceEnabled)

        let settings = SettingsStore()
        settings.configure(context: ctx)
        XCTAssertTrue(settings.skipSilenceEnabled)

        settings.skipSilenceEnabled = false
        XCTAssertFalse(
            AppSettingsStore(context: ctx).bool(SettingsKey.skipSilenceEnabled, default: true)
        )
    }

    func test_skipSilenceWritePostsPlaybackNotification() async {
        let ctx = TestStore.freshContext()
        let expectation = expectation(description: "silence setting changed")
        let token = NotificationCenter.default.addObserver(
            forName: .earshotSkipSilenceSettingDidChange,
            object: nil,
            queue: .main
        ) { _ in expectation.fulfill() }
        defer { NotificationCenter.default.removeObserver(token) }

        AppSettingsStore(context: ctx).setBool(true, for: SettingsKey.skipSilenceEnabled)
        await fulfillment(of: [expectation], timeout: 1)
    }
}
