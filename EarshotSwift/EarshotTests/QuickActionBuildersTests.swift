import XCTest
import SwiftData
@testable import Earshot

@MainActor
final class QuickActionBuildersTests: XCTestCase {

    private func makeEpisode(_ ctx: ModelContext, played: Bool = false) -> Episode {
        let p = Podcast(feedURL: "https://x/a.xml", title: "Show")
        ctx.insert(p)
        let e = Episode(guid: "g", title: "Ep", audioURL: "https://x/a.mp3")
        e.podcast = p
        e.isPlayed = played
        ctx.insert(e)
        return e
    }

    func testEpisodeActionsPreserveConfiguredOrder() {
        let ctx = TestStore.freshContext()
        let episode = makeEpisode(ctx)
        let items = buildEpisodeActions(
            episode: episode,
            order: [.share, .playNow, .addToQueueTop],
            player: PlayerService(),
            downloads: DownloadManager(),
            context: ctx,
            onShowNotes: {},
            onShare: {},
            onBookmarks: {}
        )
        XCTAssertEqual(items.map(\.label), ["Share", "Play now", "Play next"])
    }

    func testEpisodeMarkPlayedLabelReflectsState() {
        let ctx = TestStore.freshContext()
        let played = makeEpisode(ctx, played: true)
        let items = buildEpisodeActions(
            episode: played, order: [.markPlayed], player: PlayerService(),
            downloads: DownloadManager(),
            context: ctx, onShowNotes: {}, onShare: {}, onBookmarks: {}
        )
        XCTAssertEqual(items.map(\.label), ["Mark as unplayed"])
    }

    func testEpisodeBookmarksActionInvokesCallback() {
        let ctx = TestStore.freshContext()
        let episode = makeEpisode(ctx)
        var opened = false
        let items = buildEpisodeActions(
            episode: episode, order: [.viewBookmarks], player: PlayerService(),
            downloads: DownloadManager(),
            context: ctx, onShowNotes: {}, onShare: {}, onBookmarks: { opened = true }
        )
        XCTAssertEqual(items.map(\.label), ["Bookmarks"])
        items.first?.run()
        XCTAssertTrue(opened)
    }

    func testQueueActionsDropAllMovesInNoneMode() {
        let ctx = TestStore.freshContext()
        let episode = makeEpisode(ctx)
        let items = buildQueueActions(
            episode: episode,
            order: defaultQueueItemActions,
            moveMode: .none,
            player: PlayerService(),
            context: ctx,
            onShowNotes: {},
            onFocus: { _ in }
        )
        XCTAssertEqual(items.map(\.label), ["Play now", "Remove from queue", "Open show notes"])
    }

    func testQueueActionsGroupedModeKeepsUpDownButDropsTopBottom() {
        let ctx = TestStore.freshContext()
        let episode = makeEpisode(ctx)
        let items = buildQueueActions(
            episode: episode,
            order: [.moveToTop, .moveUp, .playNow, .moveDown, .moveToBottom],
            moveMode: .grouped,
            player: PlayerService(),
            context: ctx,
            onShowNotes: {},
            onFocus: { _ in }
        )
        XCTAssertEqual(items.map(\.label), ["Move up", "Play now", "Move down"])
    }

    func testQueueActionsFlatModeIncludesAllMovesInConfiguredOrder() {
        let ctx = TestStore.freshContext()
        let episode = makeEpisode(ctx)
        let items = buildQueueActions(
            episode: episode,
            order: [.moveToTop, .playNow, .removeFromQueue],
            moveMode: .flat,
            player: PlayerService(),
            context: ctx,
            onShowNotes: {},
            onFocus: { _ in }
        )
        XCTAssertEqual(items.map(\.label), ["Move to top", "Play now", "Remove from queue"])
    }

    // MARK: #572 — configurable Unfollow on episode rows

    func testUnfollowOmittedWhenSurfaceCannotUnfollow() {
        // Acceptance criterion: #572 — surfaces that pass no onUnfollow (the
        // detached search preview, #517 zero-store-writes contract) get no
        // "Unfollow this podcast" item; the other 8 stay intact and in order.
        let ctx = TestStore.freshContext()
        let episode = makeEpisode(ctx)
        let items = buildEpisodeActions(
            episode: episode, order: defaultEpisodeActions, player: PlayerService(),
            downloads: DownloadManager(),
            context: ctx, onShowNotes: {}, onShare: {}, onBookmarks: {}
        )
        XCTAssertEqual(items.map(\.label), [
            "Play now", "Add to end of queue", "Play next", "Download",
            "Mark as played", "Bookmarks", "Open show notes", "Share",
        ])
        XCTAssertFalse(items.map(\.label).contains("Unfollow this podcast"))
    }

    func testUnfollowPresentDestructiveAtConfiguredPosition() {
        // Acceptance criterion: #572 — the item sits exactly where the user put
        // `.unfollow` (mid-list here, not forced last) and is destructive.
        let ctx = TestStore.freshContext()
        let episode = makeEpisode(ctx)
        let items = buildEpisodeActions(
            episode: episode, order: [.share, .unfollow, .playNow], player: PlayerService(),
            downloads: DownloadManager(),
            context: ctx, onShowNotes: {}, onShare: {}, onBookmarks: {}, onUnfollow: {}
        )
        XCTAssertEqual(items.map(\.label), ["Share", "Unfollow this podcast", "Play now"])
        XCTAssertTrue(items[1].isDestructive)
        XCTAssertFalse(items[0].isDestructive)
        XCTAssertFalse(items[2].isDestructive)
    }

    func testUnfollowOmittedForDetachedEpisode() {
        // Acceptance criterion: #572 — an episode with no podcast (detached
        // search-preview episode) never offers Unfollow even with a handler.
        let ctx = TestStore.freshContext()
        let detached = Episode(guid: "d", title: "Detached", audioURL: "https://x/d.mp3")
        ctx.insert(detached)
        let items = buildEpisodeActions(
            episode: detached, order: [.unfollow, .share], player: PlayerService(),
            downloads: DownloadManager(),
            context: ctx, onShowNotes: {}, onShare: {}, onBookmarks: {}, onUnfollow: {}
        )
        XCTAssertEqual(items.map(\.label), ["Share"])
    }

    func testUnfollowRunnerRequestsConfirmationAndDeletesNothing() throws {
        // Acceptance criterion: #572 — activation only asks the caller to open
        // its confirmation dialog; the runner itself never unfollows.
        let ctx = TestStore.freshContext()
        let episode = makeEpisode(ctx)
        var confirmationRequested = false
        let items = buildEpisodeActions(
            episode: episode, order: [.unfollow], player: PlayerService(),
            downloads: DownloadManager(),
            context: ctx, onShowNotes: {}, onShare: {}, onBookmarks: {},
            onUnfollow: { confirmationRequested = true }
        )
        items.first?.run()
        XCTAssertTrue(confirmationRequested)
        // The podcast (and the episode's link to it) must survive the run.
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<Podcast>()), 1)
        XCTAssertNotNil(episode.podcast)
    }

    func testShuffledFullOrderBuildsAllNineLabelsInOrder() {
        // Regression guard: a full 9-action order in an arbitrary shuffle comes
        // back label-for-label in that order — compactMap must not reorder.
        let ctx = TestStore.freshContext()
        let episode = makeEpisode(ctx)
        let shuffled: [EpisodeAction] = [
            .markPlayed, .unfollow, .share, .download, .playNow,
            .openShowNotes, .addToQueueBottom, .viewBookmarks, .addToQueueTop,
        ]
        let items = buildEpisodeActions(
            episode: episode, order: shuffled, player: PlayerService(),
            downloads: DownloadManager(),
            context: ctx, onShowNotes: {}, onShare: {}, onBookmarks: {}, onUnfollow: {}
        )
        XCTAssertEqual(items.map(\.label), [
            "Mark as played", "Unfollow this podcast", "Share", "Download",
            "Play now", "Open show notes", "Add to end of queue", "Bookmarks",
            "Play next",
        ])
    }

    func testFirstBuiltActionIsFirstConfiguredAction() {
        // The default double-tap reads `actions.first` (EpisodeRow) — it must
        // be the user's FIRST configured action, never the rotor-reversed one.
        let ctx = TestStore.freshContext()
        let episode = makeEpisode(ctx)
        let items = buildEpisodeActions(
            episode: episode, order: defaultEpisodeActions, player: PlayerService(),
            downloads: DownloadManager(),
            context: ctx, onShowNotes: {}, onShare: {}, onBookmarks: {}, onUnfollow: {}
        )
        XCTAssertEqual(items.first?.label, "Play now")
    }

    // MARK: #579 — onMarkPlayed focus runner on the .markPlayed action

    func testMarkPlayedRunnerReceivesNewValueBeforeFlip() {
        // Acceptance criterion: #579 — the runner fires with the NEW played
        // value BEFORE episode.isPlayed flips, so the surface can still find
        // this row's neighbor in its visible list and move VoiceOver focus.
        let ctx = TestStore.freshContext()
        let episode = makeEpisode(ctx, played: false)
        var receivedNewValue: Bool?
        var isPlayedWhenSpyFired: Bool?
        let items = buildEpisodeActions(
            episode: episode, order: [.markPlayed], player: PlayerService(),
            downloads: DownloadManager(),
            context: ctx, onShowNotes: {}, onShare: {}, onBookmarks: {},
            onMarkPlayed: { newValue in
                receivedNewValue = newValue
                isPlayedWhenSpyFired = episode.isPlayed
            }
        )
        XCTAssertEqual(items.map(\.label), ["Mark as played"])
        items.first?.run()
        XCTAssertEqual(receivedNewValue, true, "spy receives the NEW played value")
        XCTAssertEqual(isPlayedWhenSpyFired, false, "spy fires BEFORE the state flips")
        XCTAssertTrue(episode.isPlayed, "state still flips after the spy returns")
    }

    func testMarkPlayedRunnerFiresOnUnplayDirectionToo() {
        // Acceptance criterion: #579 — played→unplayed fires the runner as
        // well, delivering the new value (false) before the flip.
        let ctx = TestStore.freshContext()
        let episode = makeEpisode(ctx, played: true)
        var receivedNewValue: Bool?
        var isPlayedWhenSpyFired: Bool?
        let items = buildEpisodeActions(
            episode: episode, order: [.markPlayed], player: PlayerService(),
            downloads: DownloadManager(),
            context: ctx, onShowNotes: {}, onShare: {}, onBookmarks: {},
            onMarkPlayed: { newValue in
                receivedNewValue = newValue
                isPlayedWhenSpyFired = episode.isPlayed
            }
        )
        XCTAssertEqual(items.map(\.label), ["Mark as unplayed"])
        items.first?.run()
        XCTAssertEqual(receivedNewValue, false, "spy receives the NEW played value")
        XCTAssertEqual(isPlayedWhenSpyFired, true, "spy fires BEFORE the state flips")
        XCTAssertFalse(episode.isPlayed, "state still flips after the spy returns")
    }

    func testMarkPlayedNilRunnerStillFlipsAndSaves() {
        // Regression guard: #579 — surfaces that pass no onMarkPlayed (the
        // default) keep the pre-#579 behavior: activation flips isPlayed and
        // persists the change.
        let ctx = TestStore.freshContext()
        let episode = makeEpisode(ctx, played: false)
        let items = buildEpisodeActions(
            episode: episode, order: [.markPlayed], player: PlayerService(),
            downloads: DownloadManager(),
            context: ctx, onShowNotes: {}, onShare: {}, onBookmarks: {}
        )
        items.first?.run()
        XCTAssertTrue(episode.isPlayed, "flip still happens with no runner")
        XCTAssertTrue(episode.inboxDismissed, "marking played dismisses from inbox (#546)")
        XCTAssertFalse(ctx.hasChanges, "runner saved the flip (saveQuickAction ran)")
    }

    // MARK: #457 — search-aware neighbor focus for Remove from queue

    /// Three distinct queued episodes (unique guids + feed URLs so the shared
    /// summary cache and Podcast.feedURL uniqueness never collide).
    private func makeQueuedTrio(_ ctx: ModelContext) -> [Episode] {
        let repo = QueueRepository(context: ctx)
        return (1...3).map { i in
            let p = Podcast(feedURL: "https://x/q\(i).xml", title: "Show \(i)")
            ctx.insert(p)
            let e = Episode(guid: "q\(i)", title: "Queued \(i)", audioURL: "https://x/q\(i).mp3")
            e.podcast = p
            ctx.insert(e)
            repo.add(e)
            return e
        }
    }

    private func removeAction(
        for episode: Episode,
        ctx: ModelContext,
        visibleQueue: (() -> [Episode])? = nil,
        onFocus: @escaping (PersistentIdentifier?) -> Void
    ) -> QuickActionItem? {
        buildQueueActions(
            episode: episode,
            order: [.removeFromQueue],
            moveMode: .flat,
            player: PlayerService(),
            context: ctx,
            onShowNotes: {},
            onFocus: onFocus,
            visibleQueue: visibleQueue
        ).first
    }

    func testRemoveFromQueueNilProviderFocusesFullQueueNeighbor() {
        // Acceptance criterion: #457 — with no visibleQueue provider (the
        // default), removal focuses the neighbor in the FULL queue, exactly
        // the pre-#457 behavior.
        let ctx = TestStore.freshContext()
        let eps = makeQueuedTrio(ctx)
        var focused: PersistentIdentifier?
        removeAction(for: eps[0], ctx: ctx) { focused = $0 }?.run()
        XCTAssertEqual(focused, eps[1].persistentModelID,
                       "full-queue neighbor (the next row) takes focus")
        XCTAssertEqual(QueueRepository(context: ctx).queue().map(\.guid), ["q2", "q3"],
                       "the episode actually left the queue")
    }

    func testRemoveFromQueueVisibleQueueFocusesNeighborWithinSubset() {
        // Acceptance criterion: #457 — when a search narrows the list, the
        // focused neighbor is the adjacent VISIBLE row, not a filtered-out
        // full-queue neighbor whose id matches no rendered row.
        let ctx = TestStore.freshContext()
        let eps = makeQueuedTrio(ctx)
        var focused: PersistentIdentifier?
        // Search shows q1 and q3; q2 is hidden by the filter.
        removeAction(for: eps[0], ctx: ctx, visibleQueue: { [eps[0], eps[2]] }) {
            focused = $0
        }?.run()
        XCTAssertEqual(focused, eps[2].persistentModelID,
                       "focus lands on the next VISIBLE row (q3), not hidden q2")
        XCTAssertNotEqual(focused, eps[1].persistentModelID)
    }

    func testRemoveFromQueueLastVisibleRowFallsBackToPreviousVisible() {
        // Acceptance criterion: #457 — removing the last visible row focuses
        // the previous visible row.
        let ctx = TestStore.freshContext()
        let eps = makeQueuedTrio(ctx)
        var focused: PersistentIdentifier?
        removeAction(for: eps[2], ctx: ctx, visibleQueue: { [eps[0], eps[2]] }) {
            focused = $0
        }?.run()
        XCTAssertEqual(focused, eps[0].persistentModelID,
                       "no next visible row, so the previous visible row takes focus")
    }

    func testRemoveFromQueueSoleVisibleRowFocusesNil() {
        // Acceptance criterion: #457 — removing the only matching row leaves
        // nothing to focus; the callback still fires with nil so the caller
        // can clear its focus state.
        let ctx = TestStore.freshContext()
        let eps = makeQueuedTrio(ctx)
        var focusFired = false
        var focused: PersistentIdentifier?
        removeAction(for: eps[1], ctx: ctx, visibleQueue: { [eps[1]] }) {
            focusFired = true
            focused = $0
        }?.run()
        XCTAssertTrue(focusFired, "onFocus still fires so the caller can reset")
        XCTAssertNil(focused)
    }

    func testPodcastToggleLabelsReflectState() {
        let ctx = TestStore.freshContext()
        let p = Podcast(feedURL: "https://x/a.xml", title: "Show", autoQueue: true)
        ctx.insert(p)
        let items = buildPodcastActions(
            podcast: p,
            order: [.toggleAutoQueue, .toggleNotifications],
            context: ctx,
            onOpenDetail: {}, onShare: {}, onUnsubscribe: {}
        )
        XCTAssertEqual(items.map(\.label), ["Turn off auto-queue", "Turn on notifications"])
    }
}
