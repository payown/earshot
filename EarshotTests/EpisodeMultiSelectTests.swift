import XCTest
import SwiftData
@testable import Earshot

/// Covers episode multi-select (folders phase 2, #758): the episode-noun batch
/// labels (folder ones reused from ``MultiSelectActionLabel``, queue/played from
/// ``EpisodeBatchLabel``), the shared selection-state holder driving an episode
/// selection, the episode batch request factory, and that a batch routes to the
/// matching ``FolderRepository`` episode path. The selection-state holder itself
/// (toggle/count/clear/enter/exit) is exercised generically in
/// ``MultiSelectStateTests`` — here it's driven with episode identities to prove
/// the same scaffold backs episodes unchanged.
@MainActor
final class EpisodeMultiSelectTests: XCTestCase {

    private func makePodcast(_ ctx: ModelContext, _ title: String) -> Podcast {
        let podcast = Podcast(feedURL: "https://x/\(title).xml", title: title)
        ctx.insert(podcast)
        return podcast
    }

    @discardableResult
    private func makeEpisode(
        _ ctx: ModelContext, _ podcast: Podcast, guid: String
    ) -> Episode {
        let episode = Episode(guid: guid, title: "Ep \(guid)", audioURL: "https://x/\(guid).mp3", pubDate: nil)
        episode.podcast = podcast
        ctx.insert(episode)
        return episode
    }

    // MARK: Folder batch labels carry the episode noun

    func testFolderLabelsUseEpisodeNoun() {
        XCTAssertEqual(MultiSelectActionLabel.addToFolder(count: 3, itemSingular: "episode"), "Add 3 episodes to another folder")
        XCTAssertEqual(MultiSelectActionLabel.addToFolder(count: 1, itemSingular: "episode"), "Add 1 episode to another folder")
        XCTAssertEqual(MultiSelectActionLabel.moveToFolder(count: 2, itemSingular: "episode"), "Move 2 episodes to one folder")
        // Zero-selection reads cleanly (the button is disabled in that state).
        XCTAssertEqual(MultiSelectActionLabel.addToFolder(count: 0, itemSingular: "episode"), "Add to another folder")
    }

    func testSelectedCountAnnouncementUsesEpisodeNoun() {
        XCTAssertEqual(MultiSelectActionLabel.selectedCount(3, itemSingular: "episode"), "3 episodes selected")
        XCTAssertEqual(MultiSelectActionLabel.selectedCount(1, itemSingular: "episode"), "1 episode selected")
        XCTAssertEqual(MultiSelectActionLabel.selectedCount(0, itemSingular: "episode"), "")
    }

    // MARK: Episode-only batch labels (queue / mark played)

    func testAddToQueueLabelCarriesLiveCount() {
        XCTAssertEqual(EpisodeBatchLabel.addToQueue(count: 3), "Add 3 episodes to queue")
        XCTAssertEqual(EpisodeBatchLabel.addToQueue(count: 1), "Add 1 episode to queue")
        XCTAssertEqual(EpisodeBatchLabel.addToQueue(count: 0), "Add to queue")
    }

    func testMarkPlayedLabelCarriesLiveCount() {
        XCTAssertEqual(EpisodeBatchLabel.markPlayed(count: 4), "Mark 4 episodes as played")
        XCTAssertEqual(EpisodeBatchLabel.markPlayed(count: 1), "Mark 1 episode as played")
        XCTAssertEqual(EpisodeBatchLabel.markPlayed(count: 0), "Mark as played")
    }

    // MARK: The shared selection holder, driven with episode identities

    func testSelectionHoldsEpisodeIdentitiesAndFiltersDisplayOrder() {
        let ctx = TestStore.freshContext()
        let podcast = makePodcast(ctx, "Show")
        let e1 = makeEpisode(ctx, podcast, guid: "e1")
        let e2 = makeEpisode(ctx, podcast, guid: "e2")
        let e3 = makeEpisode(ctx, podcast, guid: "e3")
        let visible = [e1, e2, e3]

        let state = MultiSelectState()
        state.enter()
        state.toggle(e1.persistentModelID)
        state.toggle(e3.persistentModelID)

        XCTAssertEqual(state.count, 2)
        // The screens derive the batch from the display order, filtering the
        // visible list by the holder — proving selection survives as identities.
        let selected = visible.filter { state.isSelected($0.persistentModelID) }
        XCTAssertEqual(selected.map(\.guid), ["e1", "e3"])
    }

    // MARK: Batch routes to the matching episode repository path

    func testAddBatchFilesEverySelectedEpisodeKeepingExisting() {
        let ctx = TestStore.freshContext()
        let repo = FolderRepository(context: ctx)
        let a = repo.createFolder(name: "A")
        let target = repo.createFolder(name: "Target")
        let podcast = makePodcast(ctx, "Show")
        let e1 = makeEpisode(ctx, podcast, guid: "e1")
        let e2 = makeEpisode(ctx, podcast, guid: "e2")
        repo.addEpisodes([e1], to: a) // pre-existing membership in A

        FolderPickerView.apply(mode: .add, episodes: [e1, e2], podcasts: [], to: target, using: repo)

        // Add keeps A for e1 and files both into Target.
        XCTAssertEqual(Set(repo.folders(containing: e1).map(\.name)), ["A", "Target"])
        XCTAssertEqual(Set(repo.episodes(in: target).map(\.guid)), ["e1", "e2"])
    }

    func testMoveBatchRelocatesEverySelectedEpisodeIntoTargetOnly() {
        let ctx = TestStore.freshContext()
        let repo = FolderRepository(context: ctx)
        let a = repo.createFolder(name: "A")
        let target = repo.createFolder(name: "Target")
        let podcast = makePodcast(ctx, "Show")
        let e1 = makeEpisode(ctx, podcast, guid: "e1")
        let e2 = makeEpisode(ctx, podcast, guid: "e2")
        repo.addEpisodes([e1], to: a)

        FolderPickerView.apply(mode: .move, episodes: [e1, e2], podcasts: [], to: target, using: repo)

        XCTAssertEqual(Set(repo.folders(containing: e1).map(\.name)), ["Target"])
        XCTAssertTrue(repo.episodes(in: a).isEmpty)
        XCTAssertEqual(repo.episodes(in: target).count, 2)
    }

    // MARK: Batch request factory

    func testEpisodesBatchFactoryCarriesModeAndItems() {
        let ctx = TestStore.freshContext()
        let podcast = makePodcast(ctx, "Show")
        let e1 = makeEpisode(ctx, podcast, guid: "e1")
        let e2 = makeEpisode(ctx, podcast, guid: "e2")

        let req = FolderPickRequest.episodes([e1, e2], mode: .move)

        XCTAssertEqual(req.episodes.count, 2)
        XCTAssertTrue(req.podcasts.isEmpty)
        XCTAssertEqual(req.mode, .move)
    }
}
