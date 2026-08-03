import XCTest
import SwiftData
@testable import Earshot

/// VoiceOver wording and reorder/go-up behavior for the folder-detail drill-down
/// (folders phase 1 — #753). The spoken strings are pure (``FolderDetailLabel``);
/// the go-up visibility and non-drag reorder are exercised through the repository
/// so the focus/announcement contract the screen relies on is pinned.
@MainActor
final class FolderDetailLabelTests: XCTestCase {

    // MARK: Subfolder row label — counts spoken, not implied by indentation

    func testSubfolderRowSpeaksBothCountsAndKind() {
        let label = FolderDetailLabel.subfolderRow(name: "News", subfolderCount: 2, podcastCount: 5)
        XCTAssertEqual(label, "News, 2 subfolders, 5 podcasts, folder")
    }

    func testSubfolderRowSingularCounts() {
        let label = FolderDetailLabel.subfolderRow(name: "Daily", subfolderCount: 1, podcastCount: 1)
        XCTAssertEqual(label, "Daily, 1 subfolder, 1 podcast, folder")
    }

    func testSubfolderRowZeroCountsStillSpoken() {
        // An empty subfolder must still say "0 subfolders, 0 podcasts" so its
        // shape is never left to visual indentation.
        let label = FolderDetailLabel.subfolderRow(name: "Empty", subfolderCount: 0, podcastCount: 0)
        XCTAssertEqual(label, "Empty, 0 subfolders, 0 podcasts, folder")
    }

    // MARK: Breadcrumb

    func testBreadcrumbJoinsPathWithCommasAndPrefix() {
        // Comma-joined, not the visual `›`, so VoiceOver reads it cleanly.
        let label = FolderDetailLabel.breadcrumb(path: ["News", "Tech", "Apple"])
        XCTAssertEqual(label, "Folder path: News, Tech, Apple")
    }

    func testBreadcrumbSingleLevel() {
        XCTAssertEqual(FolderDetailLabel.breadcrumb(path: ["News"]), "Folder path: News")
    }

    func testBreadcrumbEmptyPathDegradesGracefully() {
        XCTAssertEqual(FolderDetailLabel.breadcrumb(path: []), "Folder path")
    }

    /// The visible breadcrumb (`pathString`) and the spoken breadcrumb describe
    /// the same trail — one with the visual separator, one comma-joined.
    func testVisibleAndSpokenBreadcrumbAgreeOnTheSamePath() {
        let ctx = TestStore.freshContext()
        let repo = FolderRepository(context: ctx)
        let news = repo.createFolder(name: "News")
        let daily = repo.createSubfolder(named: "Daily", under: news)

        XCTAssertEqual(FolderLogic.pathString(daily), "News › Daily")
        XCTAssertEqual(
            FolderDetailLabel.breadcrumb(path: FolderLogic.folderPath(daily).map(\.name)),
            "Folder path: News, Daily"
        )
    }

    // MARK: Reorder announcement

    func testMoveAnnouncementWording() {
        XCTAssertEqual(
            FolderDetailLabel.moveAnnouncement(name: "Tech", position: 2, count: 3),
            "Moved Tech to position 2 of 3"
        )
    }

    // MARK: Folder Inbox + listening actions (#763)

    func testNewEpisodesSectionHasExplicitHeaderAndEmptyDescription() {
        XCTAssertEqual(FolderDetailLabel.newEpisodesSectionHeader, "New episodes")
        XCTAssertEqual(FolderDetailLabel.newEpisodesEmptyTitle, "No new episodes")
        XCTAssertEqual(
            FolderDetailLabel.newEpisodesEmptyDescription,
            "New episodes from podcasts in this folder and its subfolders appear here."
        )
    }

    func testListeningAnnouncementsCarryCountsAndFolderContext() {
        XCTAssertEqual(FolderDetailLabel.queueAllAnnouncement(count: 1), "Added 1 episode to the queue")
        XCTAssertEqual(FolderDetailLabel.queueAllAnnouncement(count: 3), "Added 3 episodes to the queue")
        XCTAssertEqual(
            FolderDetailLabel.playAllAnnouncement(count: 2, folderName: "News"),
            "Playing 2 episodes from News. Added to the queue."
        )
    }

    // MARK: Episodes section (#759) — header, empty state, remove announcement

    func testEpisodesSectionHeaderIsPlainSpokenLabel() {
        // A real, plain "Episodes" header string — carried into an `.isHeader`
        // section header on the screen so VoiceOver can reach it by heading.
        XCTAssertEqual(FolderDetailLabel.episodesSectionHeader, "Episodes")
    }

    func testEpisodesEmptyStateSpeaksTitleAndHowToAdd() {
        // Never a blank section: the empty state names the state and says how
        // episodes get into a folder (they're hand-picked from an episode's
        // actions, not added on this screen).
        XCTAssertEqual(FolderDetailLabel.episodesEmptyTitle, "No episodes in this folder")
        XCTAssertEqual(
            FolderDetailLabel.episodesEmptyDescription,
            "Add an episode to this folder from its actions, using Add to another folder."
        )
    }

    func testRemoveEpisodeAnnouncementNamesEpisodeAndFolder() {
        XCTAssertEqual(
            FolderDetailLabel.removeEpisodeAnnouncement(title: "Ep 42", folderName: "News"),
            "Removed Ep 42 from News"
        )
    }

    // MARK: Go-up visibility — only when the folder has a parent

    func testTopLevelFolderHasNoParentSoGoUpIsHidden() {
        let ctx = TestStore.freshContext()
        let repo = FolderRepository(context: ctx)
        let root = repo.createFolder(name: "News")
        XCTAssertNil(root.parent, "A top-level folder shows no go-up affordance")
    }

    func testSubfolderHasParentSoGoUpIsShown() {
        let ctx = TestStore.freshContext()
        let repo = FolderRepository(context: ctx)
        let root = repo.createFolder(name: "News")
        let child = repo.createSubfolder(named: "Daily", under: root)
        XCTAssertEqual(child.parent?.name, "News", "A nested folder shows go-up to its parent")
    }

    // MARK: Non-drag subfolder reorder — persistence + focus/announcement contract

    func testSubfolderReorderPersistsSiblingOrder() {
        let ctx = TestStore.freshContext()
        let repo = FolderRepository(context: ctx)
        let parent = repo.createFolder(name: "News")
        let a = repo.createSubfolder(named: "A", under: parent)
        let b = repo.createSubfolder(named: "B", under: parent)
        let c = repo.createSubfolder(named: "C", under: parent)

        // Mirror the screen's moveSubfolders: move "C" (index 2) to the top.
        var reordered = repo.childFolders(of: parent)
        reordered.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        repo.reorderFolders(reordered)

        XCTAssertEqual(repo.childFolders(of: parent).map(\.name), ["C", "A", "B"])
        // Sanity: the moved node kept its identity (focus re-anchors on it).
        XCTAssertEqual(repo.childFolders(of: parent).first?.persistentModelID, c.persistentModelID)
        _ = (a, b)
    }

    /// The rotor "Move to top" on the last of three rows lands it at index 0, and
    /// the announcement reports position 1 of 3 — the same value the screen uses
    /// to re-anchor VoiceOver focus on the moved row.
    func testMoveToTopTargetDrivesAnnouncementAndFocusPosition() {
        let targets = QuickActionMoveLogic.targets(index: 2, count: 3)
        guard let toTop = targets.first(where: { $0.label == "Move to top" }) else {
            return XCTFail("Move to top action should be offered on a non-first row")
        }
        XCTAssertEqual(toTop.resultingIndex, 0)
        XCTAssertEqual(
            FolderDetailLabel.moveAnnouncement(
                name: "C", position: toTop.resultingIndex + 1, count: 3
            ),
            "Moved C to position 1 of 3"
        )
    }

    /// The first subfolder row offers only downward moves (no redundant "up"
    /// edges), matching every other reorderable list in the app.
    func testFirstSubfolderRowOffersOnlyDownwardMoves() {
        let labels = QuickActionMoveLogic.targets(index: 0, count: 3).map(\.label)
        XCTAssertEqual(labels, ["Move down", "Move to bottom"])
    }

    /// The screen derives its Subfolders section by sorting the tracked
    /// `parent.children` relationship (so SwiftUI's Observation re-renders on a
    /// reorder), then persists the new order with `reorderFolders`. This asserts
    /// that read path stays in lock-step with `childFolders(of:)` after a move —
    /// the reactivity fix for the "announced but didn't move" hazard.
    func testChildrenRelationshipSortMatchesRepositoryOrderAfterReorder() {
        let ctx = TestStore.freshContext()
        let repo = FolderRepository(context: ctx)
        let parent = repo.createFolder(name: "News")
        _ = repo.createSubfolder(named: "A", under: parent)
        _ = repo.createSubfolder(named: "B", under: parent)
        _ = repo.createSubfolder(named: "C", under: parent)

        // The screen's `subfolders` computed: sort the tracked relationship.
        func screenOrder() -> [String] {
            parent.children
                .sorted { lhs, rhs in
                    lhs.sortOrder != rhs.sortOrder ? lhs.sortOrder < rhs.sortOrder : lhs.name < rhs.name
                }
                .map(\.name)
        }

        XCTAssertEqual(screenOrder(), ["A", "B", "C"])
        XCTAssertEqual(screenOrder(), repo.childFolders(of: parent).map(\.name))

        // Move "C" to the top the way the screen does, then persist.
        var reordered = repo.childFolders(of: parent)
        reordered.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        repo.reorderFolders(reordered)

        XCTAssertEqual(screenOrder(), ["C", "A", "B"])
        XCTAssertEqual(screenOrder(), repo.childFolders(of: parent).map(\.name))
    }
}
