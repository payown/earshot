import XCTest
import SwiftData
@testable import Earshot

@MainActor
final class FolderRepositoryTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makePodcast(_ ctx: ModelContext, _ title: String) -> Podcast {
        let podcast = Podcast(feedURL: "https://x/\(title).xml", title: title)
        ctx.insert(podcast)
        return podcast
    }

    @discardableResult
    private func makeEpisode(
        _ ctx: ModelContext, _ podcast: Podcast, guid: String,
        pubDate: Date?, status: EpisodeStatus = .newEpisode, dismissed: Bool = false
    ) -> Episode {
        let episode = Episode(
            guid: guid, title: "Ep \(guid)", audioURL: "https://x/\(guid).mp3",
            pubDate: pubDate, status: status, inboxDismissed: dismissed
        )
        episode.podcast = podcast
        ctx.insert(episode)
        return episode
    }

    // MARK: Folder lifecycle

    func testCreateAssignsIncreasingSortOrder() throws {
        let ctx = TestStore.freshContext()
        let repo = FolderRepository(context: ctx)

        let a = repo.createFolder(name: "News")
        let b = repo.createFolder(name: "Comedy")

        XCTAssertEqual(a.sortOrder, 0)
        XCTAssertEqual(b.sortOrder, 1)
        XCTAssertEqual(repo.folders().map(\.name), ["News", "Comedy"])
    }

    func testCreateTrimsWhitespace() {
        let ctx = TestStore.freshContext()
        let folder = FolderRepository(context: ctx).createFolder(name: "  Tech  ")
        XCTAssertEqual(folder.name, "Tech")
    }

    func testRenameAndDelete() {
        let ctx = TestStore.freshContext()
        let repo = FolderRepository(context: ctx)
        let folder = repo.createFolder(name: "Old")

        repo.rename(folder, to: "New")
        XCTAssertEqual(repo.folders().first?.name, "New")

        repo.delete(folder)
        XCTAssertTrue(repo.folders().isEmpty)
    }

    func testReorderFoldersPersists() {
        let ctx = TestStore.freshContext()
        let repo = FolderRepository(context: ctx)
        let a = repo.createFolder(name: "A")
        let b = repo.createFolder(name: "B")
        let c = repo.createFolder(name: "C")

        repo.reorderFolders([c, a, b])

        XCTAssertEqual(repo.folders().map(\.name), ["C", "A", "B"])
    }

    /// The folder-row rotor actions (#539) perform `folders.move(fromOffsets:toOffset:)`
    /// with the offsets from `QuickActionMoveLogic`, then persist via
    /// `reorderFolders`. This verifies that pairing lands the moved folder at each
    /// target's `resultingIndex`, so the rotor's Move to top/up/down/to bottom end
    /// up where their "position N of M" announcement claims — exactly what the
    /// FoldersScreen buttons do.
    func testRotorMoveOffsetsLandFolderAtResultingIndex() {
        let names = ["A", "B", "C", "D"]
        for indexToMove in names.indices {
            for target in QuickActionMoveLogic.targets(index: indexToMove, count: names.count) {
                let ctx = TestStore.freshContext()
                let repo = FolderRepository(context: ctx)
                _ = names.map { repo.createFolder(name: $0) }
                var ordered = repo.folders()
                XCTAssertEqual(ordered.map(\.name), names, "Starts in canonical order")

                ordered.move(fromOffsets: IndexSet(integer: indexToMove), toOffset: target.destinationOffset)
                repo.reorderFolders(ordered)

                let result = repo.folders().map(\.name)
                XCTAssertEqual(
                    result[target.resultingIndex], names[indexToMove],
                    "\(target.label) from index \(indexToMove) should land at \(target.resultingIndex); got \(result)"
                )
            }
        }
    }

    // MARK: Membership

    func testAddIsIdempotentAndOrdered() {
        let ctx = TestStore.freshContext()
        let repo = FolderRepository(context: ctx)
        let folder = repo.createFolder(name: "F")
        let p1 = makePodcast(ctx, "One")
        let p2 = makePodcast(ctx, "Two")

        repo.add(p1, to: folder)
        repo.add(p2, to: folder)
        repo.add(p1, to: folder) // duplicate — no-op

        XCTAssertEqual(folder.memberships.count, 2)
        XCTAssertEqual(repo.podcasts(in: folder).map(\.title), ["One", "Two"])
    }

    func testRemovePodcast() {
        let ctx = TestStore.freshContext()
        let repo = FolderRepository(context: ctx)
        let folder = repo.createFolder(name: "F")
        let p1 = makePodcast(ctx, "One")
        let p2 = makePodcast(ctx, "Two")
        repo.add(p1, to: folder)
        repo.add(p2, to: folder)

        repo.remove(p1, from: folder)

        XCTAssertEqual(repo.podcasts(in: folder).map(\.title), ["Two"])
    }

    func testReorderPodcastsPersists() {
        let ctx = TestStore.freshContext()
        let repo = FolderRepository(context: ctx)
        let folder = repo.createFolder(name: "F")
        let p1 = makePodcast(ctx, "One")
        let p2 = makePodcast(ctx, "Two")
        let p3 = makePodcast(ctx, "Three")
        repo.add(p1, to: folder)
        repo.add(p2, to: folder)
        repo.add(p3, to: folder)

        repo.reorderPodcasts(in: folder, ordered: [p3, p1, p2])

        XCTAssertEqual(repo.podcasts(in: folder).map(\.title), ["Three", "One", "Two"])
    }

    func testSetMembershipsReplacesFolders() {
        let ctx = TestStore.freshContext()
        let repo = FolderRepository(context: ctx)
        let a = repo.createFolder(name: "A")
        let b = repo.createFolder(name: "B")
        let c = repo.createFolder(name: "C")
        let podcast = makePodcast(ctx, "Show")
        repo.add(podcast, to: a)

        repo.setMemberships(for: podcast, folders: [b, c])

        XCTAssertEqual(Set(repo.folders(containing: podcast).map(\.name)), ["B", "C"])
        XCTAssertTrue(repo.podcasts(in: a).isEmpty)
    }

    func testUnfiledPodcasts() {
        let ctx = TestStore.freshContext()
        let repo = FolderRepository(context: ctx)
        let folder = repo.createFolder(name: "F")
        let filed = makePodcast(ctx, "Filed")
        _ = makePodcast(ctx, "Loose")
        repo.add(filed, to: folder)
        try? ctx.save()

        XCTAssertEqual(repo.unfiledPodcasts().map(\.title), ["Loose"])
    }

    // MARK: Queueing + age limit

    func testAddFolderToQueuePicksNewestUnplayedPerPodcast() {
        let ctx = TestStore.freshContext()
        let repo = FolderRepository(context: ctx)
        let folder = repo.createFolder(name: "F")
        let p1 = makePodcast(ctx, "One")
        let p2 = makePodcast(ctx, "Two")
        repo.add(p1, to: folder)
        repo.add(p2, to: folder)

        makeEpisode(ctx, p1, guid: "p1-old", pubDate: now.addingTimeInterval(-86_400))
        let p1New = makeEpisode(ctx, p1, guid: "p1-new", pubDate: now)
        makeEpisode(ctx, p1, guid: "p1-played", pubDate: now.addingTimeInterval(86_400), status: .played)
        let p2Ep = makeEpisode(ctx, p2, guid: "p2", pubDate: now.addingTimeInterval(-3_600))

        let count = repo.addFolderToQueue(folder, now: now.addingTimeInterval(3_600))

        XCTAssertEqual(count, 2)
        XCTAssertEqual(p1New.status, .inQueue)
        XCTAssertEqual(p2Ep.status, .inQueue)
    }

    func testAgeLimitSkipsStaleEpisodes() {
        let ctx = TestStore.freshContext()
        let repo = FolderRepository(context: ctx)
        let folder = repo.createFolder(name: "F")
        repo.setQueueAgeLimit(folder, days: 7)
        let fresh = makePodcast(ctx, "Fresh")
        let stale = makePodcast(ctx, "Stale")
        repo.add(fresh, to: folder)
        repo.add(stale, to: folder)

        makeEpisode(ctx, fresh, guid: "fresh", pubDate: now.addingTimeInterval(-2 * 86_400))
        makeEpisode(ctx, stale, guid: "stale", pubDate: now.addingTimeInterval(-30 * 86_400))

        let count = repo.addFolderToQueue(folder, now: now)

        XCTAssertEqual(count, 1) // stale episode skipped by the 7-day limit
    }

    func testSetQueueAgeLimitZeroClears() {
        let ctx = TestStore.freshContext()
        let repo = FolderRepository(context: ctx)
        let folder = repo.createFolder(name: "F")

        repo.setQueueAgeLimit(folder, days: 10)
        XCTAssertEqual(folder.queueAgeLimitDays, 10)

        repo.setQueueAgeLimit(folder, days: 0)
        XCTAssertNil(folder.queueAgeLimitDays)
    }

    func testRemoveFromAllFoldersBeforeDeleteLeavesNoDanglingMemberships() throws {
        let ctx = TestStore.freshContext()
        let repo = FolderRepository(context: ctx)
        let f1 = repo.createFolder(name: "F1")
        let f2 = repo.createFolder(name: "F2")
        let keep = makePodcast(ctx, "Keep")
        let drop = makePodcast(ctx, "Drop")
        repo.add(keep, to: f1)
        repo.add(drop, to: f1)
        repo.add(drop, to: f2)
        try ctx.save()

        // Mirror the unsubscribe flow: clean memberships, then delete the podcast.
        repo.removeFromAllFolders(drop)
        ctx.delete(drop)
        try ctx.save()

        XCTAssertEqual(try ctx.fetch(FetchDescriptor<FolderMembership>()).count, 1)
        XCTAssertEqual(repo.podcasts(in: f1).map(\.title), ["Keep"])
        XCTAssertTrue(repo.podcasts(in: f2).isEmpty)
    }

    func testAgeLimitIncludesEpisodesWithNoPubDate() {
        XCTAssertTrue(FolderLogic.passesAgeLimit(pubDate: nil, ageLimitDays: 7, now: now))
        XCTAssertTrue(FolderLogic.passesAgeLimit(pubDate: now, ageLimitDays: nil, now: now))
        XCTAssertFalse(
            FolderLogic.passesAgeLimit(
                pubDate: now.addingTimeInterval(-8 * 86_400), ageLimitDays: 7, now: now
            )
        )
    }

    // MARK: Nesting — subfolders (#752)

    func testCreateSubfolderSetsParentAndPerSiblingOrder() {
        let ctx = TestStore.freshContext()
        let repo = FolderRepository(context: ctx)
        let root = repo.createFolder(name: "Root")

        let a = repo.createSubfolder(named: "A", under: root)
        let b = repo.createSubfolder(named: "B", under: root)

        XCTAssertEqual(a.parent?.persistentModelID, root.persistentModelID)
        XCTAssertEqual(b.parent?.persistentModelID, root.persistentModelID)
        // Sibling order restarts within the parent, independent of the root order.
        XCTAssertEqual(a.sortOrder, 0)
        XCTAssertEqual(b.sortOrder, 1)
    }

    func testChildFoldersTopLevelVsNested() {
        let ctx = TestStore.freshContext()
        let repo = FolderRepository(context: ctx)
        let root = repo.createFolder(name: "Root")
        let other = repo.createFolder(name: "Other")
        let child = repo.createSubfolder(named: "Child", under: root)

        XCTAssertEqual(repo.childFolders(of: nil).map(\.name), ["Root", "Other"])
        XCTAssertEqual(repo.childFolders(of: root).map(\.name), ["Child"])
        XCTAssertTrue(repo.childFolders(of: other).isEmpty)
        XCTAssertTrue(repo.childFolders(of: child).isEmpty)
    }

    // MARK: Nesting — move + cycle rejection (#752)

    func testMoveReparentsToNewParent() {
        let ctx = TestStore.freshContext()
        let repo = FolderRepository(context: ctx)
        let a = repo.createFolder(name: "A")
        let b = repo.createFolder(name: "B")
        let child = repo.createSubfolder(named: "Child", under: a)

        let result = repo.move(child, under: b)

        XCTAssertEqual(result, .moved)
        XCTAssertEqual(child.parent?.persistentModelID, b.persistentModelID)
        XCTAssertEqual(repo.childFolders(of: a).map(\.name), [])
        XCTAssertEqual(repo.childFolders(of: b).map(\.name), ["Child"])
    }

    func testMoveToRootClearsParent() {
        let ctx = TestStore.freshContext()
        let repo = FolderRepository(context: ctx)
        let root = repo.createFolder(name: "Root")
        let child = repo.createSubfolder(named: "Child", under: root)

        XCTAssertEqual(repo.move(child, under: nil), .moved)
        XCTAssertNil(child.parent)
        XCTAssertEqual(repo.childFolders(of: nil).map(\.name), ["Root", "Child"])
    }

    func testMoveUnderSelfIsRejectedNoOp() {
        let ctx = TestStore.freshContext()
        let repo = FolderRepository(context: ctx)
        let root = repo.createFolder(name: "Root")
        let child = repo.createSubfolder(named: "Child", under: root)

        let result = repo.move(root, under: root)

        XCTAssertEqual(result, .rejectedCycle)
        XCTAssertNil(root.parent, "Rejected move must not mutate the folder")
        XCTAssertEqual(child.parent?.persistentModelID, root.persistentModelID)
    }

    func testMoveUnderOwnDescendantIsRejectedNoOp() {
        let ctx = TestStore.freshContext()
        let repo = FolderRepository(context: ctx)
        let root = repo.createFolder(name: "Root")
        let mid = repo.createSubfolder(named: "Mid", under: root)
        let leaf = repo.createSubfolder(named: "Leaf", under: mid)

        let result = repo.move(root, under: leaf)

        XCTAssertEqual(result, .rejectedCycle)
        XCTAssertNil(root.parent)
        XCTAssertEqual(mid.parent?.persistentModelID, root.persistentModelID)
        XCTAssertEqual(leaf.parent?.persistentModelID, mid.persistentModelID)
    }

    // MARK: Nesting — delete modes preserve podcasts + episodes (#752)

    func testDeletePromoteChildrenLiftsChildrenAndKeepsData() throws {
        let ctx = TestStore.freshContext()
        let repo = FolderRepository(context: ctx)
        let root = repo.createFolder(name: "Root")
        let mid = repo.createSubfolder(named: "Mid", under: root)
        let leaf = repo.createSubfolder(named: "Leaf", under: mid)

        let podcast = makePodcast(ctx, "Show")
        let episode = makeEpisode(ctx, podcast, guid: "e1", pubDate: now)
        repo.add(podcast, to: mid)
        ctx.insert(EpisodeFolderMembership(folder: mid, episode: episode, sortOrder: 0))
        try ctx.save()

        repo.delete(mid, mode: .promoteChildren)

        // Mid is gone; its child Leaf is lifted up to Root (the grandparent).
        XCTAssertFalse(repo.folders().contains { $0.name == "Mid" })
        XCTAssertEqual(leaf.parent?.persistentModelID, root.persistentModelID)
        XCTAssertEqual(repo.childFolders(of: root).map(\.name), ["Leaf"])

        // Podcast and episode survive; only the folder joins are cleaned up.
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Podcast>()).count, 1)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Episode>()).count, 1)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<FolderMembership>()).count, 0)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<EpisodeFolderMembership>()).count, 0)
    }

    func testPlainDeleteRoutesToPromoteChildren() {
        let ctx = TestStore.freshContext()
        let repo = FolderRepository(context: ctx)
        let root = repo.createFolder(name: "Root")
        let child = repo.createSubfolder(named: "Child", under: root)

        repo.delete(root) // single-arg default

        // Child is promoted to the root level rather than deleted or orphaned oddly.
        XCTAssertFalse(repo.folders().contains { $0.name == "Root" })
        XCTAssertNil(child.parent)
        XCTAssertEqual(repo.childFolders(of: nil).map(\.name), ["Child"])
    }

    func testDeleteSubtreeRemovesAllDescendantsButKeepsData() throws {
        let ctx = TestStore.freshContext()
        let repo = FolderRepository(context: ctx)
        let keep = repo.createFolder(name: "Keep")
        let root = repo.createFolder(name: "Root")
        let mid = repo.createSubfolder(named: "Mid", under: root)
        let leaf = repo.createSubfolder(named: "Leaf", under: mid)

        let podcast = makePodcast(ctx, "Show")
        let episode = makeEpisode(ctx, podcast, guid: "e1", pubDate: now)
        repo.add(podcast, to: leaf)
        ctx.insert(EpisodeFolderMembership(folder: leaf, episode: episode, sortOrder: 0))
        try ctx.save()

        repo.delete(root, mode: .deleteSubtree)

        // The whole Root subtree is gone; the unrelated Keep folder remains.
        XCTAssertEqual(repo.folders().map(\.name), ["Keep"])
        _ = keep

        // Podcast and episode survive; folder joins are cleaned up.
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Podcast>()).count, 1)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<Episode>()).count, 1)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<FolderMembership>()).count, 0)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<EpisodeFolderMembership>()).count, 0)
    }

    // MARK: Nesting — subtree subscriptions (#752)

    func testSubtreeSubscriptionsDeduplicatesAcrossSubtree() throws {
        let ctx = TestStore.freshContext()
        let repo = FolderRepository(context: ctx)
        let root = repo.createFolder(name: "Root")
        let child = repo.createSubfolder(named: "Child", under: root)

        let shared = makePodcast(ctx, "Shared")
        let rootOnly = makePodcast(ctx, "RootOnly")
        let childOnly = makePodcast(ctx, "ChildOnly")
        repo.add(shared, to: root)
        repo.add(shared, to: child) // same podcast filed in two folders of the subtree
        repo.add(rootOnly, to: root)
        repo.add(childOnly, to: child)
        try ctx.save()

        let subs = repo.subtreeSubscriptions(of: root)

        XCTAssertEqual(subs.map(\.title), ["ChildOnly", "RootOnly", "Shared"])
        XCTAssertEqual(subs.count, 3, "Shared appears once despite two memberships")
    }

    // MARK: Batch podcast membership (#756)

    func testAddPodcastsBatchIsIdempotentAndOrdered() throws {
        let ctx = TestStore.freshContext()
        let repo = FolderRepository(context: ctx)
        let folder = repo.createFolder(name: "F")
        let p1 = makePodcast(ctx, "One")
        let p2 = makePodcast(ctx, "Two")
        let p3 = makePodcast(ctx, "Three")
        repo.add(p1, to: folder) // pre-existing member

        // Batch includes an existing member (p1) and a duplicate (p2 twice).
        repo.addPodcasts([p2, p1, p2, p3], to: folder)

        XCTAssertEqual(repo.podcasts(in: folder).map(\.title), ["One", "Two", "Three"])
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<FolderMembership>()).count, 3,
                       "No duplicate (folder, podcast) rows")
    }

    func testAddPodcastsBatchIsAtomic() throws {
        let ctx = TestStore.freshContext()
        let repo = FolderRepository(context: ctx)
        let folder = repo.createFolder(name: "F")
        let p1 = makePodcast(ctx, "One")
        let p2 = makePodcast(ctx, "Two")

        repo.addPodcasts([p1, p2], to: folder)

        // A single save persisted the whole batch: nothing left uncommitted.
        XCTAssertFalse(ctx.hasChanges)
        XCTAssertEqual(repo.podcasts(in: folder).count, 2)
    }

    func testMovePodcastsRefilesIntoTargetOnly() throws {
        let ctx = TestStore.freshContext()
        let repo = FolderRepository(context: ctx)
        let a = repo.createFolder(name: "A")
        let b = repo.createFolder(name: "B")
        let target = repo.createFolder(name: "Target")
        let p1 = makePodcast(ctx, "One")
        let p2 = makePodcast(ctx, "Two")
        repo.add(p1, to: a)
        repo.add(p1, to: b) // filed in two folders
        repo.add(p2, to: a)

        repo.movePodcasts([p1, p2], to: target)

        XCTAssertEqual(Set(repo.folders(containing: p1).map(\.name)), ["Target"])
        XCTAssertEqual(Set(repo.folders(containing: p2).map(\.name)), ["Target"])
        XCTAssertTrue(repo.podcasts(in: a).isEmpty)
        XCTAssertTrue(repo.podcasts(in: b).isEmpty)
        XCTAssertEqual(repo.podcasts(in: target).map(\.title), ["One", "Two"])
    }

    func testMovePodcastsIsIdempotent() throws {
        let ctx = TestStore.freshContext()
        let repo = FolderRepository(context: ctx)
        let target = repo.createFolder(name: "Target")
        let p1 = makePodcast(ctx, "One")
        repo.add(p1, to: target)

        repo.movePodcasts([p1], to: target) // already solely in target

        XCTAssertEqual(repo.podcasts(in: target).map(\.title), ["One"])
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<FolderMembership>()).count, 1)
    }

    func testRemovePodcastsBatch() {
        let ctx = TestStore.freshContext()
        let repo = FolderRepository(context: ctx)
        let folder = repo.createFolder(name: "F")
        let p1 = makePodcast(ctx, "One")
        let p2 = makePodcast(ctx, "Two")
        let p3 = makePodcast(ctx, "Three")
        repo.addPodcasts([p1, p2, p3], to: folder)

        repo.removePodcasts([p1, p3], from: folder)

        XCTAssertEqual(repo.podcasts(in: folder).map(\.title), ["Two"])
    }

    // MARK: Episode membership (#756)

    func testAddEpisodesBatchIsIdempotentAndOrdered() throws {
        let ctx = TestStore.freshContext()
        let repo = FolderRepository(context: ctx)
        let folder = repo.createFolder(name: "F")
        let podcast = makePodcast(ctx, "Show")
        let e1 = makeEpisode(ctx, podcast, guid: "e1", pubDate: now)
        let e2 = makeEpisode(ctx, podcast, guid: "e2", pubDate: now.addingTimeInterval(60))
        let e3 = makeEpisode(ctx, podcast, guid: "e3", pubDate: now.addingTimeInterval(120))

        repo.addEpisodes([e1], to: folder)
        repo.addEpisodes([e2, e1, e2, e3], to: folder) // e1 existing, e2 duplicated

        XCTAssertEqual(repo.episodes(in: folder).map(\.guid), ["e1", "e2", "e3"],
                       "Membership insertion order is preserved, no duplicates")
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<EpisodeFolderMembership>()).count, 3)
        XCTAssertFalse(ctx.hasChanges, "Batch committed atomically")
    }

    func testEpisodesInFallsBackToNewestFirstOnEqualSortOrder() throws {
        let ctx = TestStore.freshContext()
        let repo = FolderRepository(context: ctx)
        let folder = repo.createFolder(name: "F")
        let podcast = makePodcast(ctx, "Show")
        let older = makeEpisode(ctx, podcast, guid: "older", pubDate: now.addingTimeInterval(-1_000))
        let newer = makeEpisode(ctx, podcast, guid: "newer", pubDate: now)

        // Same sortOrder for both → the pubDate fallback (newest first) decides.
        ctx.insert(EpisodeFolderMembership(folder: folder, episode: older, sortOrder: 0))
        ctx.insert(EpisodeFolderMembership(folder: folder, episode: newer, sortOrder: 0))
        try ctx.save()

        XCTAssertEqual(repo.episodes(in: folder).map(\.guid), ["newer", "older"])
    }

    func testMoveEpisodesRefilesIntoTargetOnly() throws {
        let ctx = TestStore.freshContext()
        let repo = FolderRepository(context: ctx)
        let a = repo.createFolder(name: "A")
        let target = repo.createFolder(name: "Target")
        let podcast = makePodcast(ctx, "Show")
        let e1 = makeEpisode(ctx, podcast, guid: "e1", pubDate: now)
        let e2 = makeEpisode(ctx, podcast, guid: "e2", pubDate: now)
        repo.addEpisodes([e1, e2], to: a)

        repo.moveEpisodes([e1, e2], to: target)

        XCTAssertTrue(repo.episodes(in: a).isEmpty)
        XCTAssertEqual(repo.episodes(in: target).map(\.guid), ["e1", "e2"])
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<EpisodeFolderMembership>()).count, 2,
                       "Move does not leave the old memberships behind")
    }

    func testRemoveEpisodesBatch() {
        let ctx = TestStore.freshContext()
        let repo = FolderRepository(context: ctx)
        let folder = repo.createFolder(name: "F")
        let podcast = makePodcast(ctx, "Show")
        let e1 = makeEpisode(ctx, podcast, guid: "e1", pubDate: now)
        let e2 = makeEpisode(ctx, podcast, guid: "e2", pubDate: now)
        repo.addEpisodes([e1, e2], to: folder)

        repo.removeEpisodes([e1], from: folder)

        XCTAssertEqual(repo.episodes(in: folder).map(\.guid), ["e2"])
    }

    /// The Episodes-section "Remove from folder" action (#759) drops only the
    /// `EpisodeFolderMembership` join row — the `Episode` itself, and its podcast,
    /// are untouched and still fetchable. This pins the contract the folder-detail
    /// row relies on: removing an episode from a folder is not deleting it.
    func testRemoveEpisodeFromFolderDropsMembershipNotEpisode() throws {
        let ctx = TestStore.freshContext()
        let repo = FolderRepository(context: ctx)
        let folder = repo.createFolder(name: "F")
        let podcast = makePodcast(ctx, "Show")
        let e1 = makeEpisode(ctx, podcast, guid: "e1", pubDate: now)
        let e2 = makeEpisode(ctx, podcast, guid: "e2", pubDate: now.addingTimeInterval(60))
        repo.addEpisodes([e1, e2], to: folder)
        try ctx.save()

        repo.removeEpisodes([e1], from: folder)

        // The folder no longer lists e1, but e2's membership stays.
        XCTAssertEqual(repo.episodes(in: folder).map(\.guid), ["e2"])
        // Exactly one membership row was deleted, not both.
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<EpisodeFolderMembership>()).count, 1)
        // The Episode itself survives — both episodes still exist in the store.
        let survivingGuids = try ctx.fetch(FetchDescriptor<Episode>()).map(\.guid).sorted()
        XCTAssertEqual(survivingGuids, ["e1", "e2"], "Removing from a folder never deletes the episode")
        // e1 simply belongs to no folder now.
        XCTAssertTrue(repo.folders(containing: e1).isEmpty)
    }

    func testFoldersContainingEpisode() throws {
        let ctx = TestStore.freshContext()
        let repo = FolderRepository(context: ctx)
        let a = repo.createFolder(name: "A")
        let b = repo.createFolder(name: "B")
        _ = repo.createFolder(name: "C")
        let podcast = makePodcast(ctx, "Show")
        let episode = makeEpisode(ctx, podcast, guid: "e1", pubDate: now)
        repo.addEpisodes([episode], to: a)
        repo.addEpisodes([episode], to: b)

        // Returned in folders() order (sortOrder), only the two it belongs to.
        XCTAssertEqual(repo.folders(containing: episode).map(\.name), ["A", "B"])
    }

    // MARK: Episode membership cleanup (#756)

    func testRemoveEpisodeFromAllFoldersBeforeDeleteLeavesNoDangling() throws {
        let ctx = TestStore.freshContext()
        let repo = FolderRepository(context: ctx)
        let a = repo.createFolder(name: "A")
        let b = repo.createFolder(name: "B")
        let podcast = makePodcast(ctx, "Show")
        let drop = makeEpisode(ctx, podcast, guid: "drop", pubDate: now)
        let keep = makeEpisode(ctx, podcast, guid: "keep", pubDate: now)
        repo.addEpisodes([drop, keep], to: a)
        repo.addEpisodes([drop], to: b)
        try ctx.save()

        repo.removeEpisodeFromAllFolders(drop)
        ctx.delete(drop)
        try ctx.save()

        XCTAssertEqual(try ctx.fetch(FetchDescriptor<EpisodeFolderMembership>()).count, 1,
                       "Only the kept episode's membership remains")
        XCTAssertEqual(repo.episodes(in: a).map(\.guid), ["keep"])
        XCTAssertTrue(repo.episodes(in: b).isEmpty)
    }

    func testRemovePodcastEpisodesFromAllFoldersCleansOnlyThatPodcast() throws {
        let ctx = TestStore.freshContext()
        let repo = FolderRepository(context: ctx)
        let folder = repo.createFolder(name: "F")
        let gone = makePodcast(ctx, "Gone")
        let stay = makePodcast(ctx, "Stay")
        let g1 = makeEpisode(ctx, gone, guid: "g1", pubDate: now)
        let g2 = makeEpisode(ctx, gone, guid: "g2", pubDate: now)
        let s1 = makeEpisode(ctx, stay, guid: "s1", pubDate: now)
        repo.addEpisodes([g1, g2, s1], to: folder)
        try ctx.save()

        repo.removePodcastEpisodesFromAllFolders(gone)

        XCTAssertEqual(repo.episodes(in: folder).map(\.guid), ["s1"],
                       "Only the removed podcast's episode memberships are cleaned")
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<EpisodeFolderMembership>()).count, 1)
    }

    /// End-to-end: unsubscribing a podcast (via the real `SubscriptionRepository`
    /// choke point) must leave no dangling `EpisodeFolderMembership` rows for its
    /// episodes. Guards the #756 wiring.
    func testUnsubscribeRemovesEpisodeFolderMemberships() throws {
        let ctx = TestStore.freshContext()
        let repo = FolderRepository(context: ctx)
        let folder = repo.createFolder(name: "F")
        let podcast = makePodcast(ctx, "Show")
        let e1 = makeEpisode(ctx, podcast, guid: "e1", pubDate: now)
        let e2 = makeEpisode(ctx, podcast, guid: "e2", pubDate: now)
        repo.addEpisodes([e1, e2], to: folder)
        try ctx.save()
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<EpisodeFolderMembership>()).count, 2)

        SubscriptionRepository(context: ctx).unsubscribe(podcast)

        XCTAssertEqual(try ctx.fetch(FetchDescriptor<EpisodeFolderMembership>()).count, 0,
                       "Unsubscribe cleaned the episodes' folder memberships")
        XCTAssertTrue(repo.episodes(in: folder).isEmpty)
    }
}
