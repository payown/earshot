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
        let custom: [EpisodeAction] = [.share, .openShowNotes, .markPlayed, .addToQueueTop, .addToQueueBottom, .playNow]
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
}
