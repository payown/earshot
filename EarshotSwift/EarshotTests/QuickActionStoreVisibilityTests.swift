import XCTest
import SwiftData
@testable import Earshot

/// Store-level hide/restore behaviour (#524): the guard against hiding the last
/// visible action, live visible surfaces, and persistence across a reconfigure.
@MainActor
final class QuickActionStoreVisibilityTests: XCTestCase {

    private func makeStore(_ ctx: ModelContext) -> QuickActionStore {
        let store = QuickActionStore()
        store.configure(context: ctx)
        return store
    }

    func testHidingRemovesFromVisibleButKeepsInFullList() {
        let store = makeStore(TestStore.freshContext())
        XCTAssertTrue(store.setEpisodeActionHidden(.share, hidden: true))

        XCTAssertFalse(store.visibleEpisodeActions.contains(.share))
        XCTAssertTrue(store.episodeActions.contains(.share), "hidden action stays in the full list for restore")
        XCTAssertTrue(store.isEpisodeActionHidden(.share))
    }

    func testDefaultDoubleTapIsFirstVisible() {
        let store = makeStore(TestStore.freshContext())
        XCTAssertEqual(store.visibleEpisodeActions.first, defaultEpisodeActions.first)

        // Hiding the current default promotes the next visible action.
        _ = store.setEpisodeActionHidden(defaultEpisodeActions[0], hidden: true)
        XCTAssertEqual(store.visibleEpisodeActions.first, defaultEpisodeActions[1])
    }

    func testCannotHideLastVisibleAction() {
        let store = makeStore(TestStore.freshContext())
        // Hide every podcast action except one.
        let all = store.podcastActions
        for action in all.dropLast() {
            XCTAssertTrue(store.setPodcastActionHidden(action, hidden: true))
        }
        let last = all.last!
        XCTAssertEqual(store.visiblePodcastActions, [last])

        // The guard refuses hiding the final visible action.
        XCTAssertFalse(store.setPodcastActionHidden(last, hidden: true))
        XCTAssertEqual(store.visiblePodcastActions, [last], "still one visible action")
    }

    func testRestoreReturnsToVisible() {
        let store = makeStore(TestStore.freshContext())
        _ = store.setQueueActionHidden(.openShowNotes, hidden: true)
        XCTAssertFalse(store.visibleQueueActions.contains(.openShowNotes))

        XCTAssertTrue(store.setQueueActionHidden(.openShowNotes, hidden: false))
        XCTAssertTrue(store.visibleQueueActions.contains(.openShowNotes))
        XCTAssertFalse(store.isQueueActionHidden(.openShowNotes))
    }

    func testVisibilityPersistsAcrossReconfigure() {
        let ctx = TestStore.freshContext()
        let store = makeStore(ctx)
        _ = store.setEpisodeActionHidden(.download, hidden: true)

        // A fresh store over the same context reloads the hidden state.
        let reloaded = makeStore(ctx)
        XCTAssertTrue(reloaded.isEpisodeActionHidden(.download))
        XCTAssertFalse(reloaded.visibleEpisodeActions.contains(.download))
    }
}
