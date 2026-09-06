import SwiftData
import XCTest
@testable import Earshot

@MainActor
final class LocalSearchLoaderTests: XCTestCase {
    func testCustomAndPublisherNamesBothFindFollowedPodcast() async throws {
        let context = TestStore.freshContext()
        let podcast = Podcast(feedURL: "https://names.example/feed", title: "Publisher Audio")
        context.insert(podcast)
        try context.save()
        try PodcastDisplayNames.shared.save("Personal Podcast", for: podcast, context: context)
        let loader = LocalPodcastSearchLoader(modelContainer: context.container)
        let custom = try await loader.page(query: "Personal", limit: 100)
        let publisher = try await loader.page(query: "Publisher", limit: 100)
        XCTAssertEqual(custom.ids, [podcast.persistentModelID])
        XCTAssertEqual(publisher.ids, [podcast.persistentModelID])
    }

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

    func testPodcastSearchUsesExactSearchLogicFollowedPredicateAndStableCaps() async throws {
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

        let expanded = try await loader.page(query: "sWiFt", limit: 50)
        XCTAssertEqual(expanded.ids.count, 30, "catalog-only podcasts stay outside Library search")
        XCTAssertFalse(expanded.hasMore)
        XCTAssertEqual(Array(expanded.ids.prefix(25)), first.ids, "Show more keeps the first page stable")
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
}
