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
            enabled: defaultQueueItemActions,
            available: QueueItemAction.allCases.filter { !defaultQueueItemActions.contains($0) }
        ))
        XCTAssertEqual(
            repo.playerButtonConfiguration(for: .rewind).enabled,
            PlayerTransportButton.rewind.defaultActions
        )
        XCTAssertEqual(
            repo.playerButtonConfiguration(for: .fastForward).enabled,
            PlayerTransportButton.fastForward.defaultActions
        )
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

    func testLegacyQueueRowsKeepOldActionsButNewEpisodeActionsStayAvailable() throws {
        let context = TestStore.freshContext()
        context.insert(QuickActionConfig(contentType: .queueItem, actionKey: "download", sortOrder: 0))
        context.insert(QuickActionConfig(contentType: .queueItem, actionKey: "playNow", sortOrder: 1))
        try context.save()

        let value = QuickActionRepository(context: context).queueConfiguration()
        XCTAssertEqual(Array(value.enabled.prefix(2)), [.download, .playNow])
        XCTAssertEqual(Set(value.enabled), Set(defaultQueueItemActions))
        XCTAssertEqual(Set(value.available), Set(QueueItemAction.allCases).subtracting(defaultQueueItemActions))
    }

    func testExistingQueueSelectionDoesNotAcquireNewActionsUntilEnabled() {
        let context = TestStore.freshContext()
        let repo = QuickActionRepository(context: context)
        repo.setQueueConfiguration(.init(enabled: [.moveUp, .download], available: [.playNow]))
        var value = repo.queueConfiguration()
        XCTAssertEqual(value.enabled, [.moveUp, .download, .pickUpToDrag, .openEpisodeDetails])
        XCTAssertTrue(value.available.contains(.markPlayed))

        let store = QuickActionStore()
        store.configure(context: context)
        store.addQueueAction(.markPlayed)
        value = QuickActionRepository(context: context).queueConfiguration()
        XCTAssertEqual(value.enabled, [.moveUp, .download, .pickUpToDrag, .openEpisodeDetails, .markPlayed])
        XCTAssertFalse(value.available.contains(.markPlayed))
    }

    func testFormerFixedQueueActionsCanBeReorderedAndDisabledAcrossRelaunch() {
        let context = TestStore.freshContext()
        let repo = QuickActionRepository(context: context)
        repo.setQueueConfiguration(.init(
            enabled: [.playNow, .openEpisodeDetails, .pickUpToDrag],
            available: QueueItemAction.allCases.filter {
                ![QueueItemAction.playNow, .openEpisodeDetails, .pickUpToDrag].contains($0)
            }
        ))
        let store = QuickActionStore()
        store.configure(context: context)
        store.moveQueueActions(from: IndexSet(integer: 2), to: 0)
        XCTAssertEqual(store.queueActions.prefix(3), [.pickUpToDrag, .playNow, .openEpisodeDetails])
        XCTAssertTrue(store.removeQueueAction(.openEpisodeDetails))
        XCTAssertTrue(store.removeQueueAction(.pickUpToDrag))

        let relaunched = QuickActionStore()
        relaunched.configure(context: context)
        XCTAssertEqual(relaunched.queueActions, [.playNow])
        XCTAssertTrue(relaunched.availableQueueActions.contains(.openEpisodeDetails))
        XCTAssertTrue(relaunched.availableQueueActions.contains(.pickUpToDrag))
    }

    func testQueueReorderPreservesUnknownFutureActionRows() throws {
        let context = TestStore.freshContext()
        context.insert(QuickActionConfig(contentType: .queueItem, actionKey: "enabled:playNow", sortOrder: 0))
        context.insert(QuickActionConfig(contentType: .queueItem, actionKey: "available:futureQueueAction", sortOrder: 1))
        try context.save()
        let repo = QuickActionRepository(context: context)
        let current = repo.queueConfiguration()
        repo.setQueueConfiguration(.init(enabled: current.enabled, available: current.available))
        let rows = try context.fetch(FetchDescriptor<QuickActionConfig>())
        XCTAssertTrue(rows.contains { $0.contentType == .queueItem && $0.actionKey == "available:futureQueueAction" })
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

    func testTransportActionsStartAvailableWithoutAddingPlayerButtons() {
        let repo = QuickActionRepository(context: TestStore.freshContext())
        let value = repo.transportConfiguration()

        XCTAssertTrue(value.enabled.isEmpty)
        XCTAssertEqual(value.available, TransportAction.allCases)
    }

    func testTransportActionsCanRemoveAllAndRoundTripAcrossStoreConfiguration() {
        let context = TestStore.freshContext()
        let store = QuickActionStore()
        store.configure(context: context)

        store.addTransportAction(.skipBack120)
        store.addTransportAction(.skipForward300)
        store.moveTransportActions(from: IndexSet(integer: 1), to: 0)
        XCTAssertEqual(store.transportActions, [.skipForward300, .skipBack120])

        store.removeTransportAction(.skipForward300)
        store.removeTransportAction(.skipBack120)
        XCTAssertTrue(store.transportActions.isEmpty)
        let expectedAvailable = store.availableTransportActions

        let relaunched = QuickActionStore()
        relaunched.configure(context: context)
        XCTAssertTrue(relaunched.transportActions.isEmpty)
        XCTAssertEqual(relaunched.availableTransportActions, expectedAvailable)
    }

    func testTransportActionRowsRemainIndependentFromEpisodeQueueRows() {
        let context = TestStore.freshContext()
        let repo = QuickActionRepository(context: context)
        repo.setEpisodeConfiguration(QuickActionConfiguration(
            enabled: [.share], available: EpisodeAction.allCases.filter { $0 != .share }
        ))
        repo.setQueueConfiguration(QuickActionConfiguration(
            enabled: [.playNow], available: QueueItemAction.allCases.filter { $0 != .playNow }
        ))
        repo.setTransportConfiguration(QuickActionConfiguration(
            enabled: [.skipForward120],
            available: TransportAction.allCases.filter { $0 != .skipForward120 }
        ))

        XCTAssertEqual(repo.episodeOrder(), [.share])
        XCTAssertEqual(repo.queueOrder(), [.playNow])
        XCTAssertEqual(repo.transportConfiguration().enabled, [.skipForward120])
    }

    @MainActor
    func testPlayerButtonRotorActionsCanBeMovedAndPersistedIndependently() {
        let context = TestStore.freshContext()
        let store = QuickActionStore()
        store.configure(context: context)

        XCTAssertEqual(store.rewindButtonActions, [.previousChapter, .previousInQueue])
        XCTAssertEqual(
            store.fastForwardButtonActions,
            [.nextChapter, .nextInQueue, .markPlayedAndNextInQueue]
        )

        store.removePlayerButtonAction(.previousChapter, from: .rewind)
        store.removePlayerButtonAction(.nextChapter, from: .fastForward)
        store.addPlayerButtonAction(.nextChapter, to: .rewind)
        store.addPlayerButtonAction(.previousChapter, to: .fastForward)

        let relaunched = QuickActionStore()
        relaunched.configure(context: context)
        XCTAssertEqual(relaunched.rewindButtonActions, [.previousInQueue, .nextChapter])
        XCTAssertEqual(
            relaunched.fastForwardButtonActions,
            [.nextInQueue, .markPlayedAndNextInQueue, .previousChapter]
        )

        for action in relaunched.rewindButtonActions {
            relaunched.removePlayerButtonAction(action, from: .rewind)
        }
        for action in relaunched.fastForwardButtonActions {
            relaunched.removePlayerButtonAction(action, from: .fastForward)
        }
        let withNoRotorActions = QuickActionStore()
        withNoRotorActions.configure(context: context)
        XCTAssertTrue(withNoRotorActions.rewindButtonActions.isEmpty)
        XCTAssertTrue(withNoRotorActions.fastForwardButtonActions.isEmpty)
    }
}
