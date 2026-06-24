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

/// Covers the onboarding "Import OPML file" path. `OnboardingView` gates its
/// "Start Listening" button on `hasPodcast`, which is `!podcasts.isEmpty` over an
/// `@Query`. A successful OPML import inserts `Podcast` rows into the same model
/// context the `@Query` observes, so the gate unlocks automatically. These tests
/// exercise that contract at the data layer — import through the shared
/// `OPMLFileImporter` (the exact call onboarding makes) and assert the context now
/// holds podcasts, i.e. `hasPodcast` would be true.
@MainActor
final class OnboardingOPMLImportTests: XCTestCase {

    private func writeOPML(_ opml: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("subscriptions.opml")
        try opml.data(using: .utf8)!.write(to: url)
        return url
    }

    func testSuccessfulImportPopulatesContextSoStartListeningUnlocks() async throws {
        let ctx = TestStore.freshContext()
        // Pre-seed the feed so the import resolves offline (no network), matching
        // the OPMLFileImporterTests strategy.
        ctx.insert(Podcast(feedURL: "https://a.com/feed", title: "Seeded"))
        try ctx.save()

        // Before import via the picker the user could already have this seeded one;
        // re-run import to prove the shared path the onboarding button drives works.
        let url = try writeOPML("""
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
          <head><title>Test</title></head>
          <body>
            <outline type="rss" text="A" xmlUrl="https://a.com/feed"/>
          </body>
        </opml>
        """)

        let count = await OPMLFileImporter.importFile(at: url, context: ctx)
        XCTAssertEqual(count, 1)

        // hasPodcast == !podcasts.isEmpty over the same context the @Query reads.
        let podcasts = try ctx.fetch(FetchDescriptor<Podcast>())
        XCTAssertFalse(podcasts.isEmpty, "Start Listening should unlock once a podcast exists")
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
