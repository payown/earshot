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

    // MARK: auto-queue opt-in enrollment

    func testAutoQueueOptInQueuesOnlyLatestRecentEpisodeUsingSevenDayDefault() throws {
        let ctx = TestStore.freshContext()
        let podcast = makePodcast(ctx, "A")
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let older = makeEpisode(ctx, "older", podcast: podcast)
        older.pubDate = now.addingTimeInterval(-2 * 86_400)
        let latest = makeEpisode(ctx, "latest", podcast: podcast)
        latest.pubDate = now.addingTimeInterval(-86_400)
        try ctx.save()

        let repo = QueueRepository(context: ctx)
        XCTAssertTrue(repo.setAutoQueue(true, for: podcast, now: now))

        XCTAssertTrue(podcast.autoQueue)
        XCTAssertEqual(repo.queue().map(\.guid), ["latest"])
        XCTAssertEqual(older.status, .newEpisode, "opt-in must not enroll deeper backlog")
        XCTAssertTrue(latest.inboxDismissed, "auto-queued episodes stay out of Inbox")
    }

    func testAutoQueueOptInRejectsLatestEpisodeOutsidePodcastAgeLimit() throws {
        let ctx = TestStore.freshContext()
        let podcast = makePodcast(ctx, "A")
        podcast.queueAgeLimitDays = 1
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let stale = makeEpisode(ctx, "stale", podcast: podcast)
        stale.pubDate = now.addingTimeInterval(-2 * 86_400)
        try ctx.save()

        let repo = QueueRepository(context: ctx)
        XCTAssertFalse(repo.setAutoQueue(true, for: podcast, now: now))

        XCTAssertTrue(podcast.autoQueue, "the setting still turns on when nothing qualifies")
        XCTAssertTrue(repo.queue().isEmpty)
    }

    func testAutoQueueOptInRejectsPlayedDismissedAndExpiredLatestEpisodes() throws {
        let ctx = TestStore.freshContext()
        let now = Date(timeIntervalSince1970: 2_000_000_000)

        let playedPodcast = makePodcast(ctx, "Played")
        let played = makeEpisode(ctx, "played", podcast: playedPodcast)
        played.pubDate = now.addingTimeInterval(-86_400)
        played.isPlayed = true

        let dismissedPodcast = makePodcast(ctx, "Dismissed")
        let dismissed = makeEpisode(ctx, "dismissed", podcast: dismissedPodcast)
        dismissed.pubDate = now.addingTimeInterval(-86_400)
        dismissed.inboxDismissed = true

        let expiredPodcast = makePodcast(ctx, "Expired")
        let expired = makeEpisode(ctx, "expired", podcast: expiredPodcast)
        expired.pubDate = now.addingTimeInterval(-86_400)
        expired.status = .expired
        ctx.insert(RecentlyExpired(episode: expired, expiredAt: now))
        try ctx.save()

        let repo = QueueRepository(context: ctx)
        XCTAssertFalse(repo.setAutoQueue(true, for: playedPodcast, now: now))
        XCTAssertFalse(repo.setAutoQueue(true, for: dismissedPodcast, now: now))
        XCTAssertFalse(repo.setAutoQueue(true, for: expiredPodcast, now: now))
        XCTAssertTrue(repo.queue().isEmpty)
    }

    func testDisablingAndReenablingAutoQueueDoesNotDuplicateLatestEpisode() throws {
        let ctx = TestStore.freshContext()
        let podcast = makePodcast(ctx, "A")
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let latest = makeEpisode(ctx, "latest", podcast: podcast)
        latest.pubDate = now.addingTimeInterval(-86_400)
        try ctx.save()

        let repo = QueueRepository(context: ctx)
        XCTAssertTrue(repo.setAutoQueue(true, for: podcast, now: now))
        XCTAssertFalse(repo.setAutoQueue(false, for: podcast, now: now))
        XCTAssertFalse(repo.setAutoQueue(true, for: podcast, now: now))

        XCTAssertEqual(repo.queue().map(\.guid), ["latest"])
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<QueueItem>()), 1)
    }

    // MARK: displayedCount (tab badge reducer, #491)

    func testDisplayedCountMatchesQueuedEpisodes() {
        let ctx = TestStore.freshContext()
        let p = makePodcast(ctx, "A")
        let repo = QueueRepository(context: ctx)
        repo.add(makeEpisode(ctx, "a", podcast: p))
        repo.add(makeEpisode(ctx, "b", podcast: p))

        let items = try! ctx.fetch(FetchDescriptor<QueueItem>())
        XCTAssertEqual(QueueRepository.displayedCount(from: items), 2)
    }

    func testDisplayedCountIsZeroForEmptyQueue() {
        XCTAssertEqual(QueueRepository.displayedCount(from: []), 0)
    }

    func testDisplayedCountExcludesOrphanRows() {
        let ctx = TestStore.freshContext()
        let p = makePodcast(ctx, "A")
        let repo = QueueRepository(context: ctx)
        repo.add(makeEpisode(ctx, "a", podcast: p))

        // An orphan row (episode == nil) can exist from corrupt/aged data; the
        // badge count must drop it so it equals what QueueScreen renders.
        let orphan = QueueItem(position: 99)
        ctx.insert(orphan)
        try! ctx.save()

        let items = try! ctx.fetch(FetchDescriptor<QueueItem>())
        XCTAssertEqual(items.count, 2, "fixture: one real row + one orphan")
        XCTAssertEqual(QueueRepository.displayedCount(from: items), 1)
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

    // MARK: batch add (Inbox multi-select, #595)

    func testBatchAddAppendsInGivenOrderAndSetsStatusInQueue() {
        let ctx = TestStore.freshContext()
        let p = makePodcast(ctx, "A")
        let a = makeEpisode(ctx, "a", podcast: p)
        let b = makeEpisode(ctx, "b", podcast: p)
        let c = makeEpisode(ctx, "c", podcast: p)
        let repo = QueueRepository(context: ctx)

        repo.add([b, c, a]) // order handed in, not insertion/pubDate order

        XCTAssertEqual(titles(repo), ["Ep b", "Ep c", "Ep a"])
        XCTAssertEqual([a, b, c].map(\.status), [.inQueue, .inQueue, .inQueue])
    }

    func testBatchAddAppendsAfterExistingQueueContents() {
        let ctx = TestStore.freshContext()
        let p = makePodcast(ctx, "A")
        let a = makeEpisode(ctx, "a", podcast: p)
        let repo = QueueRepository(context: ctx)
        repo.add(a)
        let b = makeEpisode(ctx, "b", podcast: p)
        let c = makeEpisode(ctx, "c", podcast: p)

        repo.add([b, c])

        XCTAssertEqual(titles(repo), ["Ep a", "Ep b", "Ep c"])
    }

    func testBatchAddSkipsAlreadyQueuedEpisodesWithoutDuplicating() {
        let ctx = TestStore.freshContext()
        let p = makePodcast(ctx, "A")
        let a = makeEpisode(ctx, "a", podcast: p)
        let b = makeEpisode(ctx, "b", podcast: p)
        let repo = QueueRepository(context: ctx)
        repo.add(a) // already queued

        repo.add([a, b])

        XCTAssertEqual(titles(repo), ["Ep a", "Ep b"])
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<QueueItem>()), 2)
    }

    func testBatchAddOnEmptyArrayMakesNoChange() {
        let ctx = TestStore.freshContext()
        let p = makePodcast(ctx, "A")
        let a = makeEpisode(ctx, "a", podcast: p)
        let repo = QueueRepository(context: ctx)
        repo.add(a)

        repo.add([])

        XCTAssertEqual(titles(repo), ["Ep a"])
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

    func testPlayNextInsertsAfterCurrentWhenCurrentQueued() {
        let ctx = TestStore.freshContext()
        let p = makePodcast(ctx, "A")
        let eps = ["a", "b", "c"].map { makeEpisode(ctx, $0, podcast: p) }
        let repo = QueueRepository(context: ctx)
        eps.forEach(repo.add)
        let d = makeEpisode(ctx, "d", podcast: p)

        repo.playNext(d, after: eps[0]) // current = a, queued at front

        XCTAssertEqual(titles(repo), ["Ep a", "Ep d", "Ep b", "Ep c"])
        XCTAssertEqual(d.status, .inQueue)
    }

    func testPlayNextInsertsAtFrontWhenCurrentNotQueued() {
        let ctx = TestStore.freshContext()
        let p = makePodcast(ctx, "A")
        let a = makeEpisode(ctx, "a", podcast: p)
        let b = makeEpisode(ctx, "b", podcast: p)
        let repo = QueueRepository(context: ctx)
        repo.add(a)
        repo.add(b)
        let c = makeEpisode(ctx, "c", podcast: p)

        repo.playNext(c, after: nil) // nothing playing / current not in queue

        XCTAssertEqual(titles(repo), ["Ep c", "Ep a", "Ep b"])
    }

    func testPlayNextMovesAlreadyQueuedEpisodeWithoutDuplicating() {
        let ctx = TestStore.freshContext()
        let p = makePodcast(ctx, "A")
        let eps = ["a", "b", "c"].map { makeEpisode(ctx, $0, podcast: p) }
        let repo = QueueRepository(context: ctx)
        eps.forEach(repo.add)

        repo.playNext(eps[2], after: eps[0]) // move already-queued c to after a

        XCTAssertEqual(titles(repo), ["Ep a", "Ep c", "Ep b"])
        XCTAssertEqual(repo.queue().count, 3, "must move, not duplicate")
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

    /// #614: removal must dismiss the episode from the inbox durably so it
    /// doesn't resurface as "new" -- but without marking it played, so the
    /// "Episodes completed" listening stat (driven by `isPlayed`/`playedAt`)
    /// isn't inflated for an episode the user may not have actually finished.
    func testCancelFromQueueDismissesFromInboxWithoutMarkingPlayed() {
        let ctx = TestStore.freshContext()
        let p = makePodcast(ctx, "A")
        let a = makeEpisode(ctx, "a", podcast: p)
        let repo = QueueRepository(context: ctx)
        repo.add(a)
        XCTAssertFalse(a.inboxDismissed, "Precondition: queuing never sets inboxDismissed")

        repo.cancelFromQueue(a)

        XCTAssertTrue(a.inboxDismissed, "Removal must not let the episode resurface in the inbox")
        XCTAssertFalse(a.isPlayed, "Removal must not be recorded as a completed listen")
        XCTAssertNil(a.playedAt, "Episodes-completed stat must not count this episode")
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

    func testMarkPlayedAndRemoveWithoutQueueMembershipStillMarksAndSaves() throws {
        let ctx = TestStore.freshContext()
        let p = makePodcast(ctx, "Restored")
        let episode = makeEpisode(ctx, "restored", podcast: p)
        try ctx.save()
        let queueChange = expectation(description: "non-queue played mutation stays off queue channel")
        queueChange.isInverted = true
        let token = NotificationCenter.default.addObserver(
            forName: .earshotQueueDidChange, object: nil, queue: nil
        ) { _ in queueChange.fulfill() }
        defer { NotificationCenter.default.removeObserver(token) }

        XCTAssertTrue(QueueRepository(context: ctx).markPlayedAndRemove(episode))

        XCTAssertTrue(episode.isPlayed)
        XCTAssertTrue(episode.inboxDismissed)
        XCTAssertFalse(ctx.hasChanges)
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<QueueItem>()), 0)
        wait(for: [queueChange], timeout: 0.02)
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

    // MARK: within-group moves (#476)

    func testMoveDownWithinGroupSwapsWithNextSamePodcastEpisode() {
        let ctx = TestStore.freshContext()
        let pa = makePodcast(ctx, "A")
        let pb = makePodcast(ctx, "B")
        let a1 = makeEpisode(ctx, "a1", podcast: pa)
        let b1 = makeEpisode(ctx, "b1", podcast: pb)
        let a2 = makeEpisode(ctx, "a2", podcast: pa)
        let repo = QueueRepository(context: ctx)
        [a1, b1, a2].forEach(repo.add)

        // a1 swaps with a2 (the next A item), leaping over b1; b1 stays put.
        XCTAssertTrue(repo.moveDownWithinGroup(a1), "a real move reports a change")

        XCTAssertEqual(titles(repo), ["Ep a2", "Ep b1", "Ep a1"])
        XCTAssertEqual(repo.queue().compactMap { $0.queueItem?.position }, [0, 1, 2])
    }

    func testMoveUpWithinGroupIsNoOpWhenFirstInGroup() {
        let ctx = TestStore.freshContext()
        let pa = makePodcast(ctx, "A")
        let pb = makePodcast(ctx, "B")
        let a1 = makeEpisode(ctx, "a1", podcast: pa)
        let b1 = makeEpisode(ctx, "b1", podcast: pb)
        let a2 = makeEpisode(ctx, "a2", podcast: pa)
        let repo = QueueRepository(context: ctx)
        [a1, b1, a2].forEach(repo.add)

        XCTAssertFalse(repo.moveUpWithinGroup(a1), "an edge no-op reports no change")

        XCTAssertEqual(titles(repo), ["Ep a1", "Ep b1", "Ep a2"])
    }

    // MARK: whole-group moves (#476)

    func testMoveGroupUpBringsGroupAboveAndDeInterleaves() {
        let ctx = TestStore.freshContext()
        let g = makeInterleavedGroups(ctx) // [a1, b1, a2, b2, a3]

        XCTAssertTrue(g.repo.moveGroupUp(g.pb), "B moves above A, both groups contiguous")

        XCTAssertEqual(titles(g.repo), ["Ep b1", "Ep b2", "Ep a1", "Ep a2", "Ep a3"])
        XCTAssertEqual(g.repo.queue().compactMap { $0.queueItem?.position }, [0, 1, 2, 3, 4])
    }

    func testMoveGroupDownBringsGroupBelow() {
        let ctx = TestStore.freshContext()
        let g = makeInterleavedGroups(ctx) // [a1, b1, a2, b2, a3]

        g.repo.moveGroupDown(g.pa) // A moves below B

        XCTAssertEqual(titles(g.repo), ["Ep b1", "Ep b2", "Ep a1", "Ep a2", "Ep a3"])
    }

    func testMoveGroupIsNoOpAtEdgeOrWhenNeverQueued() {
        let ctx = TestStore.freshContext()
        let g = makeInterleavedGroups(ctx)
        let pc = makePodcast(ctx, "C") // never queued
        // A no-op returns the original flat order untouched (it does NOT
        // de-interleave): A is already first, B already last, C never queued.
        let unchanged = ["Ep a1", "Ep b1", "Ep a2", "Ep b2", "Ep a3"]

        XCTAssertFalse(g.repo.moveGroupUp(g.pa), "A already first")
        XCTAssertEqual(titles(g.repo), unchanged)

        XCTAssertFalse(g.repo.moveGroupDown(g.pb), "B already last")
        XCTAssertEqual(titles(g.repo), unchanged)

        XCTAssertFalse(g.repo.moveGroupUp(pc), "never queued")
        XCTAssertEqual(titles(g.repo), unchanged)
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
        XCTAssertTrue(
            eps.allSatisfy(\.inboxDismissed),
            "Bulk clear must match individual removal and keep episodes out of Inbox"
        )
        XCTAssertTrue(eps.allSatisfy { !$0.isPlayed })
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

        XCTAssertEqual(groups.map(\.title), ["A", "B"])
        XCTAssertEqual(groups.compactMap { $0.podcast?.title }, ["A", "B"])
        XCTAssertEqual(groups[0].episodes.map(\.title), ["Ep a1", "Ep a2"])
        XCTAssertEqual(groups[1].episodes.map(\.title), ["Ep b1"])
    }

    func testOnlyFolderQueueGroupProducesPlaybackOrigin() {
        let folder = PodcastFolder(name: "News")
        let podcast = Podcast(feedURL: "https://x/a.xml", title: "A")

        let folderGroup = QueueGroup(
            kind: .folder(folder.persistentModelID),
            title: "News",
            episodes: [],
            podcast: nil
        )
        let podcastGroup = QueueGroup(
            kind: .podcast(podcast.persistentModelID),
            title: "A",
            episodes: [],
            podcast: podcast
        )
        let unfiledGroup = QueueGroup(
            kind: .unfiled,
            title: "Unfiled",
            episodes: [],
            podcast: nil
        )

        XCTAssertEqual(folderGroup.playbackOrigin, .folder(folder.persistentModelID))
        XCTAssertNil(podcastGroup.playbackOrigin)
        XCTAssertNil(unfiledGroup.playbackOrigin)
    }

    func testGroupedQueueByFolderUsesTopLevelAncestorAndIncludesUnfiled() {
        let ctx = TestStore.freshContext()
        let folders = FolderRepository(context: ctx)
        let news = folders.createFolder(name: "News")
        let tech = folders.createSubfolder(named: "Tech", under: news)
        let comedy = folders.createFolder(name: "Comedy")
        let pa = makePodcast(ctx, "A")
        let pb = makePodcast(ctx, "B")
        let pu = makePodcast(ctx, "Unfiled")
        folders.add(pa, to: tech)
        folders.add(pb, to: comedy)

        let a1 = makeEpisode(ctx, "a1", podcast: pa)
        let b1 = makeEpisode(ctx, "b1", podcast: pb)
        let a2 = makeEpisode(ctx, "a2", podcast: pa)
        let u1 = makeEpisode(ctx, "u1", podcast: pu)
        let repo = QueueRepository(context: ctx)
        [a1, b1, a2, u1].forEach(repo.add)

        let grouping = repo.groupedQueueByFolder()

        XCTAssertEqual(grouping.groups.map(\.title), ["News", "Comedy", "Unfiled"])
        XCTAssertEqual(grouping.groups[0].episodes.map(\.title), ["Ep a1", "Ep a2"])
        XCTAssertEqual(grouping.groups[1].episodes.map(\.title), ["Ep b1"])
        XCTAssertEqual(grouping.groups[2].episodes.map(\.title), ["Ep u1"])
        XCTAssertEqual(grouping.rootByPodcast[pa.persistentModelID], news.persistentModelID)
        XCTAssertNil(grouping.rootByPodcast[pu.persistentModelID])
    }

    func testFolderGroupingUsesFirstTopLevelFolderForMultiplyFiledPodcast() {
        let ctx = TestStore.freshContext()
        let folders = FolderRepository(context: ctx)
        let first = folders.createFolder(name: "First")
        let second = folders.createFolder(name: "Second")
        let podcast = makePodcast(ctx, "A")
        folders.add(podcast, to: second)
        folders.add(podcast, to: first)
        let episode = makeEpisode(ctx, "a1", podcast: podcast)
        let repo = QueueRepository(context: ctx)
        repo.add(episode)

        let grouping = repo.groupedQueueByFolder()

        XCTAssertEqual(grouping.groups.map(\.title), ["First"])
        XCTAssertEqual(grouping.rootByPodcast[podcast.persistentModelID], first.persistentModelID)
    }

    func testMoveWithinFolderGroupCanCrossPodcastBoundary() {
        let ctx = TestStore.freshContext()
        let folders = FolderRepository(context: ctx)
        let shared = folders.createFolder(name: "Shared")
        let other = folders.createFolder(name: "Other")
        let pa = makePodcast(ctx, "A")
        let pb = makePodcast(ctx, "B")
        let pc = makePodcast(ctx, "C")
        folders.add(pa, to: shared)
        folders.add(pb, to: shared)
        folders.add(pc, to: other)
        let a = makeEpisode(ctx, "a", podcast: pa)
        let c = makeEpisode(ctx, "c", podcast: pc)
        let b = makeEpisode(ctx, "b", podcast: pb)
        let repo = QueueRepository(context: ctx)
        [a, c, b].forEach(repo.add)
        let map = repo.groupedQueueByFolder().rootByPodcast

        XCTAssertTrue(repo.moveDownWithinFolderGroup(a, rootByPodcast: map))

        XCTAssertEqual(titles(repo), ["Ep b", "Ep c", "Ep a"])
    }

    func testFolderGroupActionsOperateOnWholeFolderAndKeepOtherOrder() {
        let ctx = TestStore.freshContext()
        let folders = FolderRepository(context: ctx)
        let first = folders.createFolder(name: "First")
        let second = folders.createFolder(name: "Second")
        let pa = makePodcast(ctx, "A")
        let pb = makePodcast(ctx, "B")
        let pc = makePodcast(ctx, "C")
        folders.add(pa, to: first)
        folders.add(pb, to: second)
        folders.add(pc, to: first)
        let a = makeEpisode(ctx, "a", podcast: pa)
        let b = makeEpisode(ctx, "b", podcast: pb)
        let c = makeEpisode(ctx, "c", podcast: pc)
        let repo = QueueRepository(context: ctx)
        [a, b, c].forEach(repo.add)
        let grouping = repo.groupedQueueByFolder()
        let firstKey = QueueGroup.Kind.folder(first.persistentModelID)

        XCTAssertTrue(repo.moveGroupDown(firstKey, rootByPodcast: grouping.rootByPodcast))
        XCTAssertEqual(titles(repo), ["Ep b", "Ep a", "Ep c"])

        let front = repo.playGroup(firstKey, rootByPodcast: grouping.rootByPodcast)
        XCTAssertEqual(front?.title, "Ep a")
        XCTAssertEqual(titles(repo), ["Ep a", "Ep c", "Ep b"])
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

    // MARK: binge oldest first (#488)

    /// Builds a podcast with three dated episodes (newest-first as the view
    /// supplies them) and a separate already-queued inbox episode from another
    /// podcast, so binge non-destructiveness can be asserted.
    private func makeBingeFixture(
        _ ctx: ModelContext
    ) -> (repo: QueueRepository, pa: Podcast, newestFirst: [Episode], inbox: Episode) {
        let pa = makePodcast(ctx, "A")
        let pb = makePodcast(ctx, "B")
        func ep(_ guid: String, _ podcast: Podcast, day: Double) -> Episode {
            let e = makeEpisode(ctx, guid, podcast: podcast)
            e.pubDate = Date(timeIntervalSince1970: day * 86_400)
            return e
        }
        let a1 = ep("a1", pa, day: 1) // oldest
        let a2 = ep("a2", pa, day: 2)
        let a3 = ep("a3", pa, day: 3) // newest
        let inbox = ep("b1", pb, day: 9)
        let repo = QueueRepository(context: ctx)
        repo.add(inbox) // a pre-existing, unrelated queue item
        // The view hands episodes newest-first (its display sort order).
        return (repo, pa, [a3, a2, a1], inbox)
    }

    func testBingeOldestFirstEnqueuesOrdersAndFrontInsertsNonDestructively() {
        let ctx = TestStore.freshContext()
        let f = makeBingeFixture(ctx)

        let first = f.repo.bingeOldestFirst(f.pa, episodes: f.newestFirst)

        // Oldest first at the front, then the pre-existing inbox item untouched.
        XCTAssertEqual(titles(f.repo), ["Ep a1", "Ep a2", "Ep a3", "Ep b1"])
        XCTAssertEqual(first?.title, "Ep a1", "returns the oldest episode")
        XCTAssertEqual(f.repo.queue().compactMap { $0.queueItem?.position }, [0, 1, 2, 3])
        XCTAssertEqual(f.newestFirst.map(\.status), [.inQueue, .inQueue, .inQueue])
    }

    func testBingeOldestFirstLeavesOtherQueueItemsIntact() {
        let ctx = TestStore.freshContext()
        let f = makeBingeFixture(ctx)
        // Add a second unrelated podcast group behind the inbox item.
        let pc = makePodcast(ctx, "C")
        let c1 = makeEpisode(ctx, "c1", podcast: pc)
        let c2 = makeEpisode(ctx, "c2", podcast: pc)
        f.repo.add(c1)
        f.repo.add(c2)
        // Queue before binge: [b1, c1, c2]

        f.repo.bingeOldestFirst(f.pa, episodes: f.newestFirst)

        // Binge group is at the front; the prior [b1, c1, c2] order is preserved.
        XCTAssertEqual(titles(f.repo),
                       ["Ep a1", "Ep a2", "Ep a3", "Ep b1", "Ep c1", "Ep c2"])
    }

    func testBingeOldestFirstMovesAlreadyQueuedEpisodesWithoutDuplicating() {
        let ctx = TestStore.freshContext()
        let f = makeBingeFixture(ctx)
        // Pre-queue the middle episode so binge must move, not duplicate, it.
        let a2 = f.newestFirst[1]
        f.repo.add(a2) // queue: [b1, a2]

        f.repo.bingeOldestFirst(f.pa, episodes: f.newestFirst)

        XCTAssertEqual(titles(f.repo), ["Ep a1", "Ep a2", "Ep a3", "Ep b1"])
        XCTAssertEqual(f.repo.queue().count, 4, "must move the queued item, not duplicate it")
    }

    func testBingeUnheardFilterExcludesPlayedAllFilterIncludesEverything() {
        let ctx = TestStore.freshContext()
        let f = makeBingeFixture(ctx)
        let a2 = f.newestFirst[1]
        a2.isPlayed = true

        // Unheard: the view passes only unplayed episodes (#489 filter applied
        // upstream), so binge skips the played one.
        let unheard = EpisodeListFilter.unheard.apply(to: f.newestFirst)
        f.repo.bingeOldestFirst(f.pa, episodes: unheard)
        XCTAssertEqual(titles(f.repo), ["Ep a1", "Ep a3", "Ep b1"],
                       "Unheard binge excludes the played episode")

        // All: every episode is in the set.
        let all = EpisodeListFilter.all.apply(to: f.newestFirst)
        f.repo.bingeOldestFirst(f.pa, episodes: all)
        XCTAssertEqual(titles(f.repo), ["Ep a1", "Ep a2", "Ep a3", "Ep b1"],
                       "All binge includes the played episode too")
    }

    func testBingeOnEmptySetReturnsNilAndMakesNoChange() {
        let ctx = TestStore.freshContext()
        let f = makeBingeFixture(ctx)
        let before = titles(f.repo)

        XCTAssertNil(f.repo.bingeOldestFirst(f.pa, episodes: []))
        XCTAssertEqual(titles(f.repo), before)
    }

    /// Defensive scoping: episodes that all belong to a DIFFERENT podcast are not
    /// this podcast's run, so binge returns nil and enqueues nothing (the foreign
    /// episodes must never be pulled into `podcast`'s queue group).
    func testBingeWithOnlyForeignEpisodesReturnsNilAndMakesNoChange() {
        let ctx = TestStore.freshContext()
        let f = makeBingeFixture(ctx)
        let pc = makePodcast(ctx, "C")
        let c1 = makeEpisode(ctx, "c1", podcast: pc)
        let c2 = makeEpisode(ctx, "c2", podcast: pc)
        let before = titles(f.repo)

        // Ask to binge podcast A but hand it only C's episodes.
        XCTAssertNil(f.repo.bingeOldestFirst(f.pa, episodes: [c1, c2]))
        XCTAssertEqual(titles(f.repo), before, "foreign episodes leave the queue untouched")
        XCTAssertEqual(c1.status, .newEpisode, "foreign episode is not enqueued")
        XCTAssertEqual(c2.status, .newEpisode, "foreign episode is not enqueued")
    }

    /// Defensive scoping on a MIXED set: only the episodes belonging to `podcast`
    /// form the run; foreign episodes in the same array are filtered out and never
    /// enqueued.
    func testBingeFiltersOutForeignEpisodesFromMixedSet() {
        let ctx = TestStore.freshContext()
        let f = makeBingeFixture(ctx)
        let pc = makePodcast(ctx, "C")
        let c1 = makeEpisode(ctx, "c1", podcast: pc)

        // Hand A's three episodes plus one stray C episode.
        let first = f.repo.bingeOldestFirst(f.pa, episodes: f.newestFirst + [c1])

        XCTAssertEqual(first?.title, "Ep a1", "oldest A episode leads the run")
        XCTAssertEqual(titles(f.repo), ["Ep a1", "Ep a2", "Ep a3", "Ep b1"],
                       "only A's episodes are bingeed; the stray C episode is excluded")
        XCTAssertEqual(c1.status, .newEpisode, "the foreign episode is never enqueued")
    }

    // MARK: 125/127 regression — binge must not disturb playNext / boundaries

    /// #486: after a binge seeds the front group, "Play next" still inserts the
    /// episode right after the now-playing episode (not blindly at the front).
    func testPlayNextStillInsertsAfterCurrentAfterBinge() {
        let ctx = TestStore.freshContext()
        let f = makeBingeFixture(ctx)
        f.repo.bingeOldestFirst(f.pa, episodes: f.newestFirst)
        // Queue: [a1, a2, a3, b1]; pretend a1 is now playing.
        let a1 = f.newestFirst[2]
        let extra = makeEpisode(ctx, "x", podcast: f.pa)

        f.repo.playNext(extra, after: a1)

        XCTAssertEqual(titles(f.repo), ["Ep a1", "Ep x", "Ep a2", "Ep a3", "Ep b1"],
                       "Play next inserts after the current episode, not at the front")
    }

    // MARK: Durable compact-Cloud Queue intent

    func testFollowedAddAndRemovePersistMembershipAndOrderingIntentWithQueue() throws {
        let ctx = TestStore.freshContext()
        let podcast = makePodcast(ctx, "Intent")
        let episode = makeEpisode(ctx, "intent", podcast: podcast)
        try ctx.save()
        let repo = QueueRepository(context: ctx)

        repo.add(episode)

        var memberships = try PendingCloudQueueMutation.memberships(in: ctx)
        XCTAssertEqual(memberships.count, 1)
        XCTAssertEqual(memberships.first?.feedURL, FeedURLIdentity.canonical(podcast.feedURL))
        XCTAssertEqual(memberships.first?.guid, episode.guid)
        XCTAssertEqual(memberships.first?.isQueued, true)
        XCTAssertFalse(try PendingCloudQueueMutation.orderings(in: ctx).isEmpty)

        XCTAssertTrue(repo.cancelFromQueue(episode))

        memberships = try PendingCloudQueueMutation.memberships(in: ctx)
        XCTAssertEqual(memberships.count, 2)
        XCTAssertEqual(Set(memberships.map(\.isQueued)), [true, false])
        XCTAssertGreaterThanOrEqual(try PendingCloudQueueMutation.orderings(in: ctx).count, 2)
        XCTAssertTrue(repo.queue().isEmpty)
    }

    func testCatalogQueueMutationCreatesNoCloudIntent() throws {
        let ctx = TestStore.freshContext()
        let podcast = makePodcast(ctx, "Catalog")
        podcast.subscriptionStateRaw = PodcastSubscriptionState.catalogOnly.rawValue
        let episode = makeEpisode(ctx, "catalog", podcast: podcast)
        try ctx.save()
        let repo = QueueRepository(context: ctx)

        repo.add(episode)
        XCTAssertTrue(try PendingCloudQueueMutation.memberships(in: ctx).isEmpty)
        XCTAssertTrue(try PendingCloudQueueMutation.orderings(in: ctx).isEmpty)

        XCTAssertTrue(repo.cancelFromQueue(episode))
        XCTAssertTrue(try PendingCloudQueueMutation.memberships(in: ctx).isEmpty)
        XCTAssertTrue(try PendingCloudQueueMutation.orderings(in: ctx).isEmpty)
    }

    func testClearingObservedQueueIntentLeavesNewerGenerationDurable() throws {
        let ctx = TestStore.freshContext()
        PendingCloudQueueMutation.stageMembership(
            feedURL: "https://example.com/feed", guid: "episode", isQueued: true,
            eventDate: Date(timeIntervalSince1970: 100), in: ctx
        )
        PendingCloudQueueMutation.stageOrdering(eventDate: Date(timeIntervalSince1970: 100), in: ctx)
        try ctx.save()
        let observedMemberships = try PendingCloudQueueMutation.memberships(in: ctx)
        let observedOrderings = try PendingCloudQueueMutation.orderings(in: ctx)

        PendingCloudQueueMutation.stageMembership(
            feedURL: "https://example.com/feed", guid: "episode", isQueued: false,
            eventDate: Date(timeIntervalSince1970: 200), in: ctx
        )
        PendingCloudQueueMutation.stageOrdering(eventDate: Date(timeIntervalSince1970: 200), in: ctx)
        try ctx.save()

        try PendingCloudQueueMutation.clear(
            memberships: observedMemberships, orderings: observedOrderings, in: ctx
        )
        try ctx.save()

        let remainingMembership = try XCTUnwrap(
            PendingCloudQueueMutation.memberships(in: ctx).first
        )
        XCTAssertFalse(remainingMembership.isQueued)
        XCTAssertEqual(remainingMembership.eventDate, Date(timeIntervalSince1970: 200))
        XCTAssertEqual(
            try PendingCloudQueueMutation.orderings(in: ctx).map(\.eventDate),
            [Date(timeIntervalSince1970: 200)]
        )
    }

    /// #446 / #487: the boundary helpers the binge run relies on still behave —
    /// group-end off stops at a different-group next, but a Play-next override on
    /// that next item bypasses the stop for that one advance. Pure-logic guard
    /// that the binge feature didn't change these semantics.
    func testBoundaryAndOverrideSemanticsUnchanged() {
        // #446: continue-after-episode off always stops.
        XCTAssertNil(PlaybackLogic.nextUpHonoringBoundaries(
            queue: [(id: 1, groupKey: "A"), (id: 2, groupKey: "A")],
            after: 1, currentGroupKey: "A",
            continueAfterEpisode: false, continueAfterGroupEnds: true
        ))
        // #446: group-end off stops when the next item is a different group.
        XCTAssertNil(PlaybackLogic.nextUpHonoringBoundaries(
            queue: [(id: 1, groupKey: "A"), (id: 2, groupKey: "B")],
            after: 1, currentGroupKey: "A",
            continueAfterEpisode: true, continueAfterGroupEnds: false
        ))
        // #446/#488: within the same group (a binge run), advance continues.
        XCTAssertEqual(PlaybackLogic.nextUpHonoringBoundaries(
            queue: [(id: 1, groupKey: "A"), (id: 2, groupKey: "A")],
            after: 1, currentGroupKey: "A",
            continueAfterEpisode: true, continueAfterGroupEnds: false
        ), 2)
        // #487: a Play-next override on the next candidate bypasses group-end off.
        XCTAssertTrue(PlaybackLogic.continueAfterGroupEnds(
            setting: false, nextCandidate: 2, playNextOverrides: [2]
        ))
    }
}
