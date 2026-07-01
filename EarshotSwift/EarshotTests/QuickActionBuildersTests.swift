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

    func testEpisodeUnfollowActionDroppedWhenNoHandler() {
        let ctx = TestStore.freshContext()
        let episode = makeEpisode(ctx)
        // No `onUnfollow` provided (the default): the destructive action must not
        // appear where it can't act (#528).
        let items = buildEpisodeActions(
            episode: episode, order: [.playNow, .unfollowPodcast], player: PlayerService(),
            downloads: DownloadManager(),
            context: ctx, onShowNotes: {}, onShare: {}, onBookmarks: {}
        )
        XCTAssertEqual(items.map(\.label), ["Play now"])
    }

    func testEpisodeUnfollowActionPresentDestructiveAndInvokesHandler() {
        let ctx = TestStore.freshContext()
        let episode = makeEpisode(ctx)
        var requested = false
        let items = buildEpisodeActions(
            episode: episode, order: [.unfollowPodcast], player: PlayerService(),
            downloads: DownloadManager(),
            context: ctx, onShowNotes: {}, onShare: {}, onBookmarks: {},
            onUnfollow: { requested = true }
        )
        XCTAssertEqual(items.map(\.label), ["Unfollow this podcast"])
        XCTAssertEqual(items.first?.isDestructive, true, "unfollow is destructive")
        // Running it hands off to the host (which presents the confirmation) — it
        // must NOT unfollow directly.
        items.first?.run()
        XCTAssertTrue(requested)
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
