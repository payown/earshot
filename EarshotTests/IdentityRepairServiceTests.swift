import SwiftData
import XCTest
@testable import Earshot

@MainActor
final class IdentityRepairServiceTests: XCTestCase {
    func testOrdinaryHydrationProjectsOrphanPodcastStateWithoutRepair() throws {
        let container = try ModelContainerFactory.makeInMemory()
        let context = container.mainContext
        let refreshedAt = Date(timeIntervalSince1970: 1_800_000_000)
        context.insert(LocalPodcastState(
            feedURL: "https://orphan.example/feed", refreshedAt: refreshedAt
        ))
        context.insert(LocalPodcastState(
            feedURL: "https://orphan.example/feed", refreshedAt: .distantPast
        ))
        try context.save()

        try LocalStateStore.hydrate(in: context, repairing: false)

        let projected = try XCTUnwrap(
            LocalRuntimeState.shared.refreshedAt(feedURL: "https://orphan.example/feed")
        )
        XCTAssertTrue(
            [refreshedAt, Date.distantPast].contains(projected)
        )
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LocalPodcastState>()), 2)
    }

    private let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
    private let newDate = Date(timeIntervalSince1970: 1_800_000_000)

    func testFeedURLCanonicalizationIsStableAndConservative() {
        XCTAssertEqual(
            FeedURLIdentity.canonical("  HTTPS://Example.COM:443/feed.xml#section  "),
            "https://example.com/feed.xml"
        )
        XCTAssertEqual(
            FeedURLIdentity.canonical("http://Example.COM:80/Feed?Token=AbC"),
            "http://example.com/Feed?Token=AbC"
        )
        XCTAssertEqual(
            FeedURLIdentity.canonical("not a URL"),
            "not a URL"
        )
        XCTAssertEqual(
            FeedURLIdentity.canonical(FeedURLIdentity.canonical("HTTPS://Example.COM/feed")),
            "https://example.com/feed"
        )
        XCTAssertTrue(
            FeedURLIdentity.matches(
                "HTTPS://Example.COM:443/feed#directory",
                "https://example.com/feed"
            )
        )
        XCTAssertFalse(
            FeedURLIdentity.matches(
                "https://example.com/Feed",
                "https://example.com/feed"
            )
        )
    }

    func testRepairMergesDuplicatePodcastAndEpisodeWithoutLosingUserGraph() throws {
        let context = TestStore.freshContext()
        let oldPodcast = Podcast(
            feedURL: "HTTPS://Example.COM:443/feed.xml#first",
            title: "Old metadata",
            autoQueue: false,
            speedOverride: 1.25,
            inboxIncluded: true,
            createdAt: oldDate,
            refreshedAt: oldDate,
            lastSeenPubDate: oldDate
        )
        let newPodcast = Podcast(
            feedURL: "https://example.com/feed.xml",
            title: "Fresh metadata",
            author: "Current author",
            autoQueue: true,
            notificationEnabled: true,
            speedOverride: 1.5,
            introSkipSeconds: 30,
            inboxMaxEpisodes: 5,
            inboxExcluded: true,
            createdAt: newDate,
            refreshedAt: newDate,
            lastSeenPubDate: newDate
        )
        context.insert(oldPodcast)
        context.insert(newPodcast)

        let downloaded = Episode(
            guid: "shared-guid",
            title: "Old episode metadata",
            audioURL: "https://example.com/old.mp3",
            downloadStatus: .downloaded,
            downloadPath: "kept-download.mp3",
            positionSeconds: 120,
            inboxDismissed: true,
            createdAt: oldDate
        )
        downloaded.podcast = oldPodcast
        let played = Episode(
            guid: "shared-guid",
            title: "Fresh episode metadata",
            audioURL: "https://example.com/new.mp3",
            pubDate: newDate,
            status: .played,
            positionSeconds: 240,
            playedAt: newDate,
            createdAt: newDate
        )
        played.podcast = newPodcast
        let unique = Episode(
            guid: "unique-guid",
            title: "Unique episode",
            audioURL: "https://example.com/unique.mp3",
            createdAt: newDate
        )
        unique.podcast = newPodcast
        context.insert(downloaded)
        context.insert(played)
        context.insert(unique)

        let oldQueue = QueueItem(episode: downloaded, position: 4, addedAt: oldDate)
        let newQueue = QueueItem(episode: played, position: 2, addedAt: newDate)
        context.insert(oldQueue)
        context.insert(newQueue)
        context.insert(Bookmark(episode: downloaded, positionSeconds: 30, note: "old", createdAt: oldDate))
        context.insert(Bookmark(episode: played, positionSeconds: 60, note: "new", createdAt: newDate))
        context.insert(ListeningSession(episode: downloaded, podcast: oldPodcast, durationSeconds: 30, date: oldDate))
        context.insert(ListeningSession(episode: played, podcast: newPodcast, durationSeconds: 60, date: newDate))

        let folder = PodcastFolder(name: "Favorites")
        context.insert(folder)
        context.insert(FolderMembership(folder: folder, podcast: oldPodcast, sortOrder: 3))
        context.insert(FolderMembership(folder: folder, podcast: newPodcast, sortOrder: 1))
        context.insert(EpisodeFolderMembership(folder: folder, episode: downloaded, sortOrder: 4))
        context.insert(EpisodeFolderMembership(folder: folder, episode: played, sortOrder: 2))

        context.insert(RecentlyExpired(episode: played, expiredAt: newDate))
        ActiveDownload.setDownloadStatus(.pending, on: played, in: context)

        let first = try IdentityRepairService(context: context).repairAll()
        try context.save()

        let podcasts = try context.fetch(FetchDescriptor<Podcast>())
        XCTAssertEqual(podcasts.count, 1)
        let podcast = try XCTUnwrap(podcasts.first)
        XCTAssertEqual(podcast.feedURL, "https://example.com/feed.xml")
        XCTAssertEqual(podcast.title, "Fresh metadata")
        XCTAssertEqual(podcast.author, "Current author")
        XCTAssertTrue(podcast.autoQueue)
        XCTAssertEqual(podcast.notificationEnabled, true)
        XCTAssertEqual(podcast.speedOverride, 1.5)
        XCTAssertEqual(podcast.introSkipSeconds, 30)
        XCTAssertEqual(podcast.inboxMaxEpisodes, 5)
        XCTAssertTrue(podcast.inboxExcluded)
        XCTAssertFalse(podcast.inboxIncluded, "The newest explicit inbox scope wins")
        XCTAssertEqual(podcast.createdAt, oldDate, "Stable subscription age survives")
        XCTAssertEqual(podcast.refreshedAt, newDate)
        XCTAssertEqual(podcast.lastSeenPubDate, newDate)

        let episodes = try context.fetch(FetchDescriptor<Episode>())
        XCTAssertEqual(episodes.count, 2)
        let merged = try XCTUnwrap(episodes.first { $0.guid == "shared-guid" })
        XCTAssertEqual(merged.podcast?.persistentModelID, podcast.persistentModelID)
        XCTAssertEqual(merged.title, "Fresh episode metadata")
        XCTAssertEqual(merged.audioURL, "https://example.com/new.mp3")
        XCTAssertEqual(merged.status, .inQueue, "A retained queue relationship is authoritative")
        XCTAssertEqual(merged.positionSeconds, 240)
        XCTAssertEqual(merged.playedAt, newDate)
        XCTAssertTrue(merged.inboxDismissed)
        XCTAssertEqual(merged.downloadStatus, .downloaded)
        XCTAssertEqual(merged.downloadPath, "kept-download.mp3")

        let bookmarks = try context.fetch(FetchDescriptor<Bookmark>())
        XCTAssertEqual(bookmarks.count, 2)
        XCTAssertTrue(bookmarks.allSatisfy { $0.episode?.persistentModelID == merged.persistentModelID })
        let sessions = try context.fetch(FetchDescriptor<ListeningSession>())
        XCTAssertEqual(sessions.count, 2)
        XCTAssertTrue(sessions.allSatisfy { $0.episode?.persistentModelID == merged.persistentModelID })
        XCTAssertTrue(sessions.allSatisfy { $0.podcast?.persistentModelID == podcast.persistentModelID })

        let queue = try context.fetch(FetchDescriptor<QueueItem>())
        XCTAssertEqual(queue.count, 1)
        XCTAssertEqual(queue.first?.episode?.persistentModelID, merged.persistentModelID)
        XCTAssertEqual(queue.first?.position, 2)
        XCTAssertEqual(queue.first?.addedAt, newDate)
        let podcastMemberships = try context.fetch(FetchDescriptor<FolderMembership>())
        XCTAssertEqual(podcastMemberships.count, 1)
        XCTAssertEqual(podcastMemberships.first?.podcast?.persistentModelID, podcast.persistentModelID)
        XCTAssertEqual(podcastMemberships.first?.sortOrder, 1)
        let episodeMemberships = try context.fetch(FetchDescriptor<EpisodeFolderMembership>())
        XCTAssertEqual(episodeMemberships.count, 1)
        XCTAssertEqual(episodeMemberships.first?.episode?.persistentModelID, merged.persistentModelID)
        XCTAssertEqual(episodeMemberships.first?.sortOrder, 2)
        XCTAssertEqual(try context.fetch(FetchDescriptor<RecentlyExpired>()).first?.episode?.persistentModelID, merged.persistentModelID)
        XCTAssertEqual(try context.fetch(FetchDescriptor<LocalEpisodeState>()).count, 1)

        XCTAssertEqual(first.podcastsRemoved, 1)
        XCTAssertEqual(first.episodesRemoved, 1)

        let second = try IdentityRepairService(context: context).repairAll()
        XCTAssertFalse(second.didChange, "A completed repair must be idempotent")
        XCTAssertEqual(second.podcastsRemoved, 0)
        XCTAssertEqual(second.episodesRemoved, 0)
    }

    func testSameGUIDInDifferentPodcastsIsNeverMerged() throws {
        let context = TestStore.freshContext()
        let firstPodcast = Podcast(feedURL: "https://example.com/one", title: "One")
        let secondPodcast = Podcast(feedURL: "https://example.com/two", title: "Two")
        context.insert(firstPodcast)
        context.insert(secondPodcast)
        let first = Episode(guid: "shared", title: "One", audioURL: "https://example.com/one.mp3")
        first.podcast = firstPodcast
        let second = Episode(guid: "shared", title: "Two", audioURL: "https://example.com/two.mp3")
        second.podcast = secondPodcast
        context.insert(first)
        context.insert(second)

        let report = try IdentityRepairService(context: context).repairAll()
        try context.save()

        XCTAssertEqual(report.episodesRemoved, 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Episode>()), 2)
    }

    func testLocalStateRepairPrefersExistingDownloadAndClearsMissingPath() throws {
        let existingName = "repair-existing-\(UUID()).mp3"
        let missingName = "repair-missing-\(UUID()).mp3"
        let existingURL = try DownloadPaths.downloadsDirectory()
            .appendingPathComponent(existingName)
        try Data("audio".utf8).write(to: existingURL)
        defer { try? FileManager.default.removeItem(at: existingURL) }

        let context = TestStore.freshContext()
        context.insert(LocalEpisodeState(
            podcastFeedURL: "https://example.com/feed", episodeGUID: "existing",
            downloadStatus: .downloaded, downloadPath: missingName
        ))
        context.insert(LocalEpisodeState(
            podcastFeedURL: "https://example.com/feed", episodeGUID: "existing",
            downloadStatus: .downloaded, downloadPath: existingName
        ))
        context.insert(LocalEpisodeState(
            podcastFeedURL: "https://example.com/feed", episodeGUID: "missing",
            downloadStatus: .downloaded, downloadPath: missingName
        ))
        try context.save()

        try LocalStateStore.repair(in: context)
        try context.save()

        let rows = try context.fetch(FetchDescriptor<LocalEpisodeState>())
        let existing = try XCTUnwrap(rows.first { $0.episodeGUID == "existing" })
        XCTAssertEqual(rows.filter { $0.episodeGUID == "existing" }.count, 1)
        XCTAssertEqual(existing.downloadStatus, .downloaded)
        XCTAssertEqual(existing.downloadPath, existingName)

        let missing = try XCTUnwrap(rows.first { $0.episodeGUID == "missing" })
        XCTAssertEqual(missing.downloadStatus, DownloadStatus.none)
        XCTAssertNil(missing.downloadPath)
    }

    func testLaunchRepairDoesNotInspectEpisodesForUniquePodcastGroups() throws {
        let context = TestStore.freshContext()
        for index in 0..<50 {
            let podcast = Podcast(feedURL: "https://example.com/\(index)", title: "Show \(index)")
            context.insert(podcast)
            for episodeIndex in 0..<20 {
                let episode = Episode(
                    guid: "\(index)-\(episodeIndex)",
                    title: "Episode",
                    audioURL: "https://example.com/\(index)-\(episodeIndex).mp3"
                )
                episode.podcast = podcast
                context.insert(episode)
            }
        }

        let report = try IdentityRepairService(context: context).repairAll()

        XCTAssertEqual(report.podcastsInspected, 50)
        XCTAssertEqual(report.episodesInspected, 0)
        XCTAssertEqual(report, IdentityRepairReport(podcastsInspected: 50))
    }

    func testTargetedEpisodeRepairMergesOnlyWithinRequestedPodcast() throws {
        let context = TestStore.freshContext()
        let podcast = Podcast(feedURL: "https://example.com/feed", title: "Show")
        let otherPodcast = Podcast(feedURL: "https://example.com/other", title: "Other")
        context.insert(podcast)
        context.insert(otherPodcast)
        for owner in [podcast, otherPodcast] {
            for index in 0..<2 {
                let episode = Episode(
                    guid: "duplicate",
                    title: "Episode \(index)",
                    audioURL: "https://example.com/\(index).mp3",
                    createdAt: index == 0 ? oldDate : newDate
                )
                episode.podcast = owner
                context.insert(episode)
            }
        }

        let report = try IdentityRepairService(context: context).repairEpisodes(in: podcast)
        try context.save()

        XCTAssertEqual(report.episodesInspected, 2)
        XCTAssertEqual(report.episodesRemoved, 1)
        XCTAssertEqual(podcast.episodes?.count, 1)
        XCTAssertEqual(otherPodcast.episodes?.count, 2)
    }

    func testTargetedEpisodeRepairUnloadsPlayerBeforeDeletingLoadedDuplicate() throws {
        let context = TestStore.freshContext()
        let podcast = Podcast(feedURL: "https://example.com/feed", title: "Show")
        context.insert(podcast)
        let survivor = Episode(
            guid: "duplicate",
            title: "Older survivor",
            audioURL: "https://example.com/old.mp3",
            createdAt: oldDate
        )
        survivor.podcast = podcast
        context.insert(survivor)
        let doomed = Episode(
            guid: "duplicate",
            title: "Loaded duplicate",
            audioURL: "https://example.com/new.mp3",
            createdAt: newDate
        )
        doomed.podcast = podcast
        context.insert(doomed)
        try context.save()

        let player = PlayerService()
        player.configure(context: context)
        player.load(doomed)
        XCTAssertEqual(player.nowPlayingEpisodeID, doomed.persistentModelID)

        _ = try IdentityRepairService(context: context).repairEpisodes(in: podcast)

        XCTAssertNil(player.nowPlayingEpisode)
        XCTAssertNil(player.nowPlayingEpisodeID)
        try context.save()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Episode>()), 1)
    }

    func testTargetedEpisodeRepairCanLimitWorkToIncomingGUIDs() throws {
        let context = TestStore.freshContext()
        let podcast = Podcast(feedURL: "https://example.com/feed", title: "Show")
        context.insert(podcast)
        for guid in ["incoming", "unrelated"] {
            for index in 0..<2 {
                let episode = Episode(
                    guid: guid,
                    title: "Episode \(index)",
                    audioURL: "https://example.com/\(guid)-\(index).mp3",
                    createdAt: index == 0 ? oldDate : newDate
                )
                episode.podcast = podcast
                context.insert(episode)
            }
        }

        let report = try IdentityRepairService(context: context).repairEpisodes(
            in: podcast,
            matchingGUIDs: ["incoming"]
        )
        try context.save()

        XCTAssertEqual(report.episodesInspected, 2)
        XCTAssertEqual(report.episodesRemoved, 1)
        XCTAssertEqual(podcast.episodes?.filter { $0.guid == "incoming" }.count, 1)
        XCTAssertEqual(podcast.episodes?.filter { $0.guid == "unrelated" }.count, 2)
    }
}
