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

    // Issue #357: the fetch sort uses `sendableKeyPath(...)`-wrapped key paths to
    // satisfy strict concurrency. This asserts the wrapping is behavior-neutral:
    // folders must still come back ordered by `sortOrder` first, then `name`.
    func testFoldersSortedBySortOrderThenName() {
        let ctx = TestStore.freshContext()
        let repo = FolderRepository(context: ctx)

        // Create out of alphabetical order so name ordering can't be coincidental.
        let zebra = repo.createFolder(name: "Zebra")   // sortOrder 0
        let apple = repo.createFolder(name: "Apple")   // sortOrder 1
        let mango = repo.createFolder(name: "Mango")   // sortOrder 2

        // Primary key is sortOrder, so creation order wins over alphabetical.
        XCTAssertEqual(repo.folders().map(\.name), ["Zebra", "Apple", "Mango"])

        // Tie the sortOrder so the secondary key (name) decides.
        zebra.sortOrder = 5
        apple.sortOrder = 5
        mango.sortOrder = 5
        try? ctx.save()

        XCTAssertEqual(repo.folders().map(\.name), ["Apple", "Mango", "Zebra"])
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
}
