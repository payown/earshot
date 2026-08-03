import XCTest
import SwiftData
@testable import Earshot

/// Covers the reusable ``FolderPickerView`` (folders phase 2, #756): the nested
/// tree it renders, the mode → repository-method dispatch a pick performs, and
/// the VoiceOver result announcement wording.
@MainActor
final class FolderPickerViewTests: XCTestCase {

    private func makePodcast(_ ctx: ModelContext, _ title: String) -> Podcast {
        let podcast = Podcast(feedURL: "https://x/\(title).xml", title: title)
        ctx.insert(podcast)
        return podcast
    }

    @discardableResult
    private func makeEpisode(
        _ ctx: ModelContext, _ podcast: Podcast, guid: String, pubDate: Date? = nil
    ) -> Episode {
        let episode = Episode(guid: guid, title: "Ep \(guid)", audioURL: "https://x/\(guid).mp3", pubDate: pubDate)
        episode.podcast = podcast
        ctx.insert(episode)
        return episode
    }

    // MARK: Nested tree construction

    func testOrderedHierarchyIsDepthFirstFromRoots() {
        let ctx = TestStore.freshContext()
        let repo = FolderRepository(context: ctx)
        let news = repo.createSubfolder(named: "News", under: nil)
        let daily = repo.createSubfolder(named: "Daily", under: news)
        repo.createSubfolder(named: "Weekly", under: news)
        let comedy = repo.createSubfolder(named: "Comedy", under: nil)
        repo.createSubfolder(named: "Improv", under: daily)

        let ordered = FolderLogic.orderedHierarchy(from: repo.folders())

        // Depth-first: News, its children Daily (and Daily's child Improv), Weekly,
        // then the second root Comedy.
        XCTAssertEqual(ordered.map(\.name), ["News", "Daily", "Improv", "Weekly", "Comedy"])
        // Each row is labelled by its full breadcrumb path, so depth is spoken.
        XCTAssertEqual(FolderLogic.pathString(daily), "News › Daily")
        XCTAssertEqual(FolderLogic.pathString(comedy), "Comedy")
        // The SPOKEN label/announcement join with commas so VoiceOver reads
        // "News, Daily" instead of voicing the visual `›` glyph (#753 decision;
        // earshot-accessibility gate on #756).
        XCTAssertEqual(FolderLogic.pathString(daily, separator: ", "), "News, Daily")
    }

    func testOrderedHierarchyReflectsNewlyCreatedSubfolder() {
        // The "New folder…" affordance creates a folder; the picker's live @Query
        // then rebuilds the tree. Simulate that: create, then re-derive.
        let ctx = TestStore.freshContext()
        let repo = FolderRepository(context: ctx)
        let news = repo.createSubfolder(named: "News", under: nil)
        let created = repo.createSubfolder(named: "Tech", under: news)

        let ordered = FolderLogic.orderedHierarchy(from: repo.folders())

        XCTAssertEqual(ordered.map(\.name), ["News", "Tech"])
        XCTAssertEqual(FolderLogic.pathString(created), "News › Tech")
    }

    // MARK: Mode → repository dispatch

    func testApplyAddEpisodesFilesIntoFolderKeepingOthers() {
        let ctx = TestStore.freshContext()
        let repo = FolderRepository(context: ctx)
        let a = repo.createFolder(name: "A")
        let b = repo.createFolder(name: "B")
        let podcast = makePodcast(ctx, "Show")
        let e1 = makeEpisode(ctx, podcast, guid: "e1")
        repo.addEpisodes([e1], to: a) // pre-existing membership in A

        FolderPickerView.apply(mode: .add, episodes: [e1], podcasts: [], to: b, using: repo)

        // Add keeps A and adds B.
        XCTAssertEqual(Set(repo.folders(containing: e1).map(\.name)), ["A", "B"])
    }

    func testApplyMoveEpisodesRelocatesIntoTargetOnly() {
        let ctx = TestStore.freshContext()
        let repo = FolderRepository(context: ctx)
        let a = repo.createFolder(name: "A")
        let target = repo.createFolder(name: "Target")
        let podcast = makePodcast(ctx, "Show")
        let e1 = makeEpisode(ctx, podcast, guid: "e1")
        repo.addEpisodes([e1], to: a)

        FolderPickerView.apply(mode: .move, episodes: [e1], podcasts: [], to: target, using: repo)

        XCTAssertEqual(Set(repo.folders(containing: e1).map(\.name)), ["Target"])
        XCTAssertTrue(repo.episodes(in: a).isEmpty)
    }

    func testApplyAddPodcastsFilesIntoFolder() {
        let ctx = TestStore.freshContext()
        let repo = FolderRepository(context: ctx)
        let folder = repo.createFolder(name: "F")
        let p1 = makePodcast(ctx, "One")
        let p2 = makePodcast(ctx, "Two")

        FolderPickerView.apply(mode: .add, episodes: [], podcasts: [p1, p2], to: folder, using: repo)

        XCTAssertEqual(repo.podcasts(in: folder).map(\.title), ["One", "Two"])
    }

    func testApplyMovePodcastsRelocatesIntoTargetOnly() {
        let ctx = TestStore.freshContext()
        let repo = FolderRepository(context: ctx)
        let a = repo.createFolder(name: "A")
        let target = repo.createFolder(name: "Target")
        let p1 = makePodcast(ctx, "One")
        repo.add(p1, to: a)

        FolderPickerView.apply(mode: .move, episodes: [], podcasts: [p1], to: target, using: repo)

        XCTAssertEqual(Set(repo.folders(containing: p1).map(\.name)), ["Target"])
        XCTAssertTrue(repo.podcasts(in: a).isEmpty)
    }

    // MARK: Result announcement wording

    func testResultAnnouncementMoveEpisodesPlural() {
        XCTAssertEqual(
            FolderPickerView.resultAnnouncement(mode: .move, episodeCount: 3, podcastCount: 0, path: "News › Daily"),
            "Moved 3 episodes to News › Daily"
        )
    }

    func testResultAnnouncementAddSingleEpisode() {
        XCTAssertEqual(
            FolderPickerView.resultAnnouncement(mode: .add, episodeCount: 1, podcastCount: 0, path: "News"),
            "Added 1 episode to News"
        )
    }

    func testResultAnnouncementSinglePodcast() {
        XCTAssertEqual(
            FolderPickerView.resultAnnouncement(mode: .add, episodeCount: 0, podcastCount: 1, path: "Comedy"),
            "Added 1 podcast to Comedy"
        )
    }

    func testResultAnnouncementMovePodcastsPlural() {
        XCTAssertEqual(
            FolderPickerView.resultAnnouncement(mode: .move, episodeCount: 0, podcastCount: 2, path: "Tech"),
            "Moved 2 podcasts to Tech"
        )
    }

    // MARK: Copy

    func testTitleAndHintsReflectMode() {
        XCTAssertEqual(FolderPickerView.title(mode: .add), "Add to folder")
        XCTAssertEqual(FolderPickerView.title(mode: .move), "Move to folder")
        XCTAssertTrue(FolderPickerView.rowHint(mode: .add).lowercased().contains("adds"))
        XCTAssertTrue(FolderPickerView.rowHint(mode: .move).lowercased().contains("moves"))
        XCTAssertFalse(FolderPickerView.emptyStateText.isEmpty)
    }

    // MARK: Request factories

    func testRequestFactoriesCarryModeAndItems() {
        let ctx = TestStore.freshContext()
        let podcast = makePodcast(ctx, "Show")
        let episode = makeEpisode(ctx, podcast, guid: "e1")

        let epReq = FolderPickRequest.episode(episode, mode: .move)
        XCTAssertEqual(epReq.episodes.count, 1)
        XCTAssertTrue(epReq.podcasts.isEmpty)
        XCTAssertEqual(epReq.mode, .move)

        let podReq = FolderPickRequest.podcast(podcast, mode: .add)
        XCTAssertEqual(podReq.podcasts.count, 1)
        XCTAssertTrue(podReq.episodes.isEmpty)
        XCTAssertEqual(podReq.mode, .add)
    }
}
