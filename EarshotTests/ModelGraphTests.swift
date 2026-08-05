import XCTest
import SwiftData
@testable import Earshot

@MainActor
final class ModelGraphTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        TestStore.freshContext()
    }

    func testInsertAndFetchPodcastWithEpisodes() throws {
        let context = try makeContext()
        let podcast = Podcast(feedURL: "https://example.com/feed.xml", title: "Show")
        context.insert(podcast)
        let ep = Episode(guid: "g1", title: "Ep 1", audioURL: "https://example.com/1.mp3")
        ep.podcast = podcast
        context.insert(ep)
        try context.save()

        let podcasts = try context.fetch(FetchDescriptor<Podcast>())
        XCTAssertEqual(podcasts.count, 1)
        XCTAssertEqual(podcasts[0].episodes?.count, 1)
        XCTAssertEqual(podcasts[0].episodes?.first?.title, "Ep 1")
        XCTAssertEqual(podcasts[0].episodes?.first?.podcast?.title, "Show")
    }

    func testDeletingPodcastCascadesToEpisodes() throws {
        let context = try makeContext()
        let podcast = Podcast(feedURL: "https://example.com/feed.xml", title: "Show")
        context.insert(podcast)
        let ep = Episode(guid: "g1", title: "Ep 1", audioURL: "https://example.com/1.mp3")
        ep.podcast = podcast
        context.insert(ep)
        try context.save()

        context.delete(podcast)
        try context.save()

        XCTAssertEqual(try context.fetch(FetchDescriptor<Podcast>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Episode>()).count, 0)
    }

    func testDeletingEpisodeCascadesToQueueItemAndBookmark() throws {
        let context = try makeContext()
        let ep = Episode(guid: "g1", title: "Ep 1", audioURL: "https://example.com/1.mp3")
        context.insert(ep)
        let q = QueueItem(episode: ep, position: 0)
        context.insert(q)
        let b = Bookmark(episode: ep, positionSeconds: 42, note: "here")
        context.insert(b)
        try context.save()

        XCTAssertEqual(try context.fetch(FetchDescriptor<QueueItem>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Bookmark>()).count, 1)

        context.delete(ep)
        try context.save()

        XCTAssertEqual(try context.fetch(FetchDescriptor<QueueItem>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Bookmark>()).count, 0)
    }

    func testEnumsPersistAndReload() throws {
        let context = try makeContext()
        let ep = Episode(
            guid: "g1",
            title: "Ep 1",
            audioURL: "https://example.com/1.mp3",
            status: .inQueue,
            downloadStatus: .downloaded
        )
        context.insert(ep)
        try context.save()

        let reloaded = try XCTUnwrap(try context.fetch(FetchDescriptor<Episode>()).first)
        XCTAssertEqual(reloaded.status, .inQueue)
        XCTAssertEqual(reloaded.downloadStatus, .downloaded)
    }

    func testIsPlayedComputedSetterUpdatesStatusAndPlayedAt() throws {
        let ep = Episode(guid: "g1", title: "Ep 1", audioURL: "https://example.com/1.mp3")
        XCTAssertFalse(ep.isPlayed)
        XCTAssertNil(ep.playedAt)

        ep.isPlayed = true
        XCTAssertEqual(ep.status, .played)
        XCTAssertNotNil(ep.playedAt)

        ep.isPlayed = false
        XCTAssertEqual(ep.status, .newEpisode)
        XCTAssertNil(ep.playedAt)
    }

    func testFolderMembershipCascadesOnFolderDelete() throws {
        let context = try makeContext()
        let folder = PodcastFolder(name: "News")
        context.insert(folder)
        let podcast = Podcast(feedURL: "https://example.com/feed.xml", title: "Show")
        context.insert(podcast)
        let membership = FolderMembership(folder: folder, podcast: podcast, sortOrder: 0)
        context.insert(membership)
        try context.save()

        context.delete(folder)
        try context.save()

        XCTAssertEqual(try context.fetch(FetchDescriptor<FolderMembership>()).count, 0)
        // The podcast itself survives — only the membership cascades.
        XCTAssertEqual(try context.fetch(FetchDescriptor<Podcast>()).count, 1)
    }
}
