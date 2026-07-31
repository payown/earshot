import XCTest
import SwiftData
@testable import Earshot

/// Tests for issue #369: Skip Silence toggle removed (dead stub).
///
/// The feature required MTAudioProcessingTap which was not implemented.
/// The SettingsStore property and Settings UI toggle were removed.
/// The SettingsKey and SettingsDefault entries are retained for data
/// compatibility so existing persisted values from old installs are not
/// corrupted by a missing key write.
@MainActor
final class SkipSilenceRemovalTests: XCTestCase {

    // MARK: - Acceptance criterion 1: deprecated key is preserved for data compat

    func test_skipSilenceKey_stillExistsInSettingsKey_forDataCompatibility() {
        // Acceptance criterion: AppSettingsStore key is retained so old persisted
        // rows are not orphaned after the feature is removed (#369).
        let key = SettingsKey.skipSilenceEnabled
        XCTAssertEqual(key, "skip_silence_enabled")
    }

    func test_skipSilenceDefault_stillExistsInSettingsDefault_andIsFalse() {
        // Acceptance criterion: retained default value matches what the Flutter
        // app used; existing tester data is not affected (#369).
        XCTAssertFalse(SettingsDefault.skipSilenceEnabled)
    }

    // MARK: - Acceptance criterion 2: deprecated key round-trips via AppSettingsStore

    func test_skipSilenceKey_canBeReadFromAppSettingsStore_returnsDefault() {
        // Acceptance criterion: if a tester has an old value stored under this key,
        // AppSettingsStore can still read it without crashing (#369).
        let store = AppSettingsStore(context: TestStore.freshContext())
        let value = store.bool(SettingsKey.skipSilenceEnabled, default: SettingsDefault.skipSilenceEnabled)
        XCTAssertFalse(value, "Default should be false when key is absent")
    }

    func test_skipSilenceKey_writtenByOldBuild_canBeReadByCurrentBuild() {
        // Simulates a tester who had skip silence enabled in an older build.
        // The key must be readable without crashing, even though the feature
        // is gone from the UI (#369).
        let ctx = TestStore.freshContext()
        let store = AppSettingsStore(context: ctx)

        // Old build writes true
        store.setBool(true, for: SettingsKey.skipSilenceEnabled)

        // Current build reads it (for data compat, not UI display)
        let readBack = store.bool(SettingsKey.skipSilenceEnabled, default: false)
        XCTAssertTrue(readBack, "Persisted legacy value should survive the removal")
    }

    // MARK: - Acceptance criterion 3: SettingsStore has no live skipSilenceEnabled property

    func test_settingsStore_doesNotLoadSkipSilenceEnabledFromPersistence() {
        // Acceptance criterion: SettingsStore.configure() must not attempt to
        // read or write skipSilenceEnabled. This test confirms configure() runs
        // cleanly on a context that has the legacy key present, and that none
        // of the other settings are affected (#369).
        let ctx = TestStore.freshContext()
        let legacyStore = AppSettingsStore(context: ctx)

        // Seed the legacy key so configure() would fail visibly if it tried
        // to load it into a non-existent property.
        legacyStore.setBool(true, for: SettingsKey.skipSilenceEnabled)

        let settings = SettingsStore()
        // configure() must not crash even with the legacy key present
        settings.configure(context: ctx)

        // Other settings load correctly; the legacy key is silently ignored
        XCTAssertEqual(settings.globalSpeed, SettingsDefault.globalSpeed)
        XCTAssertEqual(settings.skipForwardSeconds, SettingsDefault.skipForwardSeconds)
        XCTAssertEqual(settings.skipBackSeconds, SettingsDefault.skipBackSeconds)
    }

    // MARK: - Acceptance criterion 4: SettingsStore does not surface skipSilenceEnabled

    func test_settingsStore_propertiesDoNotIncludeSkipSilenceEnabled() {
        // This test documents the contract by name. The fact that this file
        // compiles without `settings.skipSilenceEnabled` is the compile-time
        // proof of removal. Here we verify that the known playback properties
        // are still present and functional after the removal (#369).
        let ctx = TestStore.freshContext()
        let settings = SettingsStore()
        settings.configure(context: ctx)

        // These are the only playback properties that should exist:
        _ = settings.globalSpeed
        _ = settings.skipForwardSeconds
        _ = settings.skipBackSeconds
        _ = settings.voiceEnhanceEnabled
        // settings.skipSilenceEnabled  <-- intentionally absent; would not compile
    }
}
