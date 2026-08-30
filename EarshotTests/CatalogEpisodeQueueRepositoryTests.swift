import SwiftData
import XCTest
@testable import Earshot

@MainActor
final class CatalogEpisodeQueueRepositoryTests: XCTestCase {
    private enum SaveFailure: Error { case injected }

    private func preview(
        feedURL: String = "https://EXAMPLE.com:443/show.xml#directory",
        show: String = "Directory Show",
        guid: String = "episode-1",
        title: String = "Episode One",
        audioURL: String = "https://cdn.example.com/one.mp3"
    ) -> PreviewEpisode {
        PreviewEpisode(
            podcastFeedURL: feedURL,
            podcastTitle: show,
            podcastArtworkURL: "https://example.com/show.jpg",
            id: guid,
            title: title,
            pubDate: Date(timeIntervalSince1970: 1_700_000_000),
            durationSeconds: 3_601,
            audioURL: audioURL,
            episodeDescription: "<p>Complete notes</p>",
            searchableDescription: "Complete notes",
            artworkURL: "https://example.com/episode.jpg",
            episodeNumber: 9,
            seasonNumber: 2,
            chapterURL: "https://example.com/chapters.json",
            transcriptURL: "https://example.com/transcript.vtt"
        )
    }

    private func freshAssertionContext() -> ModelContext {
        let context = ModelContext(TestStore.container)
        context.autosaveEnabled = false
        return context
    }

    private func queueGUIDs(in context: ModelContext) -> [String] {
        QueueRepository(context: context).queue().map(\.guid)
    }

    private func notificationCounter(
        center: NotificationCenter
    ) -> (token: NSObjectProtocol, count: () -> Int) {
        var count = 0
        let token = center.addObserver(
            forName: .earshotQueueDidChange,
            object: nil,
            queue: nil
        ) { _ in
            MainActor.assumeIsolated { count += 1 }
        }
        return (token, { count })
    }

    private func seedLocalDownload(
        status: DownloadStatus,
        fileName: String
    ) throws -> URL {
        let context = freshAssertionContext()
        let episode = try XCTUnwrap(context.fetch(FetchDescriptor<Episode>()).first)
        AppSettingsStore(context: context).setBool(
            true,
            for: SettingsKey.deleteDownloadAfterPlayed
        )
        let fileURL = try DownloadPaths.downloadsDirectory().appendingPathComponent(fileName)
        try Data("audio".utf8).write(to: fileURL)
        LocalStateStore.setDownloadPath(fileName, on: episode, in: context)
        LocalStateStore.setDownloadStatus(status, on: episode, in: context)
        try context.save()
        return fileURL
    }

    func testAddMaterializesCompleteLocalCatalogGraphAndQueueSurfaces() async throws {
        _ = TestStore.freshContext()
        let center = NotificationCenter.default
        let observed = notificationCounter(center: center)
        defer { center.removeObserver(observed.token) }
        let repository = CatalogEpisodeQueueRepository(container: TestStore.container)

        let result = await repository.add(preview())

        XCTAssertEqual(result, .success(.added))
        XCTAssertEqual(observed.count(), 1)
        let context = freshAssertionContext()
        let podcasts = try context.fetch(FetchDescriptor<Podcast>())
        let episodes = try context.fetch(FetchDescriptor<Episode>())
        XCTAssertEqual(podcasts.count, 1)
        XCTAssertTrue(podcasts[0].isCatalogOnly)
        XCTAssertEqual(podcasts[0].feedURL, "https://example.com/show.xml")
        XCTAssertEqual(podcasts[0].title, "Directory Show")
        XCTAssertEqual(podcasts[0].artworkURL, "https://example.com/show.jpg")
        XCTAssertEqual(episodes.count, 1)
        let episode = try XCTUnwrap(episodes.first)
        XCTAssertEqual(episode.guid, "episode-1")
        XCTAssertEqual(episode.title, "Episode One")
        XCTAssertEqual(episode.audioURL, "https://cdn.example.com/one.mp3")
        XCTAssertEqual(episode.episodeDescription, "<p>Complete notes</p>")
        XCTAssertEqual(episode.durationSeconds, 3_601)
        XCTAssertEqual(episode.artworkURL, "https://example.com/episode.jpg")
        XCTAssertEqual(episode.episodeNumber, 9)
        XCTAssertEqual(episode.seasonNumber, 2)
        XCTAssertEqual(episode.chapterURL, "https://example.com/chapters.json")
        XCTAssertEqual(episode.transcriptURL, "https://example.com/transcript.vtt")
        XCTAssertEqual(episode.status, .inQueue)
        XCTAssertTrue(episode.inboxDismissed)

        let queue = QueueRepository(context: context)
        XCTAssertEqual(queue.queue().map(\.guid), ["episode-1"])
        XCTAssertEqual(queue.groupedQueue().map(\.title), ["Directory Show"])
        XCTAssertEqual(queue.groupedQueueByFolder().groups.map(\.kind), [.unfiled])
        XCTAssertEqual(QueueLineupStore(context: context).save(queue.queue()).savedCount, 1)

        let player = PlayerService()
        player.configure(context: context)
        player.load(episode)
        XCTAssertEqual(player.currentTitle, "Episode One")
        XCTAssertEqual(player.currentArtist, "Directory Show")
        XCTAssertEqual(player.durationSeconds, 3_601)
    }

    func testRepeatedAddIsNoOpWithoutSecondQueueNotificationAndRefreshesMetadata() async throws {
        _ = TestStore.freshContext()
        let center = NotificationCenter()
        let observed = notificationCounter(center: center)
        defer { center.removeObserver(observed.token) }
        let repository = CatalogEpisodeQueueRepository(
            container: TestStore.container,
            notificationCenter: center
        )

        let firstResult = await repository.add(preview())
        XCTAssertEqual(firstResult, .success(.added))
        let refreshed = preview(title: "Publisher Correction")
        let secondResult = await repository.add(refreshed)
        XCTAssertEqual(secondResult, .success(.alreadyQueued))

        XCTAssertEqual(observed.count(), 1, "metadata-only retry is not a queue change")
        let context = freshAssertionContext()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Podcast>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Episode>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<QueueItem>()), 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Episode>()).first?.title, "Publisher Correction")
    }

    func testAddPreservesExistingUserStateAndNeverDemotesFollowedPodcast() async throws {
        let seed = TestStore.freshContext()
        let podcast = Podcast(
            feedURL: "https://example.com/show.xml",
            title: "Followed Title",
            subscriptionStateRaw: nil
        )
        let episode = Episode(
            guid: "episode-1",
            title: "Old title",
            audioURL: "https://old.example.com/audio.mp3",
            positionSeconds: 812,
            playedAt: Date(timeIntervalSince1970: 1_600_000_000),
            inboxDismissed: false
        )
        episode.podcast = podcast
        seed.insert(podcast)
        seed.insert(episode)
        seed.insert(Bookmark(episode: episode, positionSeconds: 400, note: "Keep"))
        seed.insert(LocalEpisodeState(
            podcastFeedURL: podcast.feedURL,
            episodeGUID: episode.guid,
            downloadStatus: .downloaded,
            downloadPath: "keep.mp3",
            volumeBoost: .high
        ))
        try seed.save()

        let result = await CatalogEpisodeQueueRepository(
            container: TestStore.container
        ).add(preview(show: "Directory Must Not Win", title: "Fresh episode title"))

        XCTAssertEqual(result, .success(.added))
        let context = freshAssertionContext()
        let storedPodcast = try XCTUnwrap(context.fetch(FetchDescriptor<Podcast>()).first)
        let storedEpisode = try XCTUnwrap(context.fetch(FetchDescriptor<Episode>()).first)
        XCTAssertTrue(storedPodcast.isFollowed)
        XCTAssertEqual(storedPodcast.title, "Followed Title")
        XCTAssertEqual(storedEpisode.title, "Fresh episode title")
        XCTAssertEqual(storedEpisode.positionSeconds, 812)
        XCTAssertEqual(storedEpisode.playedAt, Date(timeIntervalSince1970: 1_600_000_000))
        XCTAssertFalse(storedEpisode.inboxDismissed)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Bookmark>()), 1)
        let local = try XCTUnwrap(context.fetch(FetchDescriptor<LocalEpisodeState>()).first)
        XCTAssertEqual(local.downloadStatus, .downloaded)
        XCTAssertEqual(local.downloadPath, "keep.mp3")
        XCTAssertEqual(local.volumeBoost, .high)
    }

    func testAddReusesQueuedEpisodeAcrossCanonicalEquivalentPodcastDuplicates() async throws {
        let seed = TestStore.freshContext()
        let center = NotificationCenter()
        let observed = notificationCounter(center: center)
        defer { center.removeObserver(observed.token) }
        let followed = Podcast(
            feedURL: "HTTPS://EXAMPLE.COM:443/show.xml#legacy",
            title: "Followed",
            subscriptionStateRaw: nil
        )
        let catalog = Podcast(
            feedURL: "https://example.com/show.xml",
            title: "Catalog duplicate",
            subscriptionStateRaw: PodcastSubscriptionState.catalogOnly.rawValue
        )
        let queued = Episode(
            guid: "episode-1",
            title: "Existing queued",
            audioURL: "https://example.com/old.mp3"
        )
        queued.podcast = catalog
        queued.status = .inQueue
        seed.insert(followed)
        seed.insert(catalog)
        seed.insert(queued)
        seed.insert(QueueItem(episode: queued, position: 0))
        try seed.save()

        let result = await CatalogEpisodeQueueRepository(
            container: TestStore.container, notificationCenter: center
        ).add(preview())

        XCTAssertEqual(result, .success(.alreadyQueued))
        XCTAssertEqual(observed.count(), 1)
        let context = freshAssertionContext()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Podcast>()), 2, "repair is deferred")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Episode>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<QueueItem>()), 1)
        let episode = try XCTUnwrap(context.fetch(FetchDescriptor<Episode>()).first)
        XCTAssertEqual(episode.title, "Episode One")
        XCTAssertEqual(episode.podcast?.title, "Followed")
        XCTAssertTrue(episode.podcast?.isFollowed == true)
        XCTAssertNotNil(EpisodeUserStateSnapshot(episode: episode))
    }

    func testLegacyDuplicateSaveFailureNeverSendsFalsePreDeleteOrQueueNotification() async throws {
        let seed = TestStore.freshContext()
        let podcast = Podcast(feedURL: "https://example.com/show.xml", title: "Catalog")
        podcast.subscriptionStateRaw = PodcastSubscriptionState.catalogOnly.rawValue
        let older = Episode(
            guid: "episode-1", title: "Older", audioURL: "https://example.com/older.mp3",
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let newer = Episode(
            guid: "episode-1", title: "Newer", audioURL: "https://example.com/newer.mp3",
            createdAt: Date(timeIntervalSince1970: 2)
        )
        older.podcast = podcast
        newer.podcast = podcast
        older.status = .inQueue
        newer.status = .inQueue
        seed.insert(podcast)
        seed.insert(older)
        seed.insert(newer)
        seed.insert(QueueItem(episode: older, position: 0))
        seed.insert(QueueItem(episode: newer, position: 1))
        try seed.save()
        let player = PlayerService()
        player.configure(context: seed)
        player.load(newer)
        let loadedID = player.nowPlayingEpisodeID
        var willDeleteCount = 0
        let deleteToken = NotificationCenter.default.addObserver(
            forName: .earshotWillDeleteEpisodes, object: nil, queue: nil
        ) { _ in MainActor.assumeIsolated { willDeleteCount += 1 } }
        defer { NotificationCenter.default.removeObserver(deleteToken) }
        let center = NotificationCenter()
        let observed = notificationCounter(center: center)
        defer { center.removeObserver(observed.token) }
        let repository = CatalogEpisodeQueueRepository(
            container: TestStore.container,
            notificationCenter: center,
            saveOperation: { _ in throw SaveFailure.injected }
        )

        let result = await repository.add(preview())

        XCTAssertEqual(result, .failure(.persistenceFailed))
        XCTAssertEqual(willDeleteCount, 0)
        XCTAssertEqual(observed.count(), 0)
        XCTAssertEqual(player.nowPlayingEpisodeID, loadedID)
        let context = freshAssertionContext()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Episode>()), 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<QueueItem>()), 2)
    }

    func testPlayNextMovesAfterPersistedAnchorThenReturnsTruthfulNoOp() async throws {
        _ = TestStore.freshContext()
        let center = NotificationCenter()
        let observed = notificationCounter(center: center)
        defer { center.removeObserver(observed.token) }
        let repository = CatalogEpisodeQueueRepository(
            container: TestStore.container,
            notificationCenter: center
        )
        let first = preview(guid: "first", title: "First")
        let second = preview(guid: "second", title: "Second")
        let third = preview(guid: "third", title: "Third")
        _ = await repository.add(first)
        _ = await repository.add(second)
        _ = await repository.add(third)
        let anchor = CatalogEpisodeIdentity(feedURL: first.podcastFeedURL, guid: first.id)

        let moved = await repository.playNext(third, after: anchor)
        XCTAssertEqual(moved, .success(.movedNext))
        XCTAssertEqual(queueGUIDs(in: freshAssertionContext()), ["first", "third", "second"])
        let unchanged = await repository.playNext(third, after: anchor)
        XCTAssertEqual(unchanged, .success(.alreadyNext))
        XCTAssertEqual(observed.count(), 4, "three adds plus one real reorder; no-op stays silent")
    }

    func testPlayNextWithTransientAnchorMovesEpisodeToFront() async {
        _ = TestStore.freshContext()
        let repository = CatalogEpisodeQueueRepository(container: TestStore.container)
        let first = preview(guid: "first", title: "First")
        let second = preview(guid: "second", title: "Second")
        _ = await repository.add(first)
        _ = await repository.add(second)

        let transient = CatalogEpisodeIdentity(feedURL: "https://transient.example/feed", guid: "stream")
        let result = await repository.playNext(second, after: transient)
        XCTAssertEqual(result, .success(.movedNext))
        XCTAssertEqual(queueGUIDs(in: freshAssertionContext()), ["second", "first"])
    }

    func testRemoveRetainsGraphAndUserStateAndSecondRemoveIsNoOp() async throws {
        _ = TestStore.freshContext()
        let center = NotificationCenter.default
        let observed = notificationCounter(center: center)
        defer { center.removeObserver(observed.token) }
        let repository = CatalogEpisodeQueueRepository(container: TestStore.container)
        let value = preview()
        _ = await repository.add(value)
        let edit = freshAssertionContext()
        let episode = try XCTUnwrap(edit.fetch(FetchDescriptor<Episode>()).first)
        episode.positionSeconds = 99
        episode.playedAt = Date(timeIntervalSince1970: 1_500_000_000)
        edit.insert(Bookmark(episode: episode, positionSeconds: 44, note: "Keep"))
        try edit.save()
        let player = PlayerService()
        player.configure(context: edit)
        player.load(episode)
        let loadedID = player.nowPlayingEpisodeID
        var willDeleteCount = 0
        let deleteToken = NotificationCenter.default.addObserver(
            forName: .earshotWillDeleteEpisodes, object: nil, queue: nil
        ) { _ in MainActor.assumeIsolated { willDeleteCount += 1 } }
        defer { NotificationCenter.default.removeObserver(deleteToken) }
        let identity = CatalogEpisodeIdentity(feedURL: value.podcastFeedURL, guid: value.id)

        let removed = await repository.remove(identity)
        let unchanged = await repository.remove(identity)
        XCTAssertEqual(removed, .success(.removed))
        XCTAssertEqual(unchanged, .success(.alreadyRemoved))
        XCTAssertEqual(player.nowPlayingEpisodeID, loadedID)
        XCTAssertEqual(player.currentTitle, "Episode One")
        XCTAssertEqual(willDeleteCount, 0)

        XCTAssertEqual(observed.count(), 2, "add and first remove only")
        let context = freshAssertionContext()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Podcast>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Episode>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<QueueItem>()), 0)
        let retained = try XCTUnwrap(context.fetch(FetchDescriptor<Episode>()).first)
        XCTAssertEqual(retained.status, .newEpisode)
        XCTAssertTrue(retained.inboxDismissed)
        XCTAssertEqual(retained.positionSeconds, 99)
        XCTAssertEqual(retained.playedAt, Date(timeIntervalSince1970: 1_500_000_000))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Bookmark>()), 1)
    }

    func testRemoveDeletesCompletedDownloadOnlyAfterCommit() async throws {
        _ = TestStore.freshContext()
        let repository = CatalogEpisodeQueueRepository(container: TestStore.container)
        let value = preview(guid: "downloaded")
        _ = await repository.add(value)
        let fileURL = try seedLocalDownload(
            status: .downloaded,
            fileName: "catalog-complete-\(UUID().uuidString).mp3"
        )
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let result = await repository.remove(CatalogEpisodeIdentity(
            feedURL: value.podcastFeedURL,
            guid: value.id
        ))

        XCTAssertEqual(result, .success(.removed))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        let context = freshAssertionContext()
        let episode = try XCTUnwrap(context.fetch(FetchDescriptor<Episode>()).first)
        XCTAssertEqual(episode.downloadStatus, .none)
        XCTAssertNil(episode.downloadPath)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LocalEpisodeState>()), 0)
    }

    func testFailedRemoveSaveRetainsCompletedDownloadDatabaseRuntimeAndFile() async throws {
        _ = TestStore.freshContext()
        let value = preview(guid: "failed-download-cleanup")
        _ = await CatalogEpisodeQueueRepository(container: TestStore.container).add(value)
        let fileName = "catalog-failed-\(UUID().uuidString).mp3"
        let fileURL = try seedLocalDownload(status: .downloaded, fileName: fileName)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let failing = CatalogEpisodeQueueRepository(
            container: TestStore.container,
            saveOperation: { _ in throw SaveFailure.injected }
        )

        let result = await failing.remove(CatalogEpisodeIdentity(
            feedURL: value.podcastFeedURL,
            guid: value.id
        ))

        XCTAssertEqual(result, .failure(.persistenceFailed))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        let context = freshAssertionContext()
        let episode = try XCTUnwrap(context.fetch(FetchDescriptor<Episode>()).first)
        XCTAssertEqual(episode.downloadStatus, .downloaded)
        XCTAssertEqual(episode.downloadPath, fileName)
        XCTAssertEqual(episode.status, .inQueue)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<QueueItem>()), 1)
        let local = try XCTUnwrap(context.fetch(FetchDescriptor<LocalEpisodeState>()).first)
        XCTAssertEqual(local.downloadStatus, .downloaded)
        XCTAssertEqual(local.downloadPath, fileName)
    }

    func testFailedPostCommitCleanupFetchKeepsDownloadButQueueRemovalSucceeds() async throws {
        _ = TestStore.freshContext()
        let value = preview(guid: "cleanup-failure")
        _ = await CatalogEpisodeQueueRepository(container: TestStore.container).add(value)
        let fileName = "catalog-cleanup-failed-\(UUID().uuidString).mp3"
        let fileURL = try seedLocalDownload(status: .downloaded, fileName: fileName)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let repository = CatalogEpisodeQueueRepository(
            container: TestStore.container,
            cleanupRowsOperation: { _, _ in throw SaveFailure.injected }
        )

        let result = await repository.remove(CatalogEpisodeIdentity(
            feedURL: value.podcastFeedURL, guid: value.id
        ))

        XCTAssertEqual(result, .success(.removed))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        let context = freshAssertionContext()
        let episode = try XCTUnwrap(context.fetch(FetchDescriptor<Episode>()).first)
        let local = try XCTUnwrap(context.fetch(FetchDescriptor<LocalEpisodeState>()).first)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<QueueItem>()), 0)
        XCTAssertEqual(episode.downloadStatus, .downloaded)
        XCTAssertEqual(episode.downloadPath, fileName)
        XCTAssertEqual(local.downloadStatus, .downloaded)
        XCTAssertEqual(local.downloadPath, fileName)
    }

    func testRemovePreservesInFlightDownloadStatusPathAndFile() async throws {
        _ = TestStore.freshContext()
        let repository = CatalogEpisodeQueueRepository(container: TestStore.container)
        let value = preview(guid: "downloading")
        _ = await repository.add(value)
        let fileName = "catalog-inflight-\(UUID().uuidString).mp3"
        let fileURL = try seedLocalDownload(status: .downloading, fileName: fileName)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let result = await repository.remove(CatalogEpisodeIdentity(
            feedURL: value.podcastFeedURL,
            guid: value.id
        ))

        XCTAssertEqual(result, .success(.removed))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        let context = freshAssertionContext()
        let episode = try XCTUnwrap(context.fetch(FetchDescriptor<Episode>()).first)
        XCTAssertEqual(episode.downloadStatus, .downloading)
        XCTAssertEqual(episode.downloadPath, fileName)
        let local = try XCTUnwrap(context.fetch(FetchDescriptor<LocalEpisodeState>()).first)
        XCTAssertEqual(local.downloadStatus, .downloading)
        XCTAssertEqual(local.downloadPath, fileName)
    }

    func testAbsentRemoveCleansOrphanQueueRowsWithoutMaterializingContent() async throws {
        let seed = TestStore.freshContext()
        seed.insert(QueueItem(position: 42))
        try seed.save()
        let center = NotificationCenter()
        let observed = notificationCounter(center: center)
        defer { center.removeObserver(observed.token) }
        let repository = CatalogEpisodeQueueRepository(
            container: TestStore.container,
            notificationCenter: center
        )

        let result = await repository.remove(CatalogEpisodeIdentity(
            feedURL: "https://example.com/missing.xml",
            guid: "missing"
        ))

        XCTAssertEqual(result, .success(.alreadyRemoved))
        XCTAssertEqual(observed.count(), 1, "orphan cleanup is a durable queue change")
        let context = freshAssertionContext()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<QueueItem>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Podcast>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Episode>()), 0)
    }

    func testSaveFailureRollsBackWholeGraphFromIndependentContextThenRetrySucceeds() async throws {
        _ = TestStore.freshContext()
        let center = NotificationCenter()
        let observed = notificationCounter(center: center)
        defer { center.removeObserver(observed.token) }
        var attemptedSaves = 0
        let failing = CatalogEpisodeQueueRepository(
            container: TestStore.container,
            notificationCenter: center,
            saveOperation: { _ in
                attemptedSaves += 1
                throw SaveFailure.injected
            }
        )

        let failed = await failing.add(preview())
        XCTAssertEqual(failed, .failure(.persistenceFailed))
        XCTAssertEqual(attemptedSaves, 1, "failure occurs at the staged save boundary")
        XCTAssertEqual(observed.count(), 0)
        let afterFailure = freshAssertionContext()
        XCTAssertEqual(try afterFailure.fetchCount(FetchDescriptor<Podcast>()), 0)
        XCTAssertEqual(try afterFailure.fetchCount(FetchDescriptor<Episode>()), 0)
        XCTAssertEqual(try afterFailure.fetchCount(FetchDescriptor<QueueItem>()), 0)

        let retry = CatalogEpisodeQueueRepository(
            container: TestStore.container,
            notificationCenter: center
        )
        let retried = await retry.add(preview())
        XCTAssertEqual(retried, .success(.added))
        XCTAssertEqual(observed.count(), 1)
        let afterRetry = freshAssertionContext()
        XCTAssertEqual(try afterRetry.fetchCount(FetchDescriptor<Podcast>()), 1)
        XCTAssertEqual(try afterRetry.fetchCount(FetchDescriptor<Episode>()), 1)
        XCTAssertEqual(try afterRetry.fetchCount(FetchDescriptor<QueueItem>()), 1)
    }

    func testConcurrentSameFeedAddsRemainOneGraph() async throws {
        _ = TestStore.freshContext()
        let repository = CatalogEpisodeQueueRepository(container: TestStore.container)
        let value = preview()

        async let first = repository.add(value)
        async let second = repository.add(value)
        let results = await [first, second]

        XCTAssertEqual(results.filter { $0 == .success(.added) }.count, 1)
        XCTAssertEqual(results.filter { $0 == .success(.alreadyQueued) }.count, 1)
        let context = freshAssertionContext()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Podcast>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Episode>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<QueueItem>()), 1)
    }

    func testCancelledWaiterReleasesFeedGateWithoutMutation() async throws {
        _ = TestStore.freshContext()
        let value = preview()
        let canonical = FeedURLIdentity.canonical(value.podcastFeedURL)
        await PodcastIdentityWriteGate.shared.acquire(feedURLs: [canonical])
        let repository = CatalogEpisodeQueueRepository(container: TestStore.container)
        let task = Task { await repository.add(value) }
        await Task.yield()
        task.cancel()
        await PodcastIdentityWriteGate.shared.release(feedURLs: [canonical])

        let cancelled = await task.value
        XCTAssertEqual(cancelled, .failure(.cancelled))
        let context = freshAssertionContext()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Podcast>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Episode>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<QueueItem>()), 0)

        let retry = await repository.add(value)
        XCTAssertEqual(retry, .success(.added), "cancelled waiter released the feed identity key")
    }

    func testConcurrentDifferentFeedAddsKeepDenseQueueAndEqualGUIDsDistinct() async throws {
        _ = TestStore.freshContext()
        let repository = CatalogEpisodeQueueRepository(container: TestStore.container)
        let firstValue = preview(feedURL: "https://one.example/feed", show: "One", guid: "shared")
        let secondValue = preview(feedURL: "https://two.example/feed", show: "Two", guid: "shared")

        async let first = repository.add(firstValue)
        async let second = repository.add(secondValue)
        let results = await [first, second]
        XCTAssertEqual(results, [.success(.added), .success(.added)])

        let context = freshAssertionContext()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Podcast>()), 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Episode>()), 2)
        let items = try context.fetch(
            FetchDescriptor<QueueItem>(sortBy: [SortDescriptor(\.position)])
        )
        XCTAssertEqual(items.map(\.position), [0, 1])
        XCTAssertEqual(Set(items.compactMap { $0.episode?.podcast?.title }), Set(["One", "Two"]))
    }

    func testInvalidMaterializationInputsNeverWriteOrNotify() async throws {
        _ = TestStore.freshContext()
        let center = NotificationCenter()
        let observed = notificationCounter(center: center)
        defer { center.removeObserver(observed.token) }
        let repository = CatalogEpisodeQueueRepository(
            container: TestStore.container,
            notificationCenter: center
        )

        let invalidFeed = await repository.add(preview(feedURL: "  "))
        let missingTitle = await repository.add(preview(show: " \n "))
        let missingGUID = await repository.add(preview(guid: " \n "))
        let missingAudio = await repository.add(preview(audioURL: " \n "))
        XCTAssertEqual(invalidFeed, .failure(.invalidFeedURL))
        XCTAssertEqual(missingTitle, .failure(.missingPodcastTitle))
        XCTAssertEqual(missingGUID, .failure(.missingGUID))
        XCTAssertEqual(missingAudio, .failure(.missingAudioURL))
        XCTAssertEqual(observed.count(), 0)
        let context = freshAssertionContext()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Podcast>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Episode>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<QueueItem>()), 0)
    }
}
