import XCTest
import SwiftData
@testable import Earshot

@MainActor
final class QueueRepositoryTests: XCTestCase {

    // MARK: Fixtures

    private func makePodcast(_ ctx: ModelContext, _ title: String, autoQueue: Bool = false) -> Podcast {
        let p = Podcast(feedURL: "https://x/\(title).xml", title: title, autoQueue: autoQueue)
        ctx.insert(p)
        return p
    }

    private func makeEpisode(_ ctx: ModelContext, _ guid: String, podcast: Podcast) -> Episode {
        let e = Episode(guid: guid, title: "Ep \(guid)", audioURL: "https://x/\(guid).mp3")
        e.podcast = podcast
        ctx.insert(e)
        return e
    }

    /// Titles of the episodes currently in the queue, in order.
    private func titles(_ repo: QueueRepository) -> [String] {
        repo.queue().map(\.title)
    }

    // MARK: add / status transitions

    func testAddAppendsToEndAndSetsStatusInQueue() {
        let ctx = TestStore.freshContext()
        let p = makePodcast(ctx, "A")
        let a = makeEpisode(ctx, "a", podcast: p)
        let b = makeEpisode(ctx, "b", podcast: p)
        let repo = QueueRepository(context: ctx)

        repo.add(a)
        repo.add(b)

        XCTAssertEqual(titles(repo), ["Ep a", "Ep b"])
        XCTAssertEqual(a.status, .inQueue)
        XCTAssertEqual(b.status, .inQueue)
    }

    func testAddIsIdempotentAndDoesNotDuplicate() {
        let ctx = TestStore.freshContext()
        let p = makePodcast(ctx, "A")
        let a = makeEpisode(ctx, "a", podcast: p)
        let repo = QueueRepository(context: ctx)

        repo.add(a)
        repo.add(a)

        XCTAssertEqual(titles(repo), ["Ep a"])
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<QueueItem>()), 1)
    }

    func testQueuePositionsCompactToZeroBasedRange() {
        let ctx = TestStore.freshContext()
        let p = makePodcast(ctx, "A")
        let eps = (0..<3).map { makeEpisode(ctx, "\($0)", podcast: p) }
        let repo = QueueRepository(context: ctx)
        eps.forEach(repo.add)

        let positions = repo.queue().compactMap { $0.queueItem?.position }
        XCTAssertEqual(positions, [0, 1, 2])
    }

    func testAddToFrontInsertsAtFrontWhenAbsent() {
        let ctx = TestStore.freshContext()
        let p = makePodcast(ctx, "A")
        let a = makeEpisode(ctx, "a", podcast: p)
        let b = makeEpisode(ctx, "b", podcast: p)
        let repo = QueueRepository(context: ctx)

        repo.add(a)
        repo.addToFront(b)

        XCTAssertEqual(titles(repo), ["Ep b", "Ep a"])
        XCTAssertEqual(b.status, .inQueue)
    }

    func testAddToFrontLeavesAlreadyQueuedEpisodeInPlace() {
        let ctx = TestStore.freshContext()
        let p = makePodcast(ctx, "A")
        let a = makeEpisode(ctx, "a", podcast: p)
        let b = makeEpisode(ctx, "b", podcast: p)
        let repo = QueueRepository(context: ctx)
        repo.add(a)
        repo.add(b)

        repo.addToFront(b) // already queued -> stays where it is

        XCTAssertEqual(titles(repo), ["Ep a", "Ep b"])
    }

    func testAddAfterCurrentInsertsAtSecondPosition() {
        let ctx = TestStore.freshContext()
        let p = makePodcast(ctx, "A")
        let eps = ["a", "b", "c"].map { makeEpisode(ctx, $0, podcast: p) }
        let repo = QueueRepository(context: ctx)
        eps.forEach(repo.add)
        let d = makeEpisode(ctx, "d", podcast: p)

        repo.addAfterCurrent(d)

        XCTAssertEqual(titles(repo), ["Ep a", "Ep d", "Ep b", "Ep c"])
    }

    func testCancelFromQueueRemovesAndRevertsToNewEpisode() {
        let ctx = TestStore.freshContext()
        let p = makePodcast(ctx, "A")
        let a = makeEpisode(ctx, "a", podcast: p)
        let repo = QueueRepository(context: ctx)
        repo.add(a)

        repo.cancelFromQueue(a)

        XCTAssertTrue(repo.queue().isEmpty)
        XCTAssertEqual(a.status, .newEpisode)
        XCTAssertNil(a.queueItem)
    }

    func testMarkPlayedAndRemoveSetsPlayedAndPreservesPosition() {
        let ctx = TestStore.freshContext()
        let p = makePodcast(ctx, "A")
        let a = makeEpisode(ctx, "a", podcast: p)
        a.positionSeconds = 42
        let repo = QueueRepository(context: ctx)
        repo.add(a)

        repo.markPlayedAndRemove(a)

        XCTAssertTrue(repo.queue().isEmpty)
        XCTAssertEqual(a.status, .played)
        XCTAssertNotNil(a.playedAt)
        XCTAssertEqual(a.positionSeconds, 42, "position must not be reset here")
    }

    // MARK: moves

    func testMoveToTopAndBottomPersist() {
        let ctx = TestStore.freshContext()
        let p = makePodcast(ctx, "A")
        let eps = ["a", "b", "c"].map { makeEpisode(ctx, $0, podcast: p) }
        let repo = QueueRepository(context: ctx)
        eps.forEach(repo.add)

        repo.moveToTop(eps[2])
        XCTAssertEqual(titles(repo), ["Ep c", "Ep a", "Ep b"])

        repo.moveToBottom(eps[2])
        XCTAssertEqual(titles(repo), ["Ep a", "Ep b", "Ep c"])
        XCTAssertEqual(repo.queue().compactMap { $0.queueItem?.position }, [0, 1, 2])
    }

    func testMoveUpDownAndReorderPersist() {
        let ctx = TestStore.freshContext()
        let p = makePodcast(ctx, "A")
        let eps = ["a", "b", "c", "d"].map { makeEpisode(ctx, $0, podcast: p) }
        let repo = QueueRepository(context: ctx)
        eps.forEach(repo.add)

        repo.moveUp(eps[2])
        XCTAssertEqual(titles(repo), ["Ep a", "Ep c", "Ep b", "Ep d"])

        repo.moveDown(eps[0])
        XCTAssertEqual(titles(repo), ["Ep c", "Ep a", "Ep b", "Ep d"])

        repo.move(eps[3], toIndex: 0)
        XCTAssertEqual(titles(repo), ["Ep d", "Ep c", "Ep a", "Ep b"])
    }

    func testClearEmptiesQueue() {
        let ctx = TestStore.freshContext()
        let p = makePodcast(ctx, "A")
        let eps = ["a", "b"].map { makeEpisode(ctx, $0, podcast: p) }
        let repo = QueueRepository(context: ctx)
        eps.forEach(repo.add)

        repo.clear()

        XCTAssertTrue(repo.queue().isEmpty)
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<QueueItem>()), 0)
    }

    // MARK: grouping

    func testGroupedQueueGroupsByPodcastInFirstAppearanceOrder() {
        let ctx = TestStore.freshContext()
        let pa = makePodcast(ctx, "A")
        let pb = makePodcast(ctx, "B")
        let a1 = makeEpisode(ctx, "a1", podcast: pa)
        let b1 = makeEpisode(ctx, "b1", podcast: pb)
        let a2 = makeEpisode(ctx, "a2", podcast: pa)
        let repo = QueueRepository(context: ctx)
        [a1, b1, a2].forEach(repo.add)

        let groups = repo.groupedQueue()

        XCTAssertEqual(groups.map { $0.podcast.title }, ["A", "B"])
        XCTAssertEqual(groups[0].episodes.map(\.title), ["Ep a1", "Ep a2"])
        XCTAssertEqual(groups[1].episodes.map(\.title), ["Ep b1"])
    }

    func testPlayGroupBringsPodcastEpisodesToFront() {
        let ctx = TestStore.freshContext()
        let pa = makePodcast(ctx, "A")
        let pb = makePodcast(ctx, "B")
        let a1 = makeEpisode(ctx, "a1", podcast: pa)
        let b1 = makeEpisode(ctx, "b1", podcast: pb)
        let a2 = makeEpisode(ctx, "a2", podcast: pa)
        let repo = QueueRepository(context: ctx)
        [a1, b1, a2].forEach(repo.add)

        let front = repo.playGroup(pb)

        XCTAssertEqual(titles(repo), ["Ep b1", "Ep a1", "Ep a2"])
        XCTAssertEqual(front?.title, "Ep b1", "returns the episode now at the group front")
    }

    // MARK: group actions (#445)

    /// Builds a two-podcast queue interleaved as [a1, b1, a2, b2, a3] with A
    /// episode pub dates a1=day1, a2=day3, a3=day2 and B dates b1=day10, b2=day5.
    private func makeInterleavedGroups(
        _ ctx: ModelContext
    ) -> (repo: QueueRepository, pa: Podcast, pb: Podcast, a: [Episode], b: [Episode]) {
        let pa = makePodcast(ctx, "A")
        let pb = makePodcast(ctx, "B")
        func ep(_ guid: String, _ podcast: Podcast, day: Double) -> Episode {
            let e = makeEpisode(ctx, guid, podcast: podcast)
            e.pubDate = Date(timeIntervalSince1970: day * 86_400)
            return e
        }
        let a1 = ep("a1", pa, day: 1)
        let a2 = ep("a2", pa, day: 3)
        let a3 = ep("a3", pa, day: 2)
        let b1 = ep("b1", pb, day: 10)
        let b2 = ep("b2", pb, day: 5)
        let repo = QueueRepository(context: ctx)
        [a1, b1, a2, b2, a3].forEach(repo.add)
        return (repo, pa, pb, [a1, a2, a3], [b1, b2])
    }

    func testPlayNewestFirstReordersGroupAndKeepsOtherGroupOrder() {
        let ctx = TestStore.freshContext()
        let g = makeInterleavedGroups(ctx)

        let front = g.repo.playNewestFirst(g.pa)

        XCTAssertEqual(titles(g.repo), ["Ep a2", "Ep a3", "Ep a1", "Ep b1", "Ep b2"])
        XCTAssertEqual(front?.title, "Ep a2", "newest A episode is at the front")
    }

    func testPlayOldestFirstReordersGroupAndKeepsOtherGroupOrder() {
        let ctx = TestStore.freshContext()
        let g = makeInterleavedGroups(ctx)

        let front = g.repo.playOldestFirst(g.pa)

        XCTAssertEqual(titles(g.repo), ["Ep a1", "Ep a3", "Ep a2", "Ep b1", "Ep b2"])
        XCTAssertEqual(front?.title, "Ep a1", "oldest A episode is at the front")
    }

    func testShuffleGroupBringsGroupToFrontAndKeepsOtherGroupOrder() {
        let ctx = TestStore.freshContext()
        let g = makeInterleavedGroups(ctx)

        let front = g.repo.shuffleGroup(g.pa)

        let result = titles(g.repo)
        // The three A episodes occupy the front (some order), B keeps [b1, b2].
        XCTAssertEqual(Set(result.prefix(3)), ["Ep a1", "Ep a2", "Ep a3"])
        XCTAssertEqual(Array(result.suffix(2)), ["Ep b1", "Ep b2"])
        XCTAssertEqual(front?.title, result.first, "returns the new front episode")
        XCTAssertTrue(["Ep a1", "Ep a2", "Ep a3"].contains(front?.title ?? ""))
    }

    func testGroupActionsOnEmptyGroupReturnNilAndMakeNoChange() {
        let ctx = TestStore.freshContext()
        let g = makeInterleavedGroups(ctx)
        let pc = makePodcast(ctx, "C") // never queued
        let before = titles(g.repo)

        XCTAssertNil(g.repo.playGroup(pc))
        XCTAssertNil(g.repo.playNewestFirst(pc))
        XCTAssertNil(g.repo.playOldestFirst(pc))
        XCTAssertNil(g.repo.shuffleGroup(pc))
        XCTAssertEqual(titles(g.repo), before, "an empty group leaves the queue untouched")
    }

    func testSingleEpisodeGroupReturnsThatEpisodeAndBringsItToFront() {
        let ctx = TestStore.freshContext()
        let pa = makePodcast(ctx, "A")
        let pb = makePodcast(ctx, "B")
        let a1 = makeEpisode(ctx, "a1", podcast: pa)
        let b1 = makeEpisode(ctx, "b1", podcast: pb)
        let repo = QueueRepository(context: ctx)
        [a1, b1].forEach(repo.add)

        let front = repo.playNewestFirst(pb)

        XCTAssertEqual(front?.title, "Ep b1")
        XCTAssertEqual(titles(repo), ["Ep b1", "Ep a1"])
    }
}
