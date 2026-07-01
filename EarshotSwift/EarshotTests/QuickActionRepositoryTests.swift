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
        let custom: [EpisodeAction] = [.share, .openShowNotes, .viewBookmarks, .markPlayed, .download, .addToQueueTop, .addToQueueBottom, .playNow]
        QuickActionRepository(context: ctx).setEpisodeOrder(custom)

        // A fresh repository over the same store reads the persisted order.
        XCTAssertEqual(QuickActionRepository(context: ctx).episodeOrder(), custom)
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
        let custom: [QueueItemAction] = [.removeFromQueue, .playNow, .moveUp, .moveDown, .moveToTop, .moveToBottom, .openShowNotes]
        QuickActionRepository(context: ctx).setQueueOrder(custom)
        XCTAssertEqual(QuickActionRepository(context: ctx).queueOrder(), custom)
    }

    // MARK: Hidden flag (#524)

    func testHiddenDefaultsEmptyWhenNothingStored() {
        let repo = QuickActionRepository(context: TestStore.freshContext())
        XCTAssertTrue(repo.episodeHidden().isEmpty)
        XCTAssertTrue(repo.podcastHidden().isEmpty)
        XCTAssertTrue(repo.queueHidden().isEmpty)
    }

    func testHiddenRoundTripsWithOrder() {
        let ctx = TestStore.freshContext()
        QuickActionRepository(context: ctx).setEpisode(
            order: defaultEpisodeActions, hidden: [EpisodeAction.share.rawValue])

        let fresh = QuickActionRepository(context: ctx)
        XCTAssertEqual(fresh.episodeHidden(), [EpisodeAction.share.rawValue])
        XCTAssertEqual(fresh.episodeOrder(), defaultEpisodeActions, "order preserved alongside hidden")
    }

    func testReorderPreservesHiddenFlags() {
        let ctx = TestStore.freshContext()
        let repo = QuickActionRepository(context: ctx)
        repo.setEpisode(order: defaultEpisodeActions, hidden: [EpisodeAction.download.rawValue])

        // A plain reorder (no hidden argument) must not re-enable the hidden action.
        var reordered = defaultEpisodeActions
        reordered.reverse()
        repo.setEpisodeOrder(reordered)

        XCTAssertEqual(QuickActionRepository(context: ctx).episodeHidden(), [EpisodeAction.download.rawValue])
    }

    func testRestoreClearsHiddenFlag() {
        let ctx = TestStore.freshContext()
        let repo = QuickActionRepository(context: ctx)
        repo.setEpisode(order: defaultEpisodeActions, hidden: [EpisodeAction.share.rawValue])
        repo.setEpisode(order: defaultEpisodeActions, hidden: [])

        XCTAssertTrue(QuickActionRepository(context: ctx).episodeHidden().isEmpty)
    }

    func testHiddenSetsAreIndependentPerContentType() {
        let ctx = TestStore.freshContext()
        let repo = QuickActionRepository(context: ctx)
        repo.setEpisode(order: defaultEpisodeActions, hidden: [EpisodeAction.share.rawValue])

        XCTAssertTrue(repo.podcastHidden().isEmpty)
        XCTAssertTrue(repo.queueHidden().isEmpty)
    }
}
