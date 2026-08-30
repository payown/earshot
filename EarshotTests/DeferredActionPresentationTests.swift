import SwiftData
import XCTest
@testable import Earshot

@MainActor
final class DeferredActionPresentationTests: XCTestCase {
    func testEpisodePresentationsRemainValueSnapshotsAfterModelDeletion() throws {
        let context = TestStore.freshContext()
        let episode = Episode(
            guid: "episode",
            title: "Episode",
            audioURL: "https://example.com/episode.mp3",
            status: .newEpisode,
            downloadStatus: .downloaded
        )
        context.insert(episode)
        try context.save()

        let presentations = EpisodeAction.presentations(
            [.download, .markPlayed, .unfollow],
            for: episode
        )

        context.delete(episode)
        try context.save()

        XCTAssertEqual(presentations.map(\.action), [.download, .markPlayed, .unfollow])
        XCTAssertEqual(
            presentations.map(\.label),
            ["Remove download", "Mark as played", "Unfollow this podcast"]
        )
        XCTAssertEqual(presentations.map(\.isDestructive), [true, false, true])
    }

    func testQueuePresentationsPreserveDynamicLabelsRolesAndOrder() throws {
        let context = TestStore.freshContext()
        let episode = Episode(
            guid: "episode",
            title: "Episode",
            audioURL: "https://example.com/episode.mp3",
            downloadStatus: .downloaded
        )
        context.insert(episode)
        try context.save()

        let presentations = QueueItemAction.presentations(
            [.playNow, .download, .removeFromQueue],
            for: episode
        )

        episode.downloadStatus = .none

        XCTAssertEqual(presentations.map(\.action), [.playNow, .download, .removeFromQueue])
        XCTAssertEqual(presentations.map(\.label), ["Play now", "Remove download", "Remove from queue"])
        XCTAssertEqual(presentations.map(\.isDestructive), [false, true, true])
    }

    func testPodcastPresentationsRemainValueSnapshotsAfterModelDeletion() throws {
        let context = TestStore.freshContext()
        let podcast = Podcast(
            feedURL: "https://example.com/feed",
            title: "Show",
            autoQueue: true,
            notificationEnabled: true
        )
        context.insert(podcast)
        try context.save()

        let presentations = PodcastAction.presentations(
            [.toggleNotifications, .toggleAutoQueue, .unsubscribe],
            for: podcast
        )

        context.delete(podcast)
        try context.save()

        XCTAssertEqual(
            presentations.map(\.label),
            ["Turn off new episode notifications", "Turn off auto-queue", "Unfollow"]
        )
        XCTAssertEqual(presentations.map(\.isDestructive), [false, false, true])
    }

    func testPersistedIdentityCheckRejectsDetachedEpisodeAfterSavedDeletion() throws {
        let context = TestStore.freshContext()
        let episode = Episode(
            guid: "episode",
            title: "Episode",
            audioURL: "https://example.com/episode.mp3"
        )
        context.insert(episode)
        try context.save()
        let episodeID = episode.persistentModelID

        XCTAssertTrue(PersistentModelLifetime.episodeExists(episodeID, in: context))

        context.delete(episode)
        try context.save()

        XCTAssertFalse(PersistentModelLifetime.episodeExists(episodeID, in: context))
    }
}
