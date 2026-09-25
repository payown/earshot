import XCTest
import SwiftData
@testable import Earshot

@MainActor
final class RootLaunchPreferencesTests: XCTestCase {
    func testFirstPaintUsesSavedPreferencesAndNextRootReadsChanges() throws {
        let context = TestStore.freshContext()
        let store = AppSettingsStore(context: context)
        store.setLaunchScreen(.downloads)
        store.setThemeOverride(.dark)
        store.setAccentChoice(.purple)
        store.setLayoutDensity(.compact)
        let preferences = RootLaunchPreferences()
        let first = preferences.value(in: context)
        XCTAssertEqual(first.tab, .downloads)
        XCTAssertEqual(first.theme, .dark)
        XCTAssertEqual(first.accent, .purple)
        XCTAssertEqual(first.density, .compact)
        store.setLaunchScreen(.queue)
        XCTAssertEqual(preferences.value(in: context).tab, .downloads)
        XCTAssertEqual(RootLaunchPreferences().value(in: context).tab, .queue)
    }

    func testReplacementContainerDoesNotReusePreviousStorePreferences() throws {
        let first = TestStore.freshContext()
        AppSettingsStore(context: first).setLaunchScreen(.downloads)
        let preferences = RootLaunchPreferences()
        XCTAssertEqual(preferences.value(in: first).tab, .downloads)
        let replacement = ModelContext(try ModelContainerFactory.makeInMemory())
        AppSettingsStore(context: replacement).setLaunchScreen(.library)
        XCTAssertEqual(preferences.value(in: replacement).tab, .library)
    }
}
