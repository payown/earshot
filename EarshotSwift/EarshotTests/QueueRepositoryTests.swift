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

        repo.playGroup(pb)

        XCTAssertEqual(titles(repo), ["Ep b1", "Ep a1", "Ep a2"])
    }
}
