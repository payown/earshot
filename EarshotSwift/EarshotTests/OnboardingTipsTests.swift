import XCTest
import SwiftData
@testable import Earshot

final class OnboardingContentTests: XCTestCase {

    func testSevenPagesInOrder() {
        let pages = OnboardingContent.pages
        XCTAssertEqual(pages.count, 7)
        XCTAssertEqual(pages.first?.title, "Welcome to Earshot")
        XCTAssertEqual(pages.last?.title, "You're all set")
        XCTAssertEqual(pages.map(\.id), Array(0..<7))
    }

    func testExactlyOneAddPodcastPage() {
        let addPages = OnboardingContent.pages.filter(\.isAddPodcast)
        XCTAssertEqual(addPages.count, 1)
        XCTAssertEqual(addPages.first?.title, "Add your first podcast")
    }
}

final class TipsEncodingTests: XCTestCase {

    func testEncodeDecodeRoundTrip() {
        let set: Set<String> = ["inbox", "queue"]
        let encoded = TipsStore.encode(set)
        XCTAssertEqual(TipsStore.decode(encoded), set)
    }

    func testDecodeEmpty() {
        XCTAssertTrue(TipsStore.decode(nil).isEmpty)
        XCTAssertTrue(TipsStore.decode("").isEmpty)
    }

    func testAllTipCategoriesHaveMessages() {
        for tip in TipCategory.allCases {
            XCTAssertFalse(tip.message.isEmpty)
        }
    }
}

@MainActor
final class TipsStoreTests: XCTestCase {

    func testTipShowsOnceThenIsRemembered() {
        let ctx = TestStore.freshContext()
        let store = TipsStore()
        store.configure(context: ctx)

        XCTAssertTrue(store.shouldShow(.inbox))
        store.markShown(.inbox)
        XCTAssertFalse(store.shouldShow(.inbox))
        // Other categories are unaffected.
        XCTAssertTrue(store.shouldShow(.queue))
    }

    func testDismissalPersistsAcrossReconfigure() {
        let ctx = TestStore.freshContext()
        let store = TipsStore()
        store.configure(context: ctx)
        store.markShown(.downloads)

        // A fresh store over the same context reads the persisted dismissal.
        let reopened = TipsStore()
        reopened.configure(context: ctx)
        XCTAssertFalse(reopened.shouldShow(.downloads))
    }

    func testResetReenablesTips() {
        let ctx = TestStore.freshContext()
        let store = TipsStore()
        store.configure(context: ctx)
        store.markShown(.inbox)
        store.markShown(.queue)

        store.reset()

        XCTAssertTrue(store.shouldShow(.inbox))
        XCTAssertTrue(store.shouldShow(.queue))
    }
}
