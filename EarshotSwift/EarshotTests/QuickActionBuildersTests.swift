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
            context: ctx,
            onShowNotes: {},
            onShare: {}
        )
        XCTAssertEqual(items.map(\.label), ["Share", "Play now", "Add to queue (top)"])
    }

    func testEpisodeMarkPlayedLabelReflectsState() {
        let ctx = TestStore.freshContext()
        let played = makeEpisode(ctx, played: true)
        let items = buildEpisodeActions(
            episode: played, order: [.markPlayed], player: PlayerService(),
            context: ctx, onShowNotes: {}, onShare: {}
        )
        XCTAssertEqual(items.map(\.label), ["Mark as unplayed"])
    }

    func testQueueActionsDropMovesWhenDisabled() {
        let ctx = TestStore.freshContext()
        let episode = makeEpisode(ctx)
        let items = buildQueueActions(
            episode: episode,
            order: defaultQueueItemActions,
            moveActionsEnabled: false,
            player: PlayerService(),
            context: ctx,
            onShowNotes: {},
            onFocus: { _ in }
        )
        XCTAssertEqual(items.map(\.label), ["Play now", "Remove from queue", "Open show notes"])
    }

    func testQueueActionsIncludeMovesWhenEnabledInConfiguredOrder() {
        let ctx = TestStore.freshContext()
        let episode = makeEpisode(ctx)
        let items = buildQueueActions(
            episode: episode,
            order: [.moveToTop, .playNow, .removeFromQueue],
            moveActionsEnabled: true,
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
