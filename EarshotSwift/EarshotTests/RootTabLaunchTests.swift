import XCTest
@testable import Earshot

/// Verifies the `LaunchScreen -> RootTab` mapping that seeds the cold-launch tab
/// (#492). Pure value mapping; no SwiftData, no UI.
final class RootTabLaunchTests: XCTestCase {

    func testInboxMapsToInboxTab() {
        XCTAssertEqual(RootTab(launchScreen: .inbox), .inbox)
    }

    func testQueueMapsToQueueTab() {
        XCTAssertEqual(RootTab(launchScreen: .queue), .queue)
    }

    func testLibraryMapsToLibraryTab() {
        XCTAssertEqual(RootTab(launchScreen: .library), .library)
    }

    func testDownloadsMapsToDownloadsTab() {
        XCTAssertEqual(RootTab(launchScreen: .downloads), .downloads)
    }

    /// Every `LaunchScreen` case must resolve to a tab — guards against a new
    /// case being added without a mapping (which would fail to compile, but this
    /// also documents that all current cases are covered).
    func testEveryLaunchScreenCaseHasAMapping() {
        for screen in LaunchScreen.allCases {
            let tab = RootTab(launchScreen: screen)
            switch screen {
            case .inbox: XCTAssertEqual(tab, .inbox)
            case .queue: XCTAssertEqual(tab, .queue)
            case .library: XCTAssertEqual(tab, .library)
            case .downloads: XCTAssertEqual(tab, .downloads)
            }
        }
        // The default launch screen must never resolve to Settings (which has no
        // LaunchScreen case): the launch tab is always a content tab.
        XCTAssertNotEqual(RootTab(launchScreen: SettingsDefault.launchScreen), .settings)
    }
}
