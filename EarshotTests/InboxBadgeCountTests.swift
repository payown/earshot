import XCTest
import SwiftData
@testable import Earshot

/// The inbox tab badge count must NOT be computed by materializing the whole
/// non-dismissed library and filtering `status` in Swift. On a large library
/// that re-runs on every 5-second playback-position save and saturates the main
/// thread, and iOS force-terminates the app under its `cpu_resource_fatal` limit
/// (~93% CPU over 60s). The fix restricts the store fetch to unplayed,
/// non-dismissed episodes (`InboxQuery.unplayedPredicate`) — excluding the
/// played-history bucket that grows without bound because finished episodes are
/// never dismissed — then applies the exact `.newEpisode` membership check in
/// memory over that small set. See `RootView.InboxTabBadge` and
/// `InboxRepository.inboxCount(optInOnly:)`.
@MainActor
final class InboxBadgeCountTests: XCTestCase {

    private func podcast(_ ctx: ModelContext, _ title: String) -> Podcast {
        let p = Podcast(feedURL: "https://x/\(title).xml", title: title)
        ctx.insert(p)
        return p
    }

    @discardableResult
    private func episode(_ ctx: ModelContext, _ guid: String, podcast: Podcast,
                         status: EpisodeStatus = .newEpisode, dismissed: Bool = false,
                         played: Bool = false) -> Episode {
        let e = Episode(guid: guid, title: "Ep \(guid)", audioURL: "https://x/\(guid).mp3",
                        pubDate: nil, status: status, inboxDismissed: dismissed)
        e.podcast = podcast
        // Route played episodes through the real setter so `playedAt` is set the
        // same way production does (this is exactly what the fix's predicate keys
        // off). A played episode's `playedAt` must be non-nil.
        if played { e.isPlayed = true }
        ctx.insert(e)
        return e
    }

    /// Only `.newEpisode`, undismissed episodes from non-excluded podcasts count.
    /// Played, in-queue, dismissed, and excluded-podcast episodes must not.
    func testInboxCountCountsOnlyNewUndismissedFromIncludedPodcasts() {
        let ctx = TestStore.freshContext()
        let a = podcast(ctx, "A")
        let excluded = podcast(ctx, "B")
        excluded.inboxExcluded = true

        episode(ctx, "a-new1", podcast: a)
        episode(ctx, "a-new2", podcast: a)
        episode(ctx, "a-dismissed", podcast: a, dismissed: true)   // dismissed → out
        episode(ctx, "a-played", podcast: a, played: true)         // played → out
        episode(ctx, "a-inqueue", podcast: a, status: .inQueue)    // in queue → out
        episode(ctx, "b-new-excluded", podcast: excluded)          // excluded show → out
        try? ctx.save()

        let repo = InboxRepository(context: ctx)
        XCTAssertEqual(repo.inboxCount(optInOnly: false), 2)
    }

    /// The badge count must equal the materialized inbox count for the same
    /// (normal) mode, so the badge never drifts from the Inbox screen's list.
    func testInboxCountMatchesMaterializedInboxEpisodes() {
        let ctx = TestStore.freshContext()
        let a = podcast(ctx, "A")
        let b = podcast(ctx, "B")
        episode(ctx, "a-new", podcast: a)
        episode(ctx, "b-new", podcast: b)
        episode(ctx, "b-played", podcast: b, played: true)
        episode(ctx, "b-dismissed", podcast: b, dismissed: true)
        try? ctx.save()

        let repo = InboxRepository(context: ctx)
        XCTAssertEqual(repo.inboxCount(optInOnly: false), repo.inboxEpisodes().count)
    }

    /// In opt-in-only mode, only podcasts explicitly opted in contribute.
    func testInboxCountOptInOnlyCountsOnlyIncludedPodcasts() {
        let ctx = TestStore.freshContext()
        let optedIn = podcast(ctx, "A")
        optedIn.inboxIncluded = true
        let normal = podcast(ctx, "B") // not opted in

        episode(ctx, "a-new", podcast: optedIn)
        episode(ctx, "b-new", podcast: normal)
        try? ctx.save()

        let repo = InboxRepository(context: ctx)
        XCTAssertEqual(repo.inboxCount(optInOnly: true), 1)
    }

    /// Bulk Clear Queue must match the per-episode Remove from queue action: the
    /// episode becomes unplayed but remains dismissed, so it cannot unexpectedly
    /// return to Inbox (#David-2026-08-18).
    func testClearedQueueKeepsEpisodeOutOfInbox() {
        let ctx = TestStore.freshContext()
        let p = podcast(ctx, "A")
        let e = episode(ctx, "played-then-queued", podcast: p, played: true)
        try? ctx.save()

        let queue = QueueRepository(context: ctx)
        queue.add(e)
        queue.clear()

        let repo = InboxRepository(context: ctx)
        XCTAssertFalse(e.isPlayed)
        XCTAssertNil(e.playedAt)
        XCTAssertTrue(e.inboxDismissed)
        XCTAssertEqual(repo.inboxCount(optInOnly: false), 0)
    }

    /// The performance guard: the store fetch that backs the badge must EXCLUDE
    /// played episodes, because that bucket grows without bound over listening
    /// history and materializing it on every playback-position save is what
    /// triggered the CPU-limit termination. If a future change lets played
    /// episodes back into `unplayedPredicate`, this fails.
    func testUnplayedFetchExcludesPlayedEpisodes() {
        let ctx = TestStore.freshContext()
        let a = podcast(ctx, "A")
        episode(ctx, "new", podcast: a)
        episode(ctx, "played-1", podcast: a, played: true)
        episode(ctx, "played-2", podcast: a, played: true)
        try? ctx.save()

        let fetched = (try? ctx.fetch(
            FetchDescriptor<Episode>(predicate: InboxQuery.unplayedPredicate(optInOnly: false))
        )) ?? []
        let guids = Set(fetched.map(\.guid))
        XCTAssertTrue(guids.contains("new"))
        XCTAssertFalse(guids.contains("played-1"))
        XCTAssertFalse(guids.contains("played-2"))
    }

    /// #763: a folder-filtered Inbox must push podcast membership into the store
    /// query. Only the supplied podcast matches; the usual played/dismissed/excluded
    /// rules remain intact.
    func testFolderUnplayedPredicateScopesInStoreAndKeepsInboxRules() throws {
        let ctx = TestStore.freshContext()
        let inside = podcast(ctx, "Inside")
        let outside = podcast(ctx, "Outside")
        let excluded = podcast(ctx, "Excluded")
        excluded.inboxExcluded = true

        episode(ctx, "inside-new", podcast: inside)
        episode(ctx, "inside-played", podcast: inside, played: true)
        episode(ctx, "outside-new", podcast: outside)
        episode(ctx, "excluded-new", podcast: excluded)
        try ctx.save()

        let predicate = InboxQuery.folderUnplayedPredicate(podcastID: inside.persistentModelID)
        let fetched = try ctx.fetch(FetchDescriptor<Episode>(predicate: predicate))
        let inbox = InboxRepository(context: ctx).inbox(from: fetched)

        XCTAssertEqual(inbox.map(\.guid), ["inside-new"])
    }

    func testFolderInboxEmptySubtreeMatchesNothing() throws {
        let ctx = TestStore.freshContext()
        let show = podcast(ctx, "Show")
        episode(ctx, "new", podcast: show)
        let folder = FolderRepository(context: ctx).createFolder(name: "Empty")
        try ctx.save()

        XCTAssertTrue(InboxRepository(context: ctx).inboxEpisodes(in: folder).isEmpty)
    }

    func testFolderInboxIsSubtreeAwareAndHonorsOptInOnly() throws {
        let ctx = TestStore.freshContext()
        let included = podcast(ctx, "Included")
        included.inboxIncluded = true
        let normal = podcast(ctx, "Normal")
        let outside = podcast(ctx, "Outside")
        episode(ctx, "included-new", podcast: included)
        episode(ctx, "normal-new", podcast: normal)
        episode(ctx, "outside-new", podcast: outside)
        let folders = FolderRepository(context: ctx)
        let root = folders.createFolder(name: "Root")
        let child = folders.createSubfolder(named: "Child", under: root)
        folders.add(included, to: child)
        folders.add(normal, to: root)
        try ctx.save()

        AppSettingsStore(context: ctx).setBool(true, for: SettingsKey.inboxOptInOnly)
        let inbox = InboxRepository(context: ctx).inboxEpisodes(in: root)

        XCTAssertEqual(inbox.map(\.guid), ["included-new"])
    }

    func testClearScopedInboxLeavesEpisodesOutsideScopeVisible() {
        let ctx = TestStore.freshContext()
        let inside = podcast(ctx, "Inside")
        let outside = podcast(ctx, "Outside")
        let insideEpisode = episode(ctx, "inside", podcast: inside)
        let outsideEpisode = episode(ctx, "outside", podcast: outside)
        try? ctx.save()

        InboxRepository(context: ctx).clearInbox([insideEpisode])

        XCTAssertTrue(insideEpisode.inboxDismissed)
        XCTAssertFalse(outsideEpisode.inboxDismissed)
        XCTAssertEqual(InboxRepository(context: ctx).inboxEpisodes().map(\.guid), ["outside"])
    }

    /// #736: the badge no longer polls the store on every save — it recomputes
    /// only when it receives `.earshotInboxDidChange`. So the inbox-mutating
    /// operations must post it. Clearing the inbox is one such operation.
    func testClearInboxPostsInboxDidChange() {
        let ctx = TestStore.freshContext()
        let a = podcast(ctx, "A")
        episode(ctx, "new1", podcast: a)
        episode(ctx, "new2", podcast: a)
        try? ctx.save()

        var posted = 0
        let token = NotificationCenter.default.addObserver(
            forName: .earshotInboxDidChange, object: nil, queue: nil
        ) { _ in posted += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        InboxRepository(context: ctx).clearInbox()

        XCTAssertGreaterThan(posted, 0, "clearing the inbox must post .earshotInboxDidChange for the badge")
    }

    /// #736: marking episodes played changes the inbox count, so it must post
    /// `.earshotInboxDidChange` too — otherwise the badge would stay stale until
    /// the next foreground.
    func testMarkAllPlayedPostsInboxDidChange() {
        let ctx = TestStore.freshContext()
        let a = podcast(ctx, "A")
        episode(ctx, "new1", podcast: a)
        episode(ctx, "new2", podcast: a)
        try? ctx.save()

        var posted = 0
        let token = NotificationCenter.default.addObserver(
            forName: .earshotInboxDidChange, object: nil, queue: nil
        ) { _ in posted += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        EpisodeRepository(context: ctx).markAllPlayed(in: a)

        XCTAssertGreaterThan(posted, 0, "marking played must post .earshotInboxDidChange")
    }
}
