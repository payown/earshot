import XCTest
import SwiftData
@testable import Earshot

@MainActor
final class QuickActionRepositoryTests: XCTestCase {

    func testEpisodeOrderDefaultsWhenEmpty() {
        let repo = QuickActionRepository(context: TestStore.freshContext())
        XCTAssertEqual(repo.episodeOrder(), defaultEpisodeActions)
    }

    func testPodcastOrderDefaultsWhenEmpty() {
        let repo = QuickActionRepository(context: TestStore.freshContext())
        XCTAssertEqual(repo.podcastOrder(), defaultPodcastActions)
    }

    func testQueueOrderDefaultsWhenEmpty() {
        let repo = QuickActionRepository(context: TestStore.freshContext())
        XCTAssertEqual(repo.queueOrder(), defaultQueueItemActions)
    }

    func testEpisodeOrderRoundTrips() {
        let ctx = TestStore.freshContext()
        // A pre-#572 saved order: all 8 actions that existed before `.unfollow`.
        let custom: [EpisodeAction] = [.share, .openShowNotes, .viewBookmarks, .markPlayed, .download, .addToQueueTop, .addToQueueBottom, .playNow]
        QuickActionRepository(context: ctx).setEpisodeOrder(custom)

        // A fresh repository over the same store reads the persisted order back
        // exactly, and appends the newer `.unfollow` LAST — the no-migration
        // guarantee for existing users' saved 8-action orders (#572).
        let resolved = QuickActionRepository(context: ctx).episodeOrder()
        XCTAssertEqual(Array(resolved.prefix(custom.count)), custom, "stored actions come back in saved order")
        XCTAssertEqual(resolved.last, .unfollow, "actions added after the save are appended last")
        XCTAssertEqual(resolved.count, EpisodeAction.allCases.count, "every action is present exactly once")
    }

    // MARK: #572 — `.unfollow` joins the episode set with no migration

    func testFreshInstallEpisodeOrderEndsWithUnfollow() {
        // Acceptance criterion: #572 — unfollow defaults last (destructive
        // actions never default early), with nothing stored.
        let repo = QuickActionRepository(context: TestStore.freshContext())
        let order = repo.episodeOrder()
        XCTAssertEqual(order, defaultEpisodeActions)
        XCTAssertEqual(order.last, .unfollow)
    }

    func testEpisodeOrderRoundTripsAfterUserMovesUnfollow() {
        // Acceptance criterion: #572 — once the user reorders `.unfollow`
        // themselves, that position persists; resolve() must not force it last.
        // The saved order here predates transcript/audio export and the folder
        // actions, so resolve() appends those to the tail in `allCases`
        // order (the same migration path #572 relies on).
        let ctx = TestStore.freshContext()
        let moved: [EpisodeAction] = [.unfollow, .share, .openShowNotes, .viewBookmarks, .markPlayed, .download, .addToQueueTop, .addToQueueBottom, .playNow]
        QuickActionRepository(context: ctx).setEpisodeOrder(moved)

        XCTAssertEqual(
            QuickActionRepository(context: ctx).episodeOrder(),
            moved + [.exportTranscript, .exportAudio, .addToFolder, .moveToFolder]
        )
    }

    func testPartialStoredOrderResolvesWithUnfollowAppended() {
        // Acceptance criterion: #572 — a partial pre-unfollow save still
        // resolves to the full set with `.unfollow` among the appended tail.
        let ctx = TestStore.freshContext()
        QuickActionRepository(context: ctx).setEpisodeOrder([.share, .playNow])

        let order = QuickActionRepository(context: ctx).episodeOrder()
        XCTAssertEqual(Array(order.prefix(2)), [.share, .playNow])
        XCTAssertTrue(order.contains(.unfollow))
        XCTAssertEqual(order.count, EpisodeAction.allCases.count)
    }

    func testSetReplacesRatherThanAppends() {
        let ctx = TestStore.freshContext()
        let repo = QuickActionRepository(context: ctx)
        repo.setEpisodeOrder([.playNow, .share])
        repo.setEpisodeOrder([.share, .playNow])

        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<QuickActionConfig>()), 2)
    }

    func testNewlyAddedActionsAppendAfterStoredOrder() {
        let ctx = TestStore.freshContext()
        // Persist only a subset (as if an older app version saved fewer actions).
        QuickActionRepository(context: ctx).setEpisodeOrder([.share, .playNow])

        let order = QuickActionRepository(context: ctx).episodeOrder()
        XCTAssertEqual(Array(order.prefix(2)), [.share, .playNow])
        XCTAssertEqual(Set(order), Set(EpisodeAction.allCases), "every action is present")
    }

    func testSetsAreIndependentPerContentType() {
        let ctx = TestStore.freshContext()
        let repo = QuickActionRepository(context: ctx)
        repo.setEpisodeOrder([.share, .playNow, .openShowNotes, .markPlayed, .addToQueueTop, .addToQueueBottom])

        // Podcast + queue still report their defaults.
        XCTAssertEqual(repo.podcastOrder(), defaultPodcastActions)
        XCTAssertEqual(repo.queueOrder(), defaultQueueItemActions)
    }

    func testQueueOrderRoundTrips() {
        let ctx = TestStore.freshContext()
        // A pre-Item-3 saved order: all 7 actions that existed before `.download`.
        let custom: [QueueItemAction] = [.removeFromQueue, .playNow, .moveUp, .moveDown, .moveToTop, .moveToBottom, .openShowNotes]
        QuickActionRepository(context: ctx).setQueueOrder(custom)

        // The stored order comes back exactly, with the newer `.download`
        // appended LAST — the no-migration guarantee for existing users' saved
        // queue orders (Item 3).
        let resolved = QuickActionRepository(context: ctx).queueOrder()
        XCTAssertEqual(Array(resolved.prefix(custom.count)), custom, "stored actions come back in saved order")
        XCTAssertEqual(resolved.last, .download, "actions added after the save are appended last")
        XCTAssertEqual(resolved.count, QueueItemAction.allCases.count, "every action is present exactly once")
    }

    func testPartialStoredQueueOrderResolvesWithDownloadAppended() {
        // Acceptance criterion: Item 3 — a partial pre-download save still
        // resolves to the full set with `.download` appended at the end.
        let ctx = TestStore.freshContext()
        QuickActionRepository(context: ctx).setQueueOrder([.playNow, .removeFromQueue])

        let order = QuickActionRepository(context: ctx).queueOrder()
        XCTAssertEqual(Array(order.prefix(2)), [.playNow, .removeFromQueue])
        XCTAssertEqual(order.last, .download, "download is appended at the end for existing users")
        XCTAssertEqual(order.count, QueueItemAction.allCases.count)
    }
}
