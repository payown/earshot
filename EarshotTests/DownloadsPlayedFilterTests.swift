import XCTest
import SwiftData
@testable import Earshot

/// Unit tests for the Downloads screen played/unheard filter (#641): the
/// hidden-count announcement wording and the global persistence round-trip.
@MainActor
final class DownloadsPlayedFilterTests: XCTestCase {

    // MARK: Announcement wording

    func testHidingAnnouncementPlural() {
        XCTAssertEqual(
            DownloadsFilterAnnouncement.text(filter: .unheard, playedCount: 5),
            "Hiding 5 played episodes"
        )
    }

    func testHidingAnnouncementSingular() {
        XCTAssertEqual(
            DownloadsFilterAnnouncement.text(filter: .unheard, playedCount: 1),
            "Hiding 1 played episode"
        )
    }

    func testHidingNothingReadsNaturally() {
        XCTAssertEqual(
            DownloadsFilterAnnouncement.text(filter: .unheard, playedCount: 0),
            "No played episodes to hide"
        )
    }

    func testShowingAllWithPlayed() {
        XCTAssertEqual(
            DownloadsFilterAnnouncement.text(filter: .all, playedCount: 3),
            "Showing all downloads, 3 played episodes included"
        )
        XCTAssertEqual(
            DownloadsFilterAnnouncement.text(filter: .all, playedCount: 1),
            "Showing all downloads, 1 played episode included"
        )
    }

    func testShowingAllWithNoPlayed() {
        XCTAssertEqual(
            DownloadsFilterAnnouncement.text(filter: .all, playedCount: 0),
            "Showing all downloads"
        )
    }

    // MARK: Global persistence round-trip

    func testDefaultsToAllWhenUnset() {
        let store = AppSettingsStore(context: TestStore.freshContext())
        // Downloads defaults to All (show every download) so hiding played is an
        // opt-in that never surprises a user by hiding files they downloaded.
        XCTAssertEqual(store.downloadsPlayedFilter(), .all)
    }

    func testPersistsGlobally() {
        let store = AppSettingsStore(context: TestStore.freshContext())
        store.setDownloadsPlayedFilter(.unheard)
        XCTAssertEqual(store.downloadsPlayedFilter(), .unheard)
        store.setDownloadsPlayedFilter(.all)
        XCTAssertEqual(store.downloadsPlayedFilter(), .all)
    }

    func testUnparseableValueFallsBackToDefault() {
        let context = TestStore.freshContext()
        let store = AppSettingsStore(context: context)
        store.setRawValue("garbage", for: SettingsKey.downloadsPlayedFilter)
        XCTAssertEqual(store.downloadsPlayedFilter(), .all)
    }

    func testKeyIsStable() {
        XCTAssertEqual(SettingsKey.downloadsPlayedFilter, "downloads_played_filter")
    }
}
