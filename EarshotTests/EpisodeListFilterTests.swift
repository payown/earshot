import XCTest
import SwiftData
@testable import Earshot

/// Unit tests for the pure ``EpisodeListFilter`` logic and its per-podcast
/// persistence round-trip (#489).
@MainActor
final class EpisodeListFilterTests: XCTestCase {

    // MARK: Fixtures

    private func makeEpisode(_ guid: String, played: Bool) -> Episode {
        Episode(
            guid: guid,
            title: "Episode \(guid)",
            audioURL: "https://example.com/\(guid).mp3",
            status: played ? .played : .newEpisode
        )
    }

    /// Three unplayed, two played.
    private func mixedList() -> [Episode] {
        [
            makeEpisode("1", played: false),
            makeEpisode("2", played: true),
            makeEpisode("3", played: false),
            makeEpisode("4", played: true),
            makeEpisode("5", played: false),
        ]
    }

    // MARK: apply(to:)

    func testUnheardExcludesPlayed() {
        let result = EpisodeListFilter.unheard.apply(to: mixedList())
        XCTAssertEqual(result.count, 3)
        XCTAssertTrue(result.allSatisfy { !$0.isPlayed })
        // Order preserved.
        XCTAssertEqual(result.map(\.guid), ["1", "3", "5"])
    }

    func testAllIncludesEverything() {
        let list = mixedList()
        let result = EpisodeListFilter.all.apply(to: list)
        XCTAssertEqual(result.count, list.count)
        XCTAssertEqual(result.map(\.guid), list.map(\.guid))
    }

    func testEmptyListStaysEmpty() {
        XCTAssertTrue(EpisodeListFilter.unheard.apply(to: []).isEmpty)
        XCTAssertTrue(EpisodeListFilter.all.apply(to: []).isEmpty)
    }

    func testAllPlayedListYieldsNoneForUnheard() {
        let allPlayed = [
            makeEpisode("1", played: true),
            makeEpisode("2", played: true),
        ]
        XCTAssertTrue(EpisodeListFilter.unheard.apply(to: allPlayed).isEmpty)
        XCTAssertEqual(EpisodeListFilter.all.apply(to: allPlayed).count, 2)
    }

    // MARK: announcement(count:)

    func testAnnouncementWording() {
        XCTAssertEqual(EpisodeListFilter.unheard.announcement(count: 12), "Showing 12 unheard episodes")
        XCTAssertEqual(EpisodeListFilter.all.announcement(count: 316), "Showing all 316 episodes")
    }

    func testAnnouncementSingularPlural() {
        XCTAssertEqual(EpisodeListFilter.unheard.announcement(count: 1), "Showing 1 unheard episode")
        XCTAssertEqual(EpisodeListFilter.all.announcement(count: 1), "Showing all 1 episode")
        XCTAssertEqual(EpisodeListFilter.unheard.announcement(count: 0), "Showing 0 unheard episodes")
    }

    // MARK: rawValue round-trip

    func testRawValuesAreStable() {
        XCTAssertEqual(EpisodeListFilter.unheard.rawValue, "unheard")
        XCTAssertEqual(EpisodeListFilter.all.rawValue, "all")
        for filter in EpisodeListFilter.allCases {
            XCTAssertEqual(EpisodeListFilter(rawValue: filter.rawValue), filter)
        }
    }

    func testTitles() {
        XCTAssertEqual(EpisodeListFilter.unheard.title, "Unheard")
        XCTAssertEqual(EpisodeListFilter.all.title, "All")
    }

    // MARK: Per-podcast persistence

    func testDefaultsToUnheardWhenUnset() {
        let store = AppSettingsStore(context: TestStore.freshContext())
        XCTAssertEqual(store.episodeListFilter(forFeedURL: "https://feeds.example.com/a"), .unheard)
    }

    func testPersistsPerPodcast() {
        let store = AppSettingsStore(context: TestStore.freshContext())
        let feedA = "https://feeds.example.com/a"
        let feedB = "https://feeds.example.com/b"

        store.setEpisodeListFilter(.all, forFeedURL: feedA)

        // Feed A remembers All; Feed B still falls back to the Unheard default.
        XCTAssertEqual(store.episodeListFilter(forFeedURL: feedA), .all)
        XCTAssertEqual(store.episodeListFilter(forFeedURL: feedB), .unheard)
    }

    func testKeyIsScopedByFeedURL() {
        let feedURL = "https://feeds.example.com/a"
        XCTAssertEqual(SettingsKey.podcastFilter(feedURL: feedURL), "podcast_filter_\(feedURL)")
    }

    func testUnparseableValueFallsBackToDefault() {
        let context = TestStore.freshContext()
        let store = AppSettingsStore(context: context)
        let feedURL = "https://feeds.example.com/a"
        store.setRawValue("garbage", for: SettingsKey.podcastFilter(feedURL: feedURL))
        XCTAssertEqual(store.episodeListFilter(forFeedURL: feedURL), .unheard)
    }
}
