import XCTest
import SwiftData
@testable import Earshot

/// Covers the reusable multi-select scaffold (folders phase 2, #757): the
/// selection-state holder (toggle / count / clear / enter / exit), the
/// count-carrying batch button labels that are the accessibility source of
/// truth for the running count, and that a podcast batch routes to the matching
/// ``FolderRepository`` path.
@MainActor
final class MultiSelectStateTests: XCTestCase {

    private func makePodcast(_ ctx: ModelContext, _ title: String) -> Podcast {
        let podcast = Podcast(feedURL: "https://x/\(title).xml", title: title)
        ctx.insert(podcast)
        return podcast
    }

    // MARK: Selection state

    func testEnterStartsEmptyAndSelecting() {
        let state = MultiSelectState()
        XCTAssertFalse(state.isSelecting)

        state.enter()

        XCTAssertTrue(state.isSelecting)
        XCTAssertEqual(state.count, 0)
        XCTAssertTrue(state.isEmpty)
    }

    func testToggleAddsAndRemovesAndTracksCount() {
        let ctx = TestStore.freshContext()
        let a = makePodcast(ctx, "A").persistentModelID
        let b = makePodcast(ctx, "B").persistentModelID
        let state = MultiSelectState()
        state.enter()

        XCTAssertTrue(state.toggle(a))   // now selected
        XCTAssertTrue(state.toggle(b))
        XCTAssertEqual(state.count, 2)
        XCTAssertTrue(state.isSelected(a))
        XCTAssertTrue(state.isSelected(b))

        XCTAssertFalse(state.toggle(a))  // now deselected
        XCTAssertEqual(state.count, 1)
        XCTAssertFalse(state.isSelected(a))
        XCTAssertTrue(state.isSelected(b))
    }

    func testClearEmptiesButStaysSelecting() {
        let ctx = TestStore.freshContext()
        let a = makePodcast(ctx, "A").persistentModelID
        let state = MultiSelectState()
        state.enter()
        state.toggle(a)

        state.clear()

        XCTAssertTrue(state.isSelecting)
        XCTAssertEqual(state.count, 0)
    }

    func testExitClearsSelectionAndLeavesMode() {
        let ctx = TestStore.freshContext()
        let a = makePodcast(ctx, "A").persistentModelID
        let state = MultiSelectState()
        state.enter()
        state.toggle(a)

        state.exit()

        XCTAssertFalse(state.isSelecting)
        XCTAssertEqual(state.count, 0)
        XCTAssertFalse(state.isSelected(a))
    }

    // MARK: Batch button labels (the count's accessibility source of truth)

    func testAddToFolderLabelCarriesLiveCount() {
        XCTAssertEqual(MultiSelectActionLabel.addToFolder(count: 3, itemSingular: "podcast"), "Add 3 podcasts to another folder")
        XCTAssertEqual(MultiSelectActionLabel.addToFolder(count: 1, itemSingular: "podcast"), "Add 1 podcast to another folder")
        // Zero-selection reads cleanly (the button is disabled in that state).
        XCTAssertEqual(MultiSelectActionLabel.addToFolder(count: 0, itemSingular: "podcast"), "Add to another folder")
    }

    func testMoveAndRemoveLabelsCarryLiveCount() {
        XCTAssertEqual(MultiSelectActionLabel.moveToFolder(count: 2, itemSingular: "podcast"), "Move 2 podcasts to one folder")
        XCTAssertEqual(MultiSelectActionLabel.removeFromFolder(count: 4, itemSingular: "podcast"), "Remove 4 podcasts from folder")
    }

    func testLabelsAreItemNounAgnosticForEpisodeReuse() {
        // #758 reuses the same labels with the "episode" noun.
        XCTAssertEqual(MultiSelectActionLabel.addToFolder(count: 3, itemSingular: "episode"), "Add 3 episodes to another folder")
    }

    func testSelectedCountAnnouncement() {
        XCTAssertEqual(MultiSelectActionLabel.selectedCount(3, itemSingular: "podcast"), "3 podcasts selected")
        XCTAssertEqual(MultiSelectActionLabel.selectedCount(1, itemSingular: "podcast"), "1 podcast selected")
        // Nothing selected → nothing to announce.
        XCTAssertEqual(MultiSelectActionLabel.selectedCount(0, itemSingular: "podcast"), "")
    }

    // MARK: Batch routes to the matching repository path

    func testAddBatchFilesEverySelectedPodcastKeepingExisting() {
        let ctx = TestStore.freshContext()
        let repo = FolderRepository(context: ctx)
        let a = repo.createFolder(name: "A")
        let target = repo.createFolder(name: "Target")
        let p1 = makePodcast(ctx, "One")
        let p2 = makePodcast(ctx, "Two")
        repo.add(p1, to: a) // pre-existing membership in A

        FolderPickerView.apply(mode: .add, episodes: [], podcasts: [p1, p2], to: target, using: repo)

        // Add keeps A for p1 and files both into Target.
        XCTAssertEqual(Set(repo.folders(containing: p1).map(\.name)), ["A", "Target"])
        XCTAssertEqual(repo.podcasts(in: target).map(\.title), ["One", "Two"])
    }

    func testMoveBatchRelocatesEverySelectedPodcastIntoTargetOnly() {
        let ctx = TestStore.freshContext()
        let repo = FolderRepository(context: ctx)
        let a = repo.createFolder(name: "A")
        let target = repo.createFolder(name: "Target")
        let p1 = makePodcast(ctx, "One")
        let p2 = makePodcast(ctx, "Two")
        repo.add(p1, to: a)

        FolderPickerView.apply(mode: .move, episodes: [], podcasts: [p1, p2], to: target, using: repo)

        XCTAssertEqual(Set(repo.folders(containing: p1).map(\.name)), ["Target"])
        XCTAssertTrue(repo.podcasts(in: a).isEmpty)
        XCTAssertEqual(repo.podcasts(in: target).count, 2)
    }

    func testRemoveBatchDropsMembershipButKeepsPodcast() {
        let ctx = TestStore.freshContext()
        let repo = FolderRepository(context: ctx)
        let folder = repo.createFolder(name: "F")
        let p1 = makePodcast(ctx, "One")
        let p2 = makePodcast(ctx, "Two")
        repo.addPodcasts([p1, p2], to: folder)

        repo.removePodcasts([p1], from: folder)

        // p1 left the folder; p2 stays; both podcasts still exist (subscription
        // untouched).
        XCTAssertEqual(repo.podcasts(in: folder).map(\.title), ["Two"])
        XCTAssertEqual((try? ctx.fetch(FetchDescriptor<Podcast>()))?.count, 2)
    }

    // MARK: Batch request factory

    func testPodcastsBatchFactoryCarriesModeAndItems() {
        let ctx = TestStore.freshContext()
        let p1 = makePodcast(ctx, "One")
        let p2 = makePodcast(ctx, "Two")

        let req = FolderPickRequest.podcasts([p1, p2], mode: .move)

        XCTAssertEqual(req.podcasts.count, 2)
        XCTAssertTrue(req.episodes.isEmpty)
        XCTAssertEqual(req.mode, .move)
    }
}
