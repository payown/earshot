import XCTest
import SwiftData
@testable import Earshot

/// Unit tests for the Downloads screen's composed folder, played/unheard, and
/// search filters, plus filter announcements and persistence.
@MainActor
final class DownloadsPlayedFilterTests: XCTestCase {

    private func makePodcast(_ context: ModelContext, _ name: String) -> Podcast {
        let podcast = Podcast(feedURL: "https://example.com/\(name).xml", title: name)
        context.insert(podcast)
        return podcast
    }

    private func makeEpisode(
        _ context: ModelContext,
        podcast: Podcast,
        guid: String,
        title: String,
        isPlayed: Bool = false
    ) -> Episode {
        let episode = Episode(
            guid: guid,
            title: title,
            audioURL: "https://example.com/\(guid).mp3",
            status: isPlayed ? .played : .newEpisode
        )
        episode.podcast = podcast
        context.insert(episode)
        return episode
    }

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

    func testFolderAnnouncementIncludesVisibleCount() {
        XCTAssertEqual(
            DownloadsFilterAnnouncement.folderText(name: "News, Daily", visibleCount: 1),
            "News, Daily, showing 1 episode"
        )
        XCTAssertEqual(
            DownloadsFilterAnnouncement.folderText(name: "All folders", visibleCount: 4),
            "All folders, showing 4 episodes"
        )
    }

    // MARK: Folder + played + search composition

    func testFolderScopeIncludesDescendantPodcastsAndRecentlyExpired() throws {
        let context = TestStore.freshContext()
        let repository = FolderRepository(context: context)
        let root = repository.createFolder(name: "News")
        let child = repository.createSubfolder(named: "Daily", under: root)
        let rootPodcast = makePodcast(context, "Root")
        let childPodcast = makePodcast(context, "Child")
        let otherPodcast = makePodcast(context, "Other")
        repository.add(rootPodcast, to: root)
        repository.add(childPodcast, to: child)

        let rootDownload = makeEpisode(
            context, podcast: rootPodcast, guid: "root", title: "Root report"
        )
        let childDownload = makeEpisode(
            context, podcast: childPodcast, guid: "child", title: "Child report"
        )
        let otherDownload = makeEpisode(
            context, podcast: otherPodcast, guid: "other", title: "Other report"
        )
        let childExpiredEpisode = makeEpisode(
            context, podcast: childPodcast, guid: "child-expired", title: "Expired report"
        )
        let otherExpiredEpisode = makeEpisode(
            context, podcast: otherPodcast, guid: "other-expired", title: "Outside expired"
        )
        let childExpired = RecentlyExpired(episode: childExpiredEpisode)
        let otherExpired = RecentlyExpired(episode: otherExpiredEpisode)
        context.insert(childExpired)
        context.insert(otherExpired)
        try context.save()

        let podcastIDs = Set(
            repository.subtreeSubscriptions(of: root).map(\.persistentModelID)
        )
        let result = DownloadsListFilter.apply(
            downloaded: [rootDownload, childDownload, otherDownload],
            expired: [childExpired, otherExpired],
            podcastIDs: podcastIDs,
            playedFilter: .all,
            searchText: ""
        )

        XCTAssertEqual(result.scopedDownloaded.map(\.guid), ["root", "child"])
        XCTAssertEqual(result.visibleDownloaded.map(\.guid), ["root", "child"])
        XCTAssertEqual(result.scopedExpired.compactMap { $0.episode?.guid }, ["child-expired"])
        XCTAssertEqual(result.visibleExpired.compactMap { $0.episode?.guid }, ["child-expired"])
    }

    func testUnheardAppliesBeforeSearchAndNeverHidesExpired() {
        let context = TestStore.freshContext()
        let podcast = makePodcast(context, "Show")
        let playedMatch = makeEpisode(
            context, podcast: podcast, guid: "played", title: "Daily news", isPlayed: true
        )
        let unheardNoMatch = makeEpisode(
            context, podcast: podcast, guid: "unheard", title: "Weekly digest"
        )
        let expiredMatchEpisode = makeEpisode(
            context, podcast: podcast, guid: "expired", title: "Daily archive", isPlayed: true
        )
        let expiredMatch = RecentlyExpired(episode: expiredMatchEpisode)
        context.insert(expiredMatch)

        let result = DownloadsListFilter.apply(
            downloaded: [playedMatch, unheardNoMatch],
            expired: [expiredMatch],
            podcastIDs: nil,
            playedFilter: .unheard,
            searchText: "daily"
        )

        XCTAssertEqual(result.playedCount, 1)
        XCTAssertTrue(result.visibleDownloaded.isEmpty,
                      "Unheard removes the played title before search")
        XCTAssertEqual(result.visibleExpired.compactMap { $0.episode?.guid }, ["expired"],
                       "Recently Expired follows search but not the played filter")
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
