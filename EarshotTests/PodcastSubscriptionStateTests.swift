import SwiftData
import XCTest
@testable import Earshot

@MainActor
final class PodcastSubscriptionStateTests: XCTestCase {
    func testFollowedPredicateAndCountFailOpenExceptExactCatalogValue() throws {
        let context = TestStore.freshContext()
        let legacy = Podcast(feedURL: "https://state.example/legacy", title: "Legacy")
        let catalog = Podcast(
            feedURL: "https://state.example/catalog",
            title: "Catalog",
            subscriptionStateRaw: PodcastSubscriptionState.catalogOnly.rawValue
        )
        let explicit = Podcast(
            feedURL: "https://state.example/explicit",
            title: "Explicit",
            subscriptionStateRaw: "followed"
        )
        let future = Podcast(
            feedURL: "https://state.example/future",
            title: "Future",
            subscriptionStateRaw: "future-state"
        )
        [legacy, catalog, explicit, future].forEach(context.insert)
        try context.save()

        let followed = try context.fetch(PodcastQuery.followedDescriptor(
            sortBy: [SortDescriptor(\.title)]
        ))

        XCTAssertEqual(followed.map(\.title), ["Explicit", "Future", "Legacy"])
        XCTAssertEqual(try PodcastQuery.followedCount(in: context), 3)
        XCTAssertTrue(legacy.isFollowed)
        XCTAssertTrue(explicit.isFollowed)
        XCTAssertTrue(future.isFollowed)
        XCTAssertTrue(catalog.isCatalogOnly)
    }

    func testLibraryOwnedEpisodeAndBookmarkPredicatesExcludeCatalogGraph() throws {
        let context = TestStore.freshContext()
        let followed = Podcast(feedURL: "https://owned.example/followed", title: "Followed")
        let catalog = Podcast(
            feedURL: "https://owned.example/catalog",
            title: "Catalog",
            subscriptionStateRaw: PodcastSubscriptionState.catalogOnly.rawValue
        )
        context.insert(followed)
        context.insert(catalog)
        let followedEpisode = Episode(
            guid: "followed", title: "Followed episode", audioURL: "https://owned.example/f.mp3"
        )
        followedEpisode.podcast = followed
        let catalogEpisode = Episode(
            guid: "catalog", title: "Catalog episode", audioURL: "https://owned.example/c.mp3"
        )
        catalogEpisode.podcast = catalog
        context.insert(followedEpisode)
        context.insert(catalogEpisode)
        context.insert(Episode(
            guid: "orphan", title: "Orphan episode", audioURL: "https://owned.example/o.mp3"
        ))
        context.insert(Bookmark(episode: followedEpisode, positionSeconds: 10))
        context.insert(Bookmark(episode: catalogEpisode, positionSeconds: 20))
        context.insert(Bookmark(episode: nil, positionSeconds: 30))
        context.insert(QueueItem(episode: catalogEpisode, position: 0))
        context.insert(ListeningSession(
            episode: catalogEpisode,
            podcast: catalog,
            durationSeconds: 30
        ))
        try context.save()

        XCTAssertEqual(
            try context.fetch(FetchDescriptor<Episode>())
                .filter(PodcastQuery.isInFollowedLibrary)
                .map(\.guid),
            ["followed"]
        )
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<Bookmark>())
                .filter(PodcastQuery.isInFollowedLibrary)
                .count,
            1
        )
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<QueueItem>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ListeningSession>()), 1)
        XCTAssertNotNil(
            try PodcastIdentityService(context: context)
                .existingAnyState(feedURL: catalog.feedURL)
        )
        XCTAssertNotNil(
            try PodcastIdentityService(context: context)
                .existingFollowed(feedURL: followed.feedURL)
        )
        XCTAssertNil(
            try PodcastIdentityService(context: context)
                .existingFollowed(feedURL: catalog.feedURL)
        )
    }

    func testFolderAndInboxReadsHideCatalogRowsEvenWithCorruptMembership() throws {
        let context = TestStore.freshContext()
        let followed = Podcast(feedURL: "https://boundary.example/followed", title: "Followed")
        let catalog = Podcast(
            feedURL: "https://boundary.example/catalog",
            title: "Catalog",
            subscriptionStateRaw: PodcastSubscriptionState.catalogOnly.rawValue
        )
        context.insert(followed)
        context.insert(catalog)
        let folder = PodcastFolder(name: "Folder")
        context.insert(folder)
        context.insert(FolderMembership(folder: folder, podcast: followed, sortOrder: 0))
        context.insert(FolderMembership(folder: folder, podcast: catalog, sortOrder: 1))
        let catalogEpisode = Episode(
            guid: "catalog-inbox",
            title: "Catalog inbox episode",
            audioURL: "https://boundary.example/catalog.mp3",
            inboxDismissed: false
        )
        catalogEpisode.podcast = catalog
        context.insert(catalogEpisode)
        try context.save()

        let folders = FolderRepository(context: context)
        XCTAssertEqual(folders.podcasts(in: folder).map(\.title), ["Followed"])
        XCTAssertFalse(folders.opmlExportString().contains(catalog.feedURL))
        XCTAssertEqual(InboxRepository(context: context).inboxCount(optInOnly: false), 0)

        folders.setMemberships(for: catalog, folders: [folder])
        let catalogID = catalog.persistentModelID
        let catalogMemberships = try context.fetch(FetchDescriptor<FolderMembership>())
            .filter { $0.podcast?.persistentModelID == catalogID }
        XCTAssertTrue(catalogMemberships.isEmpty)
    }

    func testDuplicateRepairKeepsFollowedIdentityAndSettings() throws {
        let context = TestStore.freshContext()
        let followed = Podcast(
            feedURL: "HTTPS://repair.example:443/feed#old",
            title: "Followed metadata",
            autoQueue: true,
            notificationEnabled: true,
            speedOverride: 1.5,
            inboxIncluded: true,
            createdAt: Date(timeIntervalSince1970: 20)
        )
        let catalog = Podcast(
            feedURL: "https://repair.example/feed",
            title: "New catalog metadata",
            subscriptionStateRaw: PodcastSubscriptionState.catalogOnly.rawValue,
            autoQueue: false,
            notificationEnabled: false,
            speedOverride: nil,
            inboxIncluded: false,
            createdAt: Date(timeIntervalSince1970: 10)
        )
        context.insert(followed)
        context.insert(catalog)
        try context.save()

        _ = try IdentityRepairService(context: context).repairAll()
        try context.save()

        let survivor = try XCTUnwrap(
            try context.fetch(FetchDescriptor<Podcast>()).first
        )
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Podcast>()), 1)
        XCTAssertTrue(survivor.isFollowed)
        XCTAssertTrue(survivor.autoQueue)
        XCTAssertEqual(survivor.notificationEnabled, true)
        XCTAssertEqual(survivor.speedOverride, 1.5)
        XCTAssertTrue(survivor.inboxIncluded)
        XCTAssertEqual(survivor.title, "New catalog metadata")
    }

    func testExactCatalogIdentityCannotMaskLegacyFollowedDuplicateBeforeRepair() throws {
        let context = TestStore.freshContext()
        let catalog = Podcast(
            feedURL: "https://identity.example/feed",
            title: "Exact catalog",
            subscriptionStateRaw: PodcastSubscriptionState.catalogOnly.rawValue
        )
        let followed = Podcast(
            feedURL: "HTTPS://IDENTITY.EXAMPLE:443/feed#legacy",
            title: "Legacy followed"
        )
        context.insert(catalog)
        context.insert(followed)
        try context.save()

        let identity = PodcastIdentityService(context: context)
        XCTAssertEqual(
            try identity.existingAnyState(feedURL: catalog.feedURL)?.persistentModelID,
            followed.persistentModelID
        )
        XCTAssertEqual(
            try identity.existingFollowed(feedURL: catalog.feedURL)?.persistentModelID,
            followed.persistentModelID
        )
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Podcast>()), 2)
    }
}
