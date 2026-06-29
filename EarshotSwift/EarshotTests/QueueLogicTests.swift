import XCTest
@testable import Earshot

/// Unit tests for the pure queue ordering + grouping rules. No SwiftData, no UI.
/// These operate on plain ordered arrays so the repository can apply the result
/// by reassigning positions 0..N-1 (compaction).
final class QueueLogicTests: XCTestCase {

    // MARK: moveToTop

    func testMoveToTopMovesItemToFront() {
        XCTAssertEqual(QueueLogic.moveToTop([1, 2, 3, 4], 3), [3, 1, 2, 4])
    }

    func testMoveToTopOnFirstItemIsNoOp() {
        XCTAssertEqual(QueueLogic.moveToTop([1, 2, 3], 1), [1, 2, 3])
    }

    func testMoveToTopOnMissingItemIsNoOp() {
        XCTAssertEqual(QueueLogic.moveToTop([1, 2, 3], 9), [1, 2, 3])
    }

    // MARK: moveToBottom

    func testMoveToBottomMovesItemToEnd() {
        XCTAssertEqual(QueueLogic.moveToBottom([1, 2, 3, 4], 2), [1, 3, 4, 2])
    }

    func testMoveToBottomOnLastItemIsNoOp() {
        XCTAssertEqual(QueueLogic.moveToBottom([1, 2, 3], 3), [1, 2, 3])
    }

    // MARK: moveUp / moveDown

    func testMoveUpSwapsWithPreviousNeighbor() {
        XCTAssertEqual(QueueLogic.moveUp([1, 2, 3, 4], 3), [1, 3, 2, 4])
    }

    func testMoveUpOnFirstItemIsNoOp() {
        XCTAssertEqual(QueueLogic.moveUp([1, 2, 3], 1), [1, 2, 3])
    }

    func testMoveDownSwapsWithNextNeighbor() {
        XCTAssertEqual(QueueLogic.moveDown([1, 2, 3, 4], 2), [1, 3, 2, 4])
    }

    func testMoveDownOnLastItemIsNoOp() {
        XCTAssertEqual(QueueLogic.moveDown([1, 2, 3], 3), [1, 2, 3])
    }

    // MARK: move(toIndex:)

    func testMoveToIndexForward() {
        XCTAssertEqual(QueueLogic.move([1, 2, 3, 4], 1, toIndex: 2), [2, 3, 1, 4])
    }

    func testMoveToIndexBackward() {
        XCTAssertEqual(QueueLogic.move([1, 2, 3, 4], 4, toIndex: 0), [4, 1, 2, 3])
    }

    func testMoveToIndexClampsOutOfRange() {
        XCTAssertEqual(QueueLogic.move([1, 2, 3], 1, toIndex: 99), [2, 3, 1])
    }

    // MARK: bringToFront (Play group)

    func testBringToFrontPreservesSubsetOrderAndRemainder() {
        // subset given in [3, 1] order; remainder keeps original relative order.
        XCTAssertEqual(QueueLogic.bringToFront([1, 2, 3, 4, 5], [3, 1]), [3, 1, 2, 4, 5])
    }

    func testBringToFrontIgnoresIdsNotInQueue() {
        XCTAssertEqual(QueueLogic.bringToFront([1, 2, 3], [9, 2]), [2, 1, 3])
    }

    // MARK: grouping by podcast

    func testGroupOrdersByFirstAppearanceAndKeepsQueueOrderWithinGroup() {
        let items: [(id: Int, key: String)] = [
            (1, "A"), (2, "B"), (3, "A"), (4, "C"), (5, "B"),
        ]
        let groups = QueueLogic.group(items)
        XCTAssertEqual(groups, [
            QueueLogic.Group(key: "A", ids: [1, 3]),
            QueueLogic.Group(key: "B", ids: [2, 5]),
            QueueLogic.Group(key: "C", ids: [4]),
        ])
    }

    func testGroupOnEmptyIsEmpty() {
        let items: [(id: Int, key: String)] = []
        XCTAssertTrue(QueueLogic.group(items).isEmpty)
    }

    // MARK: within-group moves

    func testMoveUpWithinGroupSwapsWithPreviousSameGroupItem() {
        // Move id 3 (group A) up: swaps with id 1 (the previous A), not id 2 (B).
        let items: [(id: Int, key: String)] = [(1, "A"), (2, "B"), (3, "A")]
        XCTAssertEqual(QueueLogic.moveUpWithinGroup(items, id: 3), [3, 2, 1])
    }

    func testMoveUpWithinGroupIsNoOpWhenFirstInGroup() {
        let items: [(id: Int, key: String)] = [(1, "A"), (2, "B"), (3, "A")]
        XCTAssertEqual(QueueLogic.moveUpWithinGroup(items, id: 1), [1, 2, 3])
    }

    func testMoveDownWithinGroupSwapsWithNextSameGroupItem() {
        let items: [(id: Int, key: String)] = [(1, "A"), (2, "B"), (3, "A")]
        XCTAssertEqual(QueueLogic.moveDownWithinGroup(items, id: 1), [3, 2, 1])
    }

    func testMoveDownWithinGroupIsNoOpWhenLastInGroup() {
        let items: [(id: Int, key: String)] = [(1, "A"), (2, "B"), (3, "A")]
        XCTAssertEqual(QueueLogic.moveDownWithinGroup(items, id: 3), [1, 2, 3])
    }

    // MARK: whole-group moves

    func testMoveGroupUpSwapsWithPreviousGroupAndDeInterleaves() {
        // Groups by first appearance: A, B, C. Move B up -> B before A; every
        // group re-emitted contiguously (de-interleaving the queue).
        let items: [(id: Int, key: String)] = [
            (1, "A"), (2, "B"), (3, "A"), (4, "C"), (5, "B"),
        ]
        XCTAssertEqual(QueueLogic.moveGroupUp(items, key: "B"), [2, 5, 1, 3, 4])
    }

    func testMoveGroupDownSwapsWithNextGroupAndDeInterleaves() {
        let items: [(id: Int, key: String)] = [
            (1, "A"), (2, "B"), (3, "A"), (4, "C"), (5, "B"),
        ]
        // Move A down -> swaps with B: B, A, C, contiguous.
        XCTAssertEqual(QueueLogic.moveGroupDown(items, key: "A"), [2, 5, 1, 3, 4])
    }

    func testMoveGroupUpIsNoOpWhenAlreadyFirst() {
        let items: [(id: Int, key: String)] = [(1, "A"), (2, "B"), (3, "A")]
        XCTAssertEqual(QueueLogic.moveGroupUp(items, key: "A"), [1, 2, 3])
    }

    func testMoveGroupDownIsNoOpWhenAlreadyLast() {
        let items: [(id: Int, key: String)] = [(1, "A"), (2, "B"), (3, "A")]
        XCTAssertEqual(QueueLogic.moveGroupDown(items, key: "B"), [1, 2, 3])
    }

    func testMoveGroupOnAbsentKeyIsNoOp() {
        let items: [(id: Int, key: String)] = [(1, "A"), (2, "B")]
        XCTAssertEqual(QueueLogic.moveGroupUp(items, key: "Z"), [1, 2])
        XCTAssertEqual(QueueLogic.moveGroupDown(items, key: "Z"), [1, 2])
    }

    func testMoveGroupWithSingleGroupIsNoOp() {
        let items: [(id: Int, key: String)] = [(1, "A"), (2, "A")]
        XCTAssertEqual(QueueLogic.moveGroupUp(items, key: "A"), [1, 2])
        XCTAssertEqual(QueueLogic.moveGroupDown(items, key: "A"), [1, 2])
    }

    // MARK: sortedByDate (Play newest / oldest first)

    private func date(_ daysFromEpoch: Double) -> Date {
        Date(timeIntervalSince1970: daysFromEpoch * 86_400)
    }

    func testSortedByDateNewestFirstDescending() {
        let items: [(id: Int, date: Date?)] = [
            (1, date(3)), (2, date(1)), (3, date(2)),
        ]
        XCTAssertEqual(QueueLogic.sortedByDate(items, newestFirst: true), [1, 3, 2])
    }

    func testSortedByDateOldestFirstAscending() {
        let items: [(id: Int, date: Date?)] = [
            (1, date(3)), (2, date(1)), (3, date(2)),
        ]
        XCTAssertEqual(QueueLogic.sortedByDate(items, newestFirst: false), [2, 3, 1])
    }

    func testSortedByDateIsStableForEqualDates() {
        // Three episodes share a date; their incoming relative order must hold
        // in both directions.
        let items: [(id: Int, date: Date?)] = [
            (1, date(5)), (2, date(5)), (3, date(5)),
        ]
        XCTAssertEqual(QueueLogic.sortedByDate(items, newestFirst: true), [1, 2, 3])
        XCTAssertEqual(QueueLogic.sortedByDate(items, newestFirst: false), [1, 2, 3])
    }

    func testSortedByDateNilDatesSortLastInBothDirections() {
        let items: [(id: Int, date: Date?)] = [
            (1, nil), (2, date(2)), (3, nil), (4, date(1)),
        ]
        // Dated items ordered by direction; nils trail keeping their order (1, 3).
        XCTAssertEqual(QueueLogic.sortedByDate(items, newestFirst: true), [2, 4, 1, 3])
        XCTAssertEqual(QueueLogic.sortedByDate(items, newestFirst: false), [4, 2, 1, 3])
    }

    func testSortedByDateSingleItemIsThatItem() {
        let items: [(id: Int, date: Date?)] = [(7, date(1))]
        XCTAssertEqual(QueueLogic.sortedByDate(items, newestFirst: true), [7])
        XCTAssertEqual(QueueLogic.sortedByDate(items, newestFirst: false), [7])
    }

    func testSortedByDateEmptyIsEmpty() {
        let items: [(id: Int, date: Date?)] = []
        XCTAssertTrue(QueueLogic.sortedByDate(items, newestFirst: true).isEmpty)
    }

    // MARK: shuffled (Shuffle group)

    func testShuffledReturnsPermutationOfSameIdSet() {
        let ids = Array(1...20)
        var rng = SeededRNG(seed: 42)
        let result = QueueLogic.shuffled(ids, using: &rng)
        XCTAssertEqual(Set(result), Set(ids), "every id is preserved exactly once")
        XCTAssertEqual(result.count, ids.count)
    }

    func testShuffledIsDeterministicForASeed() {
        let ids = Array(1...20)
        var a = SeededRNG(seed: 7)
        var b = SeededRNG(seed: 7)
        XCTAssertEqual(QueueLogic.shuffled(ids, using: &a), QueueLogic.shuffled(ids, using: &b))
    }

    func testShuffledEmptyIsEmpty() {
        var rng = SeededRNG(seed: 1)
        XCTAssertTrue(QueueLogic.shuffled([Int](), using: &rng).isEmpty)
    }

    // MARK: idsToEvictForCount (#494 — per-podcast queue count cap)
    //
    // Ids model queued items newest-first (the caller orders by addedAt recency),
    // so the eviction walks the tail (oldest) and keeps the head (newest `cap`).

    func testEvictOverCapDropsOldestDownToN() {
        // newest-first [4,3,2,1], cap 2 → keep 4,3; evict oldest 2,1.
        XCTAssertEqual(
            QueueLogic.idsToEvictForCount([4, 3, 2, 1], cap: 2, nowPlaying: nil),
            [1, 2]
        )
    }

    func testEvictAtCapIsNoOp() {
        XCTAssertEqual(
            QueueLogic.idsToEvictForCount([3, 2, 1], cap: 3, nowPlaying: nil),
            []
        )
    }

    func testEvictUnderCapIsNoOp() {
        XCTAssertEqual(
            QueueLogic.idsToEvictForCount([2, 1], cap: 5, nowPlaying: nil),
            []
        )
    }

    func testEvictEmptyIsNoOp() {
        XCTAssertEqual(
            QueueLogic.idsToEvictForCount([Int](), cap: 3, nowPlaying: nil),
            []
        )
    }

    func testEvictNeverDropsNowPlayingEvenWhenOldest() {
        // Oldest item (1) is playing → skip it, evict the next-oldest (2) instead.
        XCTAssertEqual(
            QueueLogic.idsToEvictForCount([4, 3, 2, 1], cap: 2, nowPlaying: 1),
            [2, 3]
        )
    }

    func testEvictNowPlayingInKeepZoneIsUnaffected() {
        // Now-playing (4) is in the newest/keep zone → ordinary oldest eviction.
        XCTAssertEqual(
            QueueLogic.idsToEvictForCount([4, 3, 2, 1], cap: 2, nowPlaying: 4),
            [1, 2]
        )
    }

    func testEvictLeavesOverCapWhenOnlyOverflowItemIsNowPlaying() {
        // cap 0 with a single now-playing item: protecting it leaves nothing to
        // evict, so the queue is left one over the cap rather than dequeue it.
        XCTAssertEqual(
            QueueLogic.idsToEvictForCount([1], cap: 0, nowPlaying: 1),
            []
        )
    }

    func testEvictCapOneKeepsNowPlayingAndDropsTheRest() {
        // cap 1, playing item (2) is the oldest → keep it, evict everything newer.
        XCTAssertEqual(
            QueueLogic.idsToEvictForCount([4, 3, 2], cap: 1, nowPlaying: 2),
            [3, 4]
        )
    }

    func testEvictMixedPodcastsAreIndependentPerCall() {
        // The function operates on one podcast's items; a second podcast's list is
        // evaluated separately and never interacts with the first.
        let podcastA = QueueLogic.idsToEvictForCount([40, 30, 20, 10], cap: 1, nowPlaying: nil)
        let podcastB = QueueLogic.idsToEvictForCount([2, 1], cap: 5, nowPlaying: nil)
        XCTAssertEqual(podcastA, [10, 20, 30])
        XCTAssertEqual(podcastB, [])
    }
}

/// A tiny reproducible RNG (SplitMix64) so shuffle tests are deterministic.
private struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
