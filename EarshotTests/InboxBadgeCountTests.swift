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

    func testCurrentEpisodesDropsPlayedItemFromCachedGlobalSnapshot() throws {
        let ctx = TestStore.freshContext()
        let show = podcast(ctx, "Cached")
        let item = episode(ctx, "cached-new", podcast: show)
        try ctx.save()

        let cached = InboxRepository(context: ctx).inboxEpisodes()
        XCTAssertEqual(cached.map(\.guid), ["cached-new"])

        InboxRepository(context: ctx).markPlayed(item)

        XCTAssertTrue(item.isPlayed, "precondition: the durable action succeeded")
        XCTAssertEqual(cached.map(\.guid), ["cached-new"], "the retained array itself is stale")
        XCTAssertTrue(
            InboxRepository.currentEpisodes(cached, in: ctx).isEmpty,
            "render-time revalidation must not show a played item from a stale snapshot"
        )
    }

    func testCurrentEpisodesDropsBulkPlayedItemFromCachedFolderSnapshot() async throws {
        let ctx = TestStore.freshContext()
        let show = podcast(ctx, "Folder Cached")
        let item = episode(ctx, "folder-cached-new", podcast: show)
        let folder = FolderRepository(context: ctx).createFolder(name: "News")
        FolderRepository(context: ctx).add(show, to: folder)
        try ctx.save()

        let cached = InboxRepository(context: ctx).inboxEpisodes(in: folder)
        XCTAssertEqual(cached.map(\.guid), ["folder-cached-new"])

        let changed = await EpisodeRepository(context: ctx).markAllPlayed(in: show)
        XCTAssertEqual(changed, 1)

        XCTAssertTrue(item.isPlayed, "precondition: bulk mark played succeeded")
        XCTAssertEqual(cached.map(\.guid), ["folder-cached-new"], "the retained folder array is stale")
        XCTAssertTrue(
            InboxRepository.currentEpisodes(cached, in: ctx).isEmpty,
            "a bulk-played item must not linger under the folder's New episodes heading"
        )
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
    func testMarkAllPlayedPostsInboxDidChange() async {
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

        _ = await EpisodeRepository(context: ctx).markAllPlayed(in: a)

        XCTAssertGreaterThan(posted, 0, "marking played must post .earshotInboxDidChange")
    }

    func testIdentifierPagingReturnsOnlyRequestedModelsAndStableLaterPage() async throws {
        let ctx = TestStore.freshContext()
        let show = podcast(ctx, "Paged")
        for index in 0..<205 {
            let item = episode(ctx, String(format: "page-%03d", index), podcast: show)
            item.pubDate = Date(timeIntervalSince1970: TimeInterval(index))
        }
        try ctx.save()

        let repository = InboxRepository(context: ctx)
        let first = try await repository.identifierPage(
            scope: .all,
            optInOnly: false,
            searchText: "",
            limit: 100
        )
        let second = try await repository.identifierPage(
            scope: .all,
            optInOnly: false,
            searchText: "",
            limit: 200
        )

        XCTAssertEqual(first.ids.count, 100)
        XCTAssertEqual(first.inboxCount, 205)
        XCTAssertEqual(first.matchingCount, 205)
        XCTAssertEqual(first.candidateCount, 205)
        XCTAssertEqual(first.downloadIDs.count, ManualDownloadBatchPlan.maximumEpisodeCount)
        XCTAssertEqual(first.downloadEligibleCount, 205)
        XCTAssertEqual(first.downloadSkippedCount, 0)
        XCTAssertTrue(first.hasMore)
        XCTAssertEqual(Array(second.ids.prefix(100)), first.ids)
        XCTAssertEqual(second.ids.count, 200)
        XCTAssertTrue(second.hasMore)
    }

    func testResolvingPageToleratesConcurrentDeletion() async throws {
        let ctx = TestStore.freshContext()
        let show = podcast(ctx, "Concurrent deletion")
        for index in 0..<3 {
            episode(ctx, "delete-\(index)", podcast: show)
        }
        try ctx.save()

        let repository = InboxRepository(context: ctx)
        let page = try await repository.identifierPage(
            scope: .all,
            optInOnly: false,
            searchText: "",
            limit: 100
        )
        let removedID = try XCTUnwrap(page.ids.first)
        let removed = try XCTUnwrap(ctx.model(for: removedID) as? Episode)
        ctx.delete(removed)
        try ctx.save()

        let resolved = repository.resolve(page.ids)
        XCTAssertEqual(resolved.count, 2)
        XCTAssertFalse(resolved.contains { $0.persistentModelID == removedID })
    }

    func testFullScopeClearUsesAllPagesAndLeavesOutsideFolderUntouched() async throws {
        let ctx = TestStore.freshContext()
        let inside = podcast(ctx, "Inside pages")
        let outside = podcast(ctx, "Outside pages")
        let folders = FolderRepository(context: ctx)
        let root = folders.createFolder(name: "Paged root")
        folders.add(inside, to: root)
        for index in 0..<205 {
            episode(ctx, "inside-page-\(index)", podcast: inside)
        }
        let outsideEpisode = episode(ctx, "outside-page", podcast: outside)
        try ctx.save()

        let cleared = await InboxRepository(context: ctx).clearInbox(
            scope: .folder(root.persistentModelID),
            optInOnly: false
        )

        XCTAssertEqual(cleared, 205)
        XCTAssertTrue(InboxRepository(context: ctx).inboxEpisodes(in: root).isEmpty)
        XCTAssertFalse(outsideEpisode.inboxDismissed)
    }

    func testReloadCoalescerCollapsesOneRunLoopBurst() {
        var coalescer = InboxReloadCoalescer()
        XCTAssertTrue(coalescer.request())
        XCTAssertFalse(coalescer.request())
        coalescer.consume()
        XCTAssertTrue(coalescer.request())
    }

    func testPendingFocusWaitsForPublicationAndFallsBackAfterDeletion() {
        XCTAssertEqual(
            InboxPendingFocusLogic.target(
                pendingEpisode: "neighbor",
                pendingEmpty: false,
                publishedEpisodes: [],
                matchingCount: 2
            ),
            .wait
        )
        XCTAssertEqual(
            InboxPendingFocusLogic.target(
                pendingEpisode: "neighbor",
                pendingEmpty: false,
                publishedEpisodes: ["fallback"],
                matchingCount: 1
            ),
            .episode("fallback")
        )
        XCTAssertEqual(
            InboxPendingFocusLogic.target(
                pendingEpisode: Optional<String>.none,
                pendingEmpty: true,
                publishedEpisodes: ["later-page-row"],
                matchingCount: 1
            ),
            .episode("later-page-row")
        )
        XCTAssertEqual(
            InboxPendingFocusLogic.target(
                pendingEpisode: Optional<String>.none,
                pendingEmpty: true,
                publishedEpisodes: [],
                matchingCount: 0
            ),
            .empty
        )
    }

    func testCandidatePresentationNeverShowsSnapshotFromDifferentQuery() {
        let all = InboxCandidateQueryKey(scope: .all, optInOnly: false, searchText: "")
        let searched = InboxCandidateQueryKey(
            scope: .all,
            optInOnly: false,
            searchText: "swift"
        )

        XCTAssertEqual(
            InboxCandidatePresentationLogic.phase(
                requested: searched,
                published: all,
                failed: nil
            ),
            .loading
        )
        XCTAssertEqual(
            InboxCandidatePresentationLogic.phase(
                requested: searched,
                published: all,
                failed: searched
            ),
            .retry
        )
        XCTAssertEqual(
            InboxCandidatePresentationLogic.phase(
                requested: all,
                published: all,
                failed: all
            ),
            .content,
            "a refresh failure must retain the last good page for the same query"
        )
    }

    func testMountedQueryShellSuppressesCountUntilCurrentResultsPublish() {
        var state = InboxShellResultState()
        state.didPublish(matchingCount: 42)
        XCTAssertEqual(state.matchingCount, 42)

        state.queryDidChange()
        XCTAssertNil(
            state.matchingCount,
            "the mounted shell must not announce the previous query's count"
        )

        state.didPublish(matchingCount: 7)
        XCTAssertEqual(state.matchingCount, 7)
    }

    func testShowMoreWaitsForPublishedRowsAndOnlyUsesTerminalFocusFallback() {
        let pending = InboxShowMoreRequest(previousCount: 100)
        XCTAssertNil(InboxShowMoreLogic.publication(
            pending: pending,
            publishedIDs: Array(0..<100),
            totalCount: 250,
            noun: "episodes"
        ))

        let laterPage = InboxShowMoreLogic.publication(
            pending: pending,
            publishedIDs: Array(0..<200),
            totalCount: 250,
            noun: "episodes"
        )
        XCTAssertEqual(laterPage?.announcement, "Showing 200 of 250 episodes")
        XCTAssertNil(laterPage?.terminalFocus)

        let terminalPage = InboxShowMoreLogic.publication(
            pending: pending,
            publishedIDs: Array(0..<150),
            totalCount: 150,
            noun: "new episodes"
        )
        XCTAssertEqual(terminalPage?.announcement, "Showing 150 of 150 new episodes")
        XCTAssertEqual(terminalPage?.terminalFocus, 149)
    }

    func testFolderInboxLoadingLabelIsContextual() {
        let ctx = TestStore.freshContext()
        let folder = FolderRepository(context: ctx).createFolder(name: "Loading")
        XCTAssertEqual(
            InboxPageScope.folder(folder.persistentModelID).loadingAccessibilityLabel,
            "Loading folder inbox"
        )
        XCTAssertEqual(InboxPageScope.all.loadingAccessibilityLabel, "Loading inbox")
    }
}
