import SwiftData
import XCTest
@testable import Earshot

@MainActor
final class LocalSearchLoaderTests: XCTestCase {
    func testAddPodcastPlanAndLoaderSetNeverCreateEpisodeOrBookmarkLoaders() {
        let plan = LocalSearchLoaderPlan(scope: .addPodcast)
        XCTAssertTrue(plan.loadsPodcasts)
        XCTAssertFalse(plan.loadsEpisodes)
        XCTAssertFalse(plan.loadsBookmarks)

        let loaders = LocalSearchLoaders(
            scope: .addPodcast,
            modelContainer: TestStore.container
        )
        XCTAssertNil(loaders.episodes)
        XCTAssertNil(loaders.bookmarks)
    }

    func testLibraryPlanCreatesAllThreeIndependentSectionLoaders() {
        let plan = LocalSearchLoaderPlan(scope: .library)
        XCTAssertTrue(plan.loadsPodcasts)
        XCTAssertTrue(plan.loadsEpisodes)
        XCTAssertTrue(plan.loadsBookmarks)

        let loaders = LocalSearchLoaders(
            scope: .library,
            modelContainer: TestStore.container
        )
        XCTAssertNotNil(loaders.episodes)
        XCTAssertNotNil(loaders.bookmarks)
    }

    func testPodcastSearchUsesExactSearchLogicFollowedPredicateAndIncrementalPages() async throws {
        let context = TestStore.freshContext()
        for index in 0..<30 {
            context.insert(Podcast(
                feedURL: "https://example.com/\(index)",
                title: "Swift Show \(index)"
            ))
        }
        context.insert(Podcast(
            feedURL: "https://example.com/catalog",
            title: "Swift Catalog",
            subscriptionStateRaw: PodcastSubscriptionState.catalogOnly.rawValue
        ))
        context.insert(Podcast(
            feedURL: "https://example.com/no-match",
            title: "Unrelated"
        ))
        try context.save()

        let loader = LocalPodcastSearchLoader(modelContainer: TestStore.container)
        let first = try await loader.page(query: "sWiFt", limit: 25)
        XCTAssertEqual(first.ids.count, 25)
        XCTAssertTrue(first.hasMore)

        let second = try await loader.page(
            query: "sWiFt",
            after: try XCTUnwrap(first.nextOffset),
            limit: 25
        )
        XCTAssertEqual(second.ids.count, 5, "catalog-only podcasts stay outside Library search")
        XCTAssertFalse(second.hasMore)
        XCTAssertTrue(Set(first.ids).isDisjoint(with: second.ids))
        XCTAssertEqual(Set(first.ids + second.ids).count, 30)
        XCTAssertLessThanOrEqual(
            second.inspectedCount,
            6,
            "Show more resumes at its cursor instead of rescanning the first 25 results"
        )
    }

    func testEpisodeAndBookmarkPredicatesExcludeCatalogOnlyContent() async throws {
        let context = TestStore.freshContext()
        let followed = Podcast(feedURL: "https://example.com/followed", title: "Followed")
        let catalog = Podcast(
            feedURL: "https://example.com/catalog",
            title: "Catalog",
            subscriptionStateRaw: PodcastSubscriptionState.catalogOnly.rawValue
        )
        context.insert(followed)
        context.insert(catalog)

        let followedEpisode = Episode(guid: "f", title: "Needle Episode", audioURL: "https://example.com/f.mp3")
        followedEpisode.podcast = followed
        context.insert(followedEpisode)
        let catalogEpisode = Episode(guid: "c", title: "Needle Episode", audioURL: "https://example.com/c.mp3")
        catalogEpisode.podcast = catalog
        context.insert(catalogEpisode)
        context.insert(Bookmark(episode: followedEpisode, positionSeconds: 1, note: "Needle note"))
        context.insert(Bookmark(episode: catalogEpisode, positionSeconds: 2, note: "Needle note"))
        try context.save()

        let episodePage = try await LocalEpisodeSearchLoader(
            modelContainer: TestStore.container
        ).page(query: "needle", limit: 25)
        let bookmarkPage = try await LocalBookmarkSearchLoader(
            modelContainer: TestStore.container
        ).page(query: "needle", limit: 25)

        XCTAssertEqual(episodePage.ids, [followedEpisode.persistentModelID])
        XCTAssertEqual(bookmarkPage.ids.count, 1)
    }

    func testCancelledRequestCannotCompleteAStoreScan() async throws {
        let context = TestStore.freshContext()
        context.insert(Podcast(feedURL: "https://example.com/one", title: "One"))
        try context.save()
        let loader = LocalPodcastSearchLoader(modelContainer: TestStore.container)

        let request = Task { try await loader.page(query: "one", limit: 25) }
        request.cancel()
        do {
            _ = try await request.value
            XCTFail("A cancelled query must not publish a result")
        } catch is CancellationError {
            // Expected: each store batch and row checks cooperative cancellation.
        }
    }

    func testSupersededOrCancelledRequestCannotPublish() {
        XCTAssertTrue(LocalSearchPublicationPolicy.accepts(
            requestedTerm: "swift",
            currentTerm: "swift",
            isCancelled: false
        ))
        XCTAssertFalse(LocalSearchPublicationPolicy.accepts(
            requestedTerm: "swift",
            currentTerm: "swiftui",
            isCancelled: false
        ))
        XCTAssertFalse(LocalSearchPublicationPolicy.accepts(
            requestedTerm: "swift",
            currentTerm: "swift",
            isCancelled: true
        ))
    }

    func testStoreCandidatePreservesCrossFieldSearchSemantics() async throws {
        let context = TestStore.freshContext()
        let podcast = Podcast(
            feedURL: "https://example.com/cross-field",
            title: "Daily Swift",
            author: "Team Earshot"
        )
        context.insert(podcast)
        let episode = Episode(
            guid: "cross",
            title: "Episode boundary",
            audioURL: "https://example.com/cross.mp3"
        )
        episode.podcast = podcast
        context.insert(episode)
        context.insert(Bookmark(
            episode: episode,
            positionSeconds: 1,
            note: "Remember episode"
        ))
        try context.save()

        let podcastPage = try await LocalPodcastSearchLoader(
            modelContainer: TestStore.container
        ).page(query: "Swift Team")
        let bookmarkPage = try await LocalBookmarkSearchLoader(
            modelContainer: TestStore.container
        ).page(query: "episode Episode")

        XCTAssertEqual(podcastPage.ids, [podcast.persistentModelID])
        XCTAssertEqual(bookmarkPage.ids.count, 1)
    }

    func testStorePredicateDoesNotInspectUnrelatedEpisodeCatalog() async throws {
        let context = TestStore.freshContext()
        let podcast = Podcast(feedURL: "https://example.com/scale", title: "Scale")
        context.insert(podcast)
        for index in 0..<2_000 {
            let episode = Episode(
                guid: "unrelated-\(index)",
                title: "Unrelated \(index)",
                audioURL: "https://example.com/unrelated-\(index).mp3"
            )
            episode.podcast = podcast
            context.insert(episode)
        }
        for index in 0..<30 {
            let episode = Episode(
                guid: "needle-\(index)",
                title: "Needle \(String(format: "%02d", index))",
                audioURL: "https://example.com/needle-\(index).mp3"
            )
            episode.podcast = podcast
            context.insert(episode)
        }
        try context.save()

        let page = try await LocalEpisodeSearchLoader(
            modelContainer: TestStore.container
        ).page(query: "needle")

        XCTAssertEqual(page.ids.count, LocalSearchScanPolicy.resultPageSize)
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(
            page.inspectedCount,
            LocalSearchScanPolicy.resultPageSize + 1,
            "SQLite text filtering prevents an unrelated 2,000-row catalog scan"
        )
    }

    func testLargeCatalogDiagnosticPublishesOnlyOneBoundedPage() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUN_LOCAL_SEARCH_SCALE_DIAG"] != nil,
            "Set RUN_LOCAL_SEARCH_SCALE_DIAG=1 for the 242,000-row diagnostic."
        )
        let context = TestStore.freshContext()
        let podcast = Podcast(feedURL: "https://example.com/diagnostic", title: "Diagnostic")
        context.insert(podcast)
        for index in 0..<242_000 {
            let episode = Episode(
                guid: "diag-\(index)",
                title: index < 30 ? "Needle \(index)" : "Unrelated \(index)",
                audioURL: "https://example.com/diag-\(index).mp3"
            )
            episode.podcast = podcast
            context.insert(episode)
        }
        try context.save()

        let page = try await LocalEpisodeSearchLoader(
            modelContainer: TestStore.container
        ).page(query: "needle")

        XCTAssertEqual(page.ids.count, LocalSearchScanPolicy.resultPageSize)
        XCTAssertEqual(page.inspectedCount, LocalSearchScanPolicy.resultPageSize + 1)
    }
}
