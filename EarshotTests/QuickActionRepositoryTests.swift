import XCTest
import SwiftData
@testable import Earshot

@MainActor
final class QuickActionRepositoryTests: XCTestCase {
    func testEmptyStoreEnablesEveryDefaultAction() {
        let repo = QuickActionRepository(context: TestStore.freshContext())

        XCTAssertEqual(repo.episodeConfiguration(), QuickActionConfiguration(
            enabled: defaultEpisodeActions, available: []
        ))
        XCTAssertEqual(repo.podcastConfiguration(), QuickActionConfiguration(
            enabled: defaultPodcastActions, available: []
        ))
        XCTAssertEqual(repo.queueConfiguration(), QuickActionConfiguration(
            enabled: defaultQueueItemActions, available: []
        ))
    }

    func testEnabledAndAvailableOrdersRoundTripIndependently() {
        let context = TestStore.freshContext()
        let value = QuickActionConfiguration<EpisodeAction>(
            enabled: [.share, .playNow],
            available: [.unfollow, .download, .openShowNotes]
        )
        let repo = QuickActionRepository(context: context)

        repo.setEpisodeConfiguration(value)

        let resolved = QuickActionRepository(context: context).episodeConfiguration()
        XCTAssertEqual(resolved.enabled, value.enabled)
        XCTAssertEqual(Array(resolved.available.prefix(value.available.count)), value.available)
        XCTAssertEqual(Set(resolved.enabled + resolved.available), Set(EpisodeAction.allCases))
    }

    func testLegacyBareRowsKeepEveryActionEnabledInSavedOrder() throws {
        let context = TestStore.freshContext()
        context.insert(QuickActionConfig(
            contentType: .episode, actionKey: EpisodeAction.share.rawValue, sortOrder: 0
        ))
        context.insert(QuickActionConfig(
            contentType: .episode, actionKey: EpisodeAction.playNow.rawValue, sortOrder: 1
        ))
        try context.save()

        let value = QuickActionRepository(context: context).episodeConfiguration()

        XCTAssertEqual(Array(value.enabled.prefix(2)), [.share, .playNow])
        XCTAssertEqual(Set(value.enabled), Set(EpisodeAction.allCases))
        XCTAssertTrue(value.available.isEmpty)
    }

    func testNewActionsJoinAvailableAfterUserHasCustomizedList() {
        let context = TestStore.freshContext()
        let repo = QuickActionRepository(context: context)
        repo.setEpisodeConfiguration(QuickActionConfiguration(
            enabled: [.share], available: [.playNow]
        ))

        let value = repo.episodeConfiguration()

        XCTAssertEqual(value.enabled, [.share])
        XCTAssertEqual(value.available.first, .playNow)
        XCTAssertEqual(Set(value.enabled + value.available), Set(EpisodeAction.allCases))
    }

    func testRepositoryRejectsConfigurationWithNoEnabledAction() {
        let context = TestStore.freshContext()
        let repo = QuickActionRepository(context: context)

        repo.setEpisodeConfiguration(QuickActionConfiguration(
            enabled: [], available: EpisodeAction.allCases
        ))

        XCTAssertEqual(repo.episodeConfiguration().enabled, defaultEpisodeActions)
        XCTAssertTrue(repo.episodeConfiguration().available.isEmpty)
    }

    func testCorruptEncodedStateRepairsOneAvailableActionToEnabled() throws {
        let context = TestStore.freshContext()
        context.insert(QuickActionConfig(
            contentType: .episode,
            actionKey: "available:\(EpisodeAction.share.rawValue)",
            sortOrder: 0
        ))
        try context.save()

        let value = QuickActionRepository(context: context).episodeConfiguration()

        XCTAssertEqual(value.enabled, [.share])
        XCTAssertFalse(value.available.contains(.share))
    }

    func testDuplicateAndUnknownRowsDoNotDuplicateActions() throws {
        let context = TestStore.freshContext()
        for (index, key) in ["enabled:share", "enabled:share", "available:share", "available:futureAction"].enumerated() {
            context.insert(QuickActionConfig(contentType: .episode, actionKey: key, sortOrder: index))
        }
        try context.save()

        let value = QuickActionRepository(context: context).episodeConfiguration()

        XCTAssertEqual(value.enabled, [.share])
        XCTAssertEqual(value.available.filter { $0 == .share }.count, 0)
        XCTAssertEqual(Set(value.enabled + value.available), Set(EpisodeAction.allCases))
    }

    func testContentTypesRemainIndependent() {
        let context = TestStore.freshContext()
        let repo = QuickActionRepository(context: context)
        repo.setEpisodeConfiguration(QuickActionConfiguration(
            enabled: [.share], available: EpisodeAction.allCases.filter { $0 != .share }
        ))

        XCTAssertEqual(repo.episodeOrder(), [.share])
        XCTAssertEqual(repo.podcastOrder(), defaultPodcastActions)
        XCTAssertEqual(repo.queueOrder(), defaultQueueItemActions)
    }

    func testStoreRemoveAddAndRelaunchPreserveBothOrders() {
        let context = TestStore.freshContext()
        let store = QuickActionStore()
        store.configure(context: context)

        XCTAssertTrue(store.removeEpisodeAction(.download))
        XCTAssertFalse(store.episodeActions.contains(.download))
        XCTAssertEqual(store.availableEpisodeActions.last, .download)
        store.addEpisodeAction(.download)
        XCTAssertEqual(store.episodeActions.last, .download)
        XCTAssertFalse(store.availableEpisodeActions.contains(.download))

        let relaunched = QuickActionStore()
        relaunched.configure(context: context)
        XCTAssertEqual(relaunched.episodeActions, store.episodeActions)
        XCTAssertEqual(relaunched.availableEpisodeActions, store.availableEpisodeActions)
    }

    func testStoreNeverRemovesLastEnabledAction() {
        let context = TestStore.freshContext()
        let repo = QuickActionRepository(context: context)
        repo.setQueueConfiguration(QuickActionConfiguration(
            enabled: [.playNow],
            available: QueueItemAction.allCases.filter { $0 != .playNow }
        ))
        let store = QuickActionStore()
        store.configure(context: context)

        XCTAssertFalse(store.removeQueueAction(.playNow))
        XCTAssertEqual(store.queueActions, [.playNow])
    }
}
