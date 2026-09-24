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

    func testMembershipSelectionsIgnoreOtherScopesDuplicatesAndMissingRelationships() {
        let context = TestStore.freshContext()
        let first = makePodcast(context, "First")
        let second = makePodcast(context, "Second")
        let root = PodcastFolder(name: "Root")
        let child = PodcastFolder(name: "Child")
        context.insert(root)
        context.insert(child)
        child.parent = root
        let rows = [
            FolderMembership(folder: root, podcast: first),
            FolderMembership(folder: root, podcast: first),
            FolderMembership(folder: child, podcast: first),
            FolderMembership(folder: child, podcast: second),
            FolderMembership(folder: root, podcast: nil),
            FolderMembership(folder: nil, podcast: first),
        ]
        XCTAssertEqual(FolderMembershipSelection.podcastIDs(in: root, memberships: rows), [first.persistentModelID])
        XCTAssertEqual(FolderMembershipSelection.folderIDs(for: first, memberships: rows), [root.persistentModelID, child.persistentModelID])
        XCTAssertEqual(FolderMembershipSelection.folderIDs(for: second, memberships: rows), [child.persistentModelID])
        XCTAssertTrue(FolderMembershipSelection.podcastIDs(in: root, memberships: []).isEmpty)
        XCTAssertTrue(FolderMembershipSelection.folderIDs(for: first, memberships: []).isEmpty)
    }

    func testMembershipSelectionRebuildsAfterAddRemoveAndNewFolder() throws {
        let context = TestStore.freshContext()
        let podcast = makePodcast(context, "Show")
        let repo = FolderRepository(context: context)
        let folder = repo.createFolder(name: "First")
        func rows() throws -> [FolderMembership] { try context.fetch(FetchDescriptor<FolderMembership>()) }
        XCTAssertTrue(FolderMembershipSelection.folderIDs(for: podcast, memberships: try rows()).isEmpty)
        repo.add(podcast, to: folder)
        XCTAssertEqual(FolderMembershipSelection.folderIDs(for: podcast, memberships: try rows()), [folder.persistentModelID])
        XCTAssertEqual(FolderMembershipSelection.podcastIDs(in: folder, memberships: try rows()), [podcast.persistentModelID])
        repo.remove(podcast, from: folder)
        XCTAssertTrue(FolderMembershipSelection.podcastIDs(in: folder, memberships: try rows()).isEmpty)
        let created = repo.createSubfolder(named: "New child", under: folder)
        repo.add(podcast, to: created)
        XCTAssertEqual(FolderMembershipSelection.folderIDs(for: podcast, memberships: try rows()), [created.persistentModelID])
        XCTAssertTrue(FolderMembershipSelection.podcastIDs(in: folder, memberships: try rows()).isEmpty,
                      "Picker membership is direct, not inherited from child folders")
    }

    func testSelectionSetsMatchLegacyRowScansAtLibraryScale() {
        let podcasts = (0..<500).map { Podcast(feedURL: "https://example.com/\($0).xml", title: "Show \($0)") }
        let folders = (0..<20).map { PodcastFolder(name: "Folder \($0)") }
        let rows = (0..<2000).map { index in
            FolderMembership(folder: folders[index % 20], podcast: podcasts[index % 500])
        }
        let folderID = folders[0].persistentModelID
        let start = Date()
        let legacy = Set(podcasts.filter { podcast in
            rows.contains { $0.podcast?.persistentModelID == podcast.persistentModelID && $0.folder?.persistentModelID == folderID }
        }.map(\.persistentModelID))
        let legacySeconds = Date().timeIntervalSince(start)
        let indexedStart = Date()
        let actual = FolderMembershipSelection.podcastIDs(in: folders[0], memberships: rows)
        let indexedSeconds = Date().timeIntervalSince(indexedStart)
        XCTAssertEqual(actual, legacy)
        XCTAssertEqual(actual.count, 25)
        let podcastID = podcasts[0].persistentModelID
        let legacyFolders = Set(folders.filter { folder in
            rows.contains { $0.podcast?.persistentModelID == podcastID && $0.folder?.persistentModelID == folder.persistentModelID }
        }.map(\.persistentModelID))
        XCTAssertEqual(FolderMembershipSelection.folderIDs(for: podcasts[0], memberships: rows), legacyFolders)
        print("Folder picker simulator diagnostic: legacy=\(legacySeconds)s selectionSet=\(indexedSeconds)s; 500 podcasts/2000 memberships")
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
            "Moved 3 episodes to News › Daily only"
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
            "Moved 2 podcasts to Tech only"
        )
    }

    // MARK: Copy

    func testTitleAndHintsReflectMode() {
        XCTAssertEqual(FolderPickerView.title(mode: .add), "Add to another folder")
        XCTAssertEqual(FolderPickerView.title(mode: .move), "Move to one folder")
        XCTAssertEqual(
            FolderPickerView.instruction(mode: .add),
            "Choose a folder. Current folders will be kept."
        )
        XCTAssertEqual(
            FolderPickerView.instruction(mode: .move),
            "Choose one folder. Other folder assignments will be removed."
        )
        XCTAssertTrue(FolderPickerView.rowHint(mode: .add).contains("keeps"))
        XCTAssertTrue(FolderPickerView.rowHint(mode: .move).contains("all other folders"))
        XCTAssertFalse(FolderPickerView.emptyStateText.isEmpty)
    }

    func testMoveConfirmationNamesRemovedFoldersAndExclusiveDestination() {
        XCTAssertEqual(
            FolderPickerView.moveConfirmationTitle(path: "Commute"),
            "Move to Commute?"
        )
        XCTAssertEqual(
            FolderPickerView.moveConfirmationMessage(
                sourcePaths: ["News", "Favorites"], targetPath: "Commute"
            ),
            "Folder assignments to News and Favorites will be removed. The selection will be kept only in Commute."
        )
    }

    func testMoveConfirmationWithoutExistingFoldersStillStatesExclusiveResult() {
        XCTAssertEqual(
            FolderPickerView.moveConfirmationMessage(sourcePaths: [], targetPath: "Commute"),
            "The selection will be kept only in Commute."
        )
    }

    func testNewFolderCopyExplainsWhetherExistingFoldersRemain() {
        XCTAssertEqual(FolderPickerView.createButtonTitle(mode: .add), "Create and add")
        XCTAssertEqual(FolderPickerView.createButtonTitle(mode: .move), "Create and move")
        XCTAssertEqual(
            FolderPickerView.newFolderMessage(mode: .add, sourcePaths: ["News"]),
            "Enter a name. Current folders will be kept."
        )
        XCTAssertEqual(
            FolderPickerView.newFolderMessage(
                mode: .move, sourcePaths: ["News", "Favorites", "Archive"]
            ),
            "Enter a name. Folder assignments to News, Favorites, and Archive will be removed. The selection will be kept only in the new folder."
        )
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
