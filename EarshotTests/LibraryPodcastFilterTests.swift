import XCTest
import SwiftData
@testable import Earshot

@MainActor
final class LibraryPodcastFilterTests: XCTestCase {
    func testUnknownCountsStayVisibleAndFilteringPreservesInputOrder() {
        let counts: [String: Int] = ["caught-up": 0, "unheard": 2]
        let ordered = ["unknown", "caught-up", "unheard"]
        XCTAssertEqual(ordered.filter {
            LibraryPodcastFilter.includes(unplayedCount: counts[$0], hideCaughtUp: true)
        }, ["unknown", "unheard"])
        XCTAssertEqual(ordered.filter {
            LibraryPodcastFilter.includes(unplayedCount: counts[$0], hideCaughtUp: false)
        }, ordered)
    }

    func testPreferenceDefaultsOffAndSurvivesSettingsReload() {
        let context = TestStore.freshContext()
        let first = SettingsStore()
        first.configure(context: context)
        XCTAssertFalse(first.hideCaughtUpPodcasts)
        first.hideCaughtUpPodcasts = true
        let reloaded = SettingsStore()
        reloaded.configure(context: context)
        XCTAssertTrue(reloaded.hideCaughtUpPodcasts)
        reloaded.hideCaughtUpPodcasts = false
        first.configure(context: context)
        XCTAssertFalse(first.hideCaughtUpPodcasts)
        XCTAssertFalse(AppSettingScope.isLocal(SettingsKey.hideCaughtUpPodcasts))
    }

    func testLiveCountsHideCompletedPodcastAndRestoreNewUnplayedEpisode() async throws {
        let context = TestStore.freshContext()
        let podcast = Podcast(feedURL: "https://example.com/feed", title: "Show")
        context.insert(podcast)
        let episode = Episode(guid: "one", title: "One", audioURL: "https://example.com/audio")
        context.insert(episode)
        episode.podcast = podcast
        try context.save()
        let id = podcast.persistentModelID
        var counts = try await LibraryUnplayedCounts.load(container: context.container, podcastIDs: [id])
        XCTAssertTrue(LibraryPodcastFilter.includes(unplayedCount: counts[id], hideCaughtUp: true))
        episode.isPlayed = true
        try context.save()
        counts = try await LibraryUnplayedCounts.load(container: context.container, podcastIDs: [id])
        XCTAssertFalse(LibraryPodcastFilter.includes(unplayedCount: counts[id], hideCaughtUp: true))
        episode.isPlayed = false
        try context.save()
        counts = try await LibraryUnplayedCounts.load(container: context.container, podcastIDs: [id])
        XCTAssertTrue(LibraryPodcastFilter.includes(unplayedCount: counts[id], hideCaughtUp: true))
        XCTAssertTrue(podcast.isFollowed)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Episode>()), 1)
    }

    func testRemovedFocusPrefersNextThenPreviousSurvivorAndHandlesEmptyLibrary() {
        XCTAssertEqual(LibraryPodcastFilter.replacementFocus(removed: 2, previous: [1, 2, 3], remaining: [1, 3]), 3)
        XCTAssertEqual(LibraryPodcastFilter.replacementFocus(removed: 3, previous: [1, 2, 3], remaining: [1, 2]), 2)
        XCTAssertNil(LibraryPodcastFilter.replacementFocus(removed: 1, previous: [1], remaining: []))
    }
}
