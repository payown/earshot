import XCTest
import SwiftData
import UserNotifications
@testable import Earshot

/// Main-actor behavior of `DownloadManager` that does NOT start a real background
/// transfer (#544). Actual background downloads need a device (Phase 9); these
/// exercise only the branches that touch SwiftData without enqueuing a task:
/// the already-downloaded no-op, the invalid-URL failure, remove, and that
/// reconciliation leaves non-`.downloading` episodes untouched (and never forces
/// the shared background session into existence).
@MainActor
final class DownloadManagerTests: XCTestCase {

    private func makeManager(_ context: ModelContext) -> DownloadManager {
        let manager = DownloadManager()
        manager.configure(context: context)
        return manager
    }

    /// Seeds the mirrored episode plus its device-local download row, matching
    /// the split-store state that bulk download operations query in production.
    private func persistLocalDownloadState(
        for episodes: [Episode], in context: ModelContext
    ) throws {
        let podcast = Podcast(
            feedURL: "https://downloads.test/\(UUID().uuidString)",
            title: "Download tests"
        )
        context.insert(podcast)
        for episode in episodes {
            episode.podcast = podcast
            context.insert(episode)
            LocalStateStore.persist(episode, in: context)
        }
        try context.save()
    }

    /// Writes a real fixture file into the CURRENT `Documents/Downloads`
    /// directory (the one `DownloadPaths.resolveLocalURL` resolves against) and
    /// schedules its removal so tests never leak files across runs.
    private func plantDownloadFile(named name: String) throws -> URL {
        let url = try DownloadPaths.downloadsDirectory().appendingPathComponent(name)
        try Data("audio".utf8).write(to: url)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    func testDownloadIsNoOpWhenAlreadyDownloaded() async {
        let context = TestStore.freshContext()
        let episode = Episode(guid: "g1", title: "Done", audioURL: "https://h/a.mp3",
                              downloadStatus: .downloaded, downloadPath: "/tmp/a.mp3")
        context.insert(episode)
        let manager = makeManager(context)

        await manager.download(episode)

        // Early return before any session/task work; state is left intact.
        XCTAssertEqual(episode.downloadStatus, .downloaded)
        XCTAssertEqual(episode.downloadPath, "/tmp/a.mp3")
    }

    func testDownloadWithInvalidURLMarksFailed() async {
        let context = TestStore.freshContext()
        // Empty audioURL → URL(string:) is nil → the failure branch, reached only
        // after the Wi-Fi gate passes (defaults: wifiOnly=true, isOnWifi=true).
        let episode = Episode(guid: "g2", title: "Bad URL", audioURL: "")
        context.insert(episode)
        let manager = makeManager(context)

        await manager.download(episode)

        XCTAssertEqual(episode.downloadStatus, .failed)
        XCTAssertNil(episode.downloadPath)
    }

    func testBBCDownloadStartsWithHTTPSSelector() async throws {
        let context = TestStore.freshContext()
        let episode = Episode(
            guid: "bbc", title: "BBC episode",
            audioURL: "http://open.live.bbc.co.uk/mediaselector/6/select/proto/http/vpid/bbc.mp3"
        )
        context.insert(episode)
        try context.save()
        var transferURL: URL?
        let manager = DownloadManager { url, _ in transferURL = url }
        manager.configureForTesting(context: context, isOnWifi: true)

        await manager.download(episode)

        XCTAssertEqual(episode.downloadStatus, .downloading)
        XCTAssertEqual(
            transferURL?.absoluteString,
            "https://open.live.bbc.co.uk/mediaselector/6/select/proto/https/vpid/bbc.mp3"
        )
    }

    func testCorrectedMediaCleanupRunsAfterSavedRepairInstruction() async throws {
        let context = TestStore.freshContext()
        let podcast = Podcast(feedURL: "https://h/feed.xml", title: "Show")
        let episode = Episode(
            guid: "corrected", title: "Episode", audioURL: "https://h/new.mp3"
        )
        episode.podcast = podcast
        context.insert(podcast)
        context.insert(episode)
        try context.save()
        let staleName = "corrected-media-\(UUID().uuidString).mp3"
        let staleFile = try plantDownloadFile(named: staleName)
        let manager = makeManager(context)

        await manager.replaceCorrectedMedia([
            CorrectedEpisodeMedia(
                episodeID: episode.persistentModelID,
                restoreDownloadIntent: false,
                staleDownloadPath: staleName
            )
        ])

        XCTAssertFalse(FileManager.default.fileExists(atPath: staleFile.path))
        XCTAssertEqual(episode.downloadStatus, .none)
        XCTAssertNil(episode.downloadPath)
    }

    func testDownloadAllReportsEligibleStartedSkippedAndFailed() async {
        let context = TestStore.freshContext()
        let invalid = Episode(guid: "batch-invalid", title: "Invalid", audioURL: "")
        let downloaded = Episode(
            guid: "batch-downloaded", title: "Downloaded",
            audioURL: "https://h/downloaded.mp3", downloadStatus: .downloaded
        )
        let downloading = Episode(
            guid: "batch-downloading", title: "Downloading",
            audioURL: "https://h/downloading.mp3", downloadStatus: .downloading
        )
        let pending = Episode(
            guid: "batch-pending", title: "Pending",
            audioURL: "https://h/pending.mp3", downloadStatus: .pending
        )
        for episode in [invalid, downloaded, downloading, pending] {
            context.insert(episode)
        }
        let manager = makeManager(context)

        let report = await manager.downloadAll([invalid, downloaded, downloading, pending])

        XCTAssertEqual(
            report,
            DownloadBatchReport(
                eligible: 1, skipped: 3, deferred: 0,
                failed: 1, wasCancelled: false
            )
        )
        XCTAssertEqual(invalid.downloadStatus, .failed)
        XCTAssertEqual(downloading.downloadStatus, .downloading)
        XCTAssertEqual(pending.downloadStatus, .pending)
    }

    func testDownloadBatchAnnouncementIncludesEveryOutcomeOnce() {
        let report = DownloadBatchReport(
            eligible: 9, downloading: 5, waitingForWifi: 3, skipped: 3, deferred: 0,
            failed: 1, wasCancelled: false
        )

        XCTAssertEqual(
            report.announcement,
            "Download requests prepared. Eligible 9, accepted 8, downloading 5, waiting for Wi-Fi 3, already finished 0, skipped 3, deferred 0, could not start 1. Open Download activity in Downloads to check progress or retry failures."
        )
    }

    func testManualDownloadBatchPlanCapsOneInvocationAtFifty() {
        let statuses = Array(repeating: DownloadStatus.none, count: 831)

        let plan = ManualDownloadBatchPlan.make(statuses: statuses)

        XCTAssertEqual(plan.selectedIndices, Array(0..<50))
        XCTAssertEqual(plan.eligibleCount, 831)
        XCTAssertEqual(plan.skippedCount, 0)
        XCTAssertEqual(plan.deferredCount, 781)
    }

    func testManualDownloadBatchPlanSkipsCompletedAndActiveWithoutConsumingLimit() {
        let statuses: [DownloadStatus] = [
            .downloaded, .downloading, .pending, .none, .failed,
        ]

        let plan = ManualDownloadBatchPlan.make(statuses: statuses)

        XCTAssertEqual(plan.selectedIndices, [3, 4])
        XCTAssertEqual(plan.eligibleCount, 2)
        XCTAssertEqual(plan.skippedCount, 3)
        XCTAssertEqual(plan.deferredCount, 0)
    }

    func testDownloadAllDefensivelyCapsCallerAndReportsDeferredEpisodes() async {
        let context = TestStore.freshContext()
        let episodes = (0..<60).map {
            Episode(guid: "capped-\($0)", title: "Episode \($0)", audioURL: "")
        }
        for episode in episodes { context.insert(episode) }
        let manager = makeManager(context)

        let report = await manager.downloadAll(episodes)

        XCTAssertEqual(report.eligible, 60)
        XCTAssertEqual(report.accepted, 0)
        XCTAssertEqual(report.skipped, 0)
        XCTAssertEqual(report.deferred, 10)
        XCTAssertEqual(report.failed, 50)
        XCTAssertEqual(episodes.prefix(50).map(\.downloadStatus), Array(repeating: .failed, count: 50))
        XCTAssertEqual(episodes.suffix(10).map(\.downloadStatus), Array(repeating: .none, count: 10))
    }

    func testRemoveDownloadDeletesFileAndResetsState() throws {
        let context = TestStore.freshContext()
        // Post-#575 contract: downloadPath stores a bare file NAME; the file
        // lives in the real Downloads directory and is deleted via the resolved
        // URL (`Episode.localAudioURL`).
        let name = "earshot-test-remove-\(UUID().uuidString).mp3"
        let fileURL = try plantDownloadFile(named: name)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        let episode = Episode(guid: "g3", title: "Downloaded", audioURL: "https://h/a.mp3",
                              downloadStatus: .downloaded, downloadPath: name)
        context.insert(episode)
        let manager = makeManager(context)

        manager.removeDownload(episode)

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertNil(episode.downloadPath)
        XCTAssertEqual(episode.downloadStatus, DownloadStatus.none)
    }

    func test_removeDownload_legacyAbsolutePath_deletesFileAtResolvedLocation() throws {
        let context = TestStore.freshContext()
        // Pre-#575 rows hold an absolute path from a DEAD container. The real
        // file is in the CURRENT Downloads directory under the same name;
        // removeDownload must delete that one, not the stale path.
        let name = "earshot-test-legacy-\(UUID().uuidString).mp3"
        let fileURL = try plantDownloadFile(named: name)
        let legacyPath = "/var/mobile/Containers/Data/Application/DEAD-UUID/Documents/Downloads/\(name)"

        let episode = Episode(guid: "g-legacy", title: "Legacy", audioURL: "https://h/a.mp3",
                              downloadStatus: .downloaded, downloadPath: legacyPath)
        context.insert(episode)
        let manager = makeManager(context)

        manager.removeDownload(episode)

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path),
                       "The real file at the resolved location must be deleted")
        XCTAssertNil(episode.downloadPath)
        XCTAssertEqual(episode.downloadStatus, DownloadStatus.none)
    }

    // MARK: clearAllDownloads

    func test_cancelActiveDownloads_resetsActiveStateAndKeepsCompletedDownload() async throws {
        let context = TestStore.freshContext()
        let completedName = "earshot-test-cancel-kept-\(UUID().uuidString).mp3"
        let completedFile = try plantDownloadFile(named: completedName)
        let firstActive = Episode(
            guid: "cancel-active-one", title: "Active one", audioURL: "https://h/one.mp3",
            downloadStatus: .downloading
        )
        let secondActive = Episode(
            guid: "cancel-active-two", title: "Active two", audioURL: "https://h/two.mp3",
            downloadStatus: .downloading
        )
        let completed = Episode(
            guid: "cancel-completed", title: "Completed", audioURL: "https://h/completed.mp3",
            downloadStatus: .downloaded, downloadPath: completedName
        )
        try persistLocalDownloadState(for: [firstActive, secondActive, completed], in: context)
        let manager = makeManager(context)

        let cancelled = await manager.cancelActiveDownloads()

        XCTAssertEqual(cancelled, 2)
        XCTAssertEqual(firstActive.downloadStatus, .none)
        XCTAssertEqual(secondActive.downloadStatus, .none)
        XCTAssertEqual(completed.downloadStatus, .downloaded)
        XCTAssertEqual(completed.downloadPath, completedName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: completedFile.path))
    }

    func testStorageSnapshotMatchesActiveEpisodesOffMainAndReadsOtherContextSaves() async throws {
        let context = TestStore.freshContext()
        let podcast = Podcast(feedURL: "https://example.com/show", title: "Show")
        let episode = Episode(guid: "same-guid", title: "Episode", audioURL: "https://example.com/audio")
        episode.podcast = podcast
        context.insert(podcast)
        context.insert(episode)
        context.insert(LocalEpisodeState(podcastFeedURL: podcast.feedURL, episodeGUID: episode.guid,
                                         downloadStatus: .downloading))
        context.insert(LocalEpisodeState(podcastFeedURL: "https://example.com/other", episodeGUID: episode.guid,
                                         downloadStatus: .pending, downloadPath: "orphan.mp3"))
        context.insert(LocalEpisodeState(podcastFeedURL: "https://example.com/third", episodeGUID: "done",
                                         downloadStatus: .downloaded, downloadPath: "done.mp3"))
        try context.save()
        let snapshot = try await DownloadStorageSnapshot.load(container: context.container)
        XCTAssertEqual(snapshot.counts, .init(downloadedCount: 2, activeCount: 1))
        XCTAssertEqual(snapshot.paths, ["orphan.mp3", "done.mp3"])
        XCTAssertFalse(snapshot.executedStoreWorkOnMainThread)

        let otherContext = ModelContext(context.container)
        otherContext.insert(LocalEpisodeState(podcastFeedURL: "https://example.com/fourth", episodeGUID: "new",
                                              downloadStatus: .downloaded, downloadPath: "new.mp3"))
        try otherContext.save()
        let refreshed = try await DownloadStorageSnapshot.load(container: context.container)
        XCTAssertEqual(refreshed.counts, .init(downloadedCount: 3, activeCount: 1))
        XCTAssertEqual(refreshed.paths, ["orphan.mp3", "done.mp3", "new.mp3"])
        XCTAssertFalse(refreshed.executedStoreWorkOnMainThread)
    }

    func test_storageSummaryReportsCompletedActiveAndAllocatedBytes() async throws {
        let context = TestStore.freshContext()
        let completedName = "earshot-test-summary-\(UUID().uuidString).mp3"
        _ = try plantDownloadFile(named: completedName)
        let completed = Episode(
            guid: "summary-completed", title: "Completed", audioURL: "https://h/completed.mp3",
            downloadStatus: .downloaded, downloadPath: completedName
        )
        let active = Episode(
            guid: "summary-active", title: "Active", audioURL: "https://h/active.mp3",
            downloadStatus: .downloading
        )
        try persistLocalDownloadState(for: [completed, active], in: context)
        let manager = makeManager(context)

        let summary = await manager.storageSummary()
        let counts = await manager.storageCounts()

        XCTAssertEqual(summary.downloadedCount, 1)
        XCTAssertEqual(summary.activeCount, 1)
        XCTAssertGreaterThan(summary.allocatedBytes, 0)
        XCTAssertEqual(counts.downloadedCount, 1)
        XCTAssertEqual(counts.activeCount, 1)
    }

    func test_clearAllDownloads_deletesEveryFileAndResetsState() async throws {
        let context = TestStore.freshContext()
        let nameA = "earshot-test-clear-a-\(UUID().uuidString).mp3"
        let nameB = "earshot-test-clear-b-\(UUID().uuidString).mp3"
        let fileA = try plantDownloadFile(named: nameA)
        let fileB = try plantDownloadFile(named: nameB)

        let a = Episode(guid: "c1", title: "A", audioURL: "https://h/a.mp3",
                        downloadStatus: .downloaded, downloadPath: nameA)
        let b = Episode(guid: "c2", title: "B", audioURL: "https://h/b.mp3",
                        downloadStatus: .downloaded, downloadPath: nameB)
        // An idle (never-downloaded) episode must be left completely alone.
        let idle = Episode(guid: "c3", title: "Idle", audioURL: "https://h/i.mp3",
                           downloadStatus: DownloadStatus.none)
        try persistLocalDownloadState(for: [a, b], in: context)
        context.insert(idle)
        let manager = makeManager(context)

        let removed = await manager.clearAllDownloads()

        XCTAssertEqual(removed, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileA.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileB.path))
        XCTAssertNil(a.downloadPath)
        XCTAssertNil(b.downloadPath)
        XCTAssertEqual(a.downloadStatus, DownloadStatus.none)
        XCTAssertEqual(b.downloadStatus, DownloadStatus.none)
        XCTAssertEqual(idle.downloadStatus, DownloadStatus.none,
                       "A never-downloaded episode is untouched")
    }

    func test_clearAllDownloads_noDownloads_returnsZeroAndDoesNothing() async {
        let context = TestStore.freshContext()
        let idle = Episode(guid: "c4", title: "Idle", audioURL: "https://h/i.mp3",
                           downloadStatus: DownloadStatus.none)
        context.insert(idle)
        let manager = makeManager(context)

        let removed = await manager.clearAllDownloads()

        XCTAssertEqual(removed, 0)
        XCTAssertEqual(idle.downloadStatus, DownloadStatus.none)
        XCTAssertFalse(context.hasChanges, "Nothing to clear must write nothing")
    }

    func test_clearAllDownloads_legacyAbsolutePath_deletesFileAtResolvedLocation() async throws {
        // Bulk clear must honor the same #575 resolution as removeDownload: a
        // legacy absolute path still deletes the real file in the CURRENT
        // Downloads directory.
        let context = TestStore.freshContext()
        let name = "earshot-test-clear-legacy-\(UUID().uuidString).mp3"
        let fileURL = try plantDownloadFile(named: name)
        let legacyPath = "/var/mobile/Containers/Data/Application/DEAD-UUID/Documents/Downloads/\(name)"

        let episode = Episode(guid: "c5", title: "Legacy", audioURL: "https://h/a.mp3",
                              downloadStatus: .downloaded, downloadPath: legacyPath)
        try persistLocalDownloadState(for: [episode], in: context)
        let manager = makeManager(context)

        let removed = await manager.clearAllDownloads()

        XCTAssertEqual(removed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path),
                       "The real file at the resolved location must be deleted")
        XCTAssertNil(episode.downloadPath)
        XCTAssertEqual(episode.downloadStatus, DownloadStatus.none)
    }

    func test_finishedDownloadAfterEpisodeDeletionRemovesOrphanedFile() throws {
        let name = "earshot-test-orphan-completion-\(UUID().uuidString).mp3"
        let fileURL = try plantDownloadFile(named: name)
        let context = TestStore.freshContext()
        DownloadManager.setContainerForTesting(context.container)
        defer { DownloadManager.setContainerForTesting(nil) }

        DownloadManager.handle(PendingDownloadTerminalEvent(
            taskKey: "https://example.com/deleted-feed|deleted-episode",
            outcome: .finished(fileName: name)
        ))

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fileURL.path),
            "a completion with no surviving episode must not leak downloaded audio"
        )
    }

    func testFinishedEventWaitsForContainerWithoutDeletingFile() throws {
        let name = "earshot-test-waiting-\(UUID().uuidString).mp3"
        let fileURL = try plantDownloadFile(named: name)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        DownloadManager.setContainerForTesting(nil)
        let handled = DownloadManager.handle(PendingDownloadTerminalEvent(
            taskKey: "waiting", outcome: .finished(fileName: name)
        ))
        XCTAssertFalse(handled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testOrphanedLegacyEventDoesNotDeleteAnotherEpisodesFile() throws {
        let context = TestStore.freshContext()
        let name = "earshot-shared-\(UUID().uuidString).mp3"
        let fileURL = try plantDownloadFile(named: name)
        let owner = Episode(guid: "owner", title: "Owner", audioURL: "https://h/a.mp3",
                            downloadStatus: .downloaded, downloadPath: name)
        try persistLocalDownloadState(for: [owner], in: context)
        DownloadManager.setContainerForTesting(context.container)
        defer { DownloadManager.setContainerForTesting(nil) }
        XCTAssertTrue(DownloadManager.handle(PendingDownloadTerminalEvent(
            taskKey: "missing-episode", outcome: .finished(fileName: name)
        )))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(owner.downloadPath, name)
    }

    func testRemovingOrCleaningSharedLegacyDownloadKeepsOtherEpisodesAudio() throws {
        for usePlayedCleanup in [false, true] {
            let context = TestStore.freshContext()
            let name = "shared-legacy-\(UUID().uuidString).mp3"
            let file = try plantDownloadFile(named: name)
            let a = Podcast(feedURL: "https://first.example/feed", title: "First")
            let b = Podcast(feedURL: "https://second.example/feed", title: "Second")
            let first = Episode(guid: "1", title: "First", audioURL: "https://h/a.mp3",
                                downloadStatus: .downloaded, downloadPath: name)
            let second = Episode(guid: "1", title: "Second", audioURL: "https://h/b.mp3",
                                 downloadStatus: .downloaded,
                                 downloadPath: "/old/container/Downloads/\(name)")
            first.podcast = a; second.podcast = b
            context.insert(a); context.insert(b); context.insert(first); context.insert(second)
            LocalStateStore.persist(first, in: context)
            LocalStateStore.persist(second, in: context)
            try context.save()
            let manager = makeManager(context)
            if usePlayedCleanup {
                DownloadCleanup.removeDownloadFileAndState(first, in: context)
            } else {
                manager.removeDownload(first)
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
            XCTAssertNil(first.downloadPath)
            XCTAssertNotNil(second.downloadPath)
            manager.removeDownload(second)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        }
    }

    func testExpirationPreservesAudioReferencedByAnotherEpisode() throws {
        let context = TestStore.freshContext()
        let name = "shared-expiration-\(UUID().uuidString).mp3"
        let file = try plantDownloadFile(named: name)
        let a = Podcast(feedURL: "https://expired.example/feed", title: "Expired")
        let b = Podcast(feedURL: "https://kept.example/feed", title: "Kept")
        let first = Episode(guid: "1", title: "Expired", audioURL: "https://h/a.mp3",
                            downloadStatus: .downloaded, downloadPath: name)
        let second = Episode(guid: "1", title: "Kept", audioURL: "https://h/b.mp3",
                             downloadStatus: .downloaded, downloadPath: name)
        let c = Podcast(feedURL: "https://expired2.example/feed", title: "Also expired")
        let third = Episode(guid: "1", title: "Also expired", audioURL: "https://h/c.mp3",
                            downloadStatus: .downloaded, downloadPath: name)
        first.podcast = a; second.podcast = b
        third.podcast = c
        context.insert(a); context.insert(b); context.insert(c)
        context.insert(first); context.insert(second); context.insert(third)
        LocalStateStore.persist(first, in: context); LocalStateStore.persist(second, in: context)
        LocalStateStore.persist(third, in: context)
        context.insert(RecentlyExpired(episode: first, expiredAt: Date().addingTimeInterval(-9 * 86400)))
        context.insert(RecentlyExpired(episode: third, expiredAt: Date().addingTimeInterval(-9 * 86400)))
        try context.save()
        ExpirationService(context: context).runExpiration(now: Date())
        XCTAssertNil(first.downloadPath)
        XCTAssertNil(third.downloadPath)
        XCTAssertEqual(second.downloadPath, name)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testBulkCleanupRetainsFileOwnedOutsideBatch() throws {
        let context = TestStore.freshContext()
        let name = "bulk-shared-\(UUID().uuidString).mp3"
        let file = try plantDownloadFile(named: name)
        let episodes = (0..<3).map { index in
            let podcast = Podcast(feedURL: "https://show\(index).example/feed", title: "Show")
            let episode = Episode(guid: "1", title: "Episode", audioURL: "https://h/a.mp3",
                                  downloadStatus: .downloaded, downloadPath: name)
            episode.podcast = podcast
            context.insert(podcast); context.insert(episode)
            LocalStateStore.persist(episode, in: context)
            return episode
        }
        try context.save()
        let ownership = DownloadCleanup.bulkOwnership(for: Array(episodes.prefix(2)), in: context)
        for episode in episodes.prefix(2) {
            DownloadCleanup.removeDownloadFileAndState(episode, in: context, ownership: ownership)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(episodes[2].downloadPath, name)
        DownloadCleanup.removeDownloadFileAndState(episodes[2], in: context)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testExpirationRemovesSharedFileWhenAllOwnersArePurged() throws {
        let context = TestStore.freshContext()
        let name = "expired-shared-\(UUID().uuidString).mp3"
        let file = try plantDownloadFile(named: name)
        for index in 0..<2 {
            let podcast = Podcast(feedURL: "https://expired\(index).example/feed", title: "Show")
            let episode = Episode(guid: "1", title: "Expired", audioURL: "https://h/a.mp3",
                                  downloadStatus: .downloaded, downloadPath: name)
            episode.podcast = podcast
            context.insert(podcast); context.insert(episode)
            LocalStateStore.persist(episode, in: context)
            context.insert(RecentlyExpired(episode: episode, expiredAt: Date().addingTimeInterval(-9 * 86400)))
        }
        try context.save()
        // A separate context refaults the episodes without relying on the
        // transient state of the objects that created the download rows.
        LocalRuntimeState.shared.clear()
        let refaultedContext = ModelContext(context.container)
        ExpirationService(context: refaultedContext).runExpiration(now: Date())
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try refaultedContext.fetchCount(FetchDescriptor<LocalEpisodeState>()), 0)
    }

    func testExpirationSaveFailureKeepsFileAndDownloadState() throws {
        let context = TestStore.freshContext()
        let name = "expired-save-failure-\(UUID().uuidString).mp3"
        let file = try plantDownloadFile(named: name)
        let episode = Episode(guid: "expiration-save", title: "Expired", audioURL: "https://h/a.mp3",
                              downloadStatus: .downloaded, downloadPath: name)
        try persistLocalDownloadState(for: [episode], in: context)
        context.insert(RecentlyExpired(episode: episode, expiredAt: Date().addingTimeInterval(-9 * 86400)))
        try context.save()
        ExpirationService(context: context, saveOperation: { _ in
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
            throw DownloadEventTestError.injected
        }).runExpiration(now: Date())

        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(episode.downloadStatus, .downloaded)
        XCTAssertEqual(episode.downloadPath, name)
        let fresh = ModelContext(context.container)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<LocalEpisodeState>()).first?.downloadPath, name)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<RecentlyExpired>()), 1)
    }

    func testExpirationSaveFailureRestoresRefaultedDownloadFromLocalState() throws {
        let context = TestStore.freshContext()
        let name = "expired-refault-failure-\(UUID().uuidString).mp3"
        let file = try plantDownloadFile(named: name)
        let original = Episode(guid: "expiration-refault", title: "Expired", audioURL: "https://h/a.mp3",
                               downloadStatus: .downloaded, downloadPath: name)
        try persistLocalDownloadState(for: [original], in: context)
        context.insert(RecentlyExpired(episode: original, expiredAt: Date().addingTimeInterval(-9 * 86400)))
        try context.save()
        LocalRuntimeState.shared.clear()
        let fresh = ModelContext(context.container)
        let episode = try XCTUnwrap(fresh.fetch(FetchDescriptor<Episode>()).first)
        XCTAssertNil(LocalRuntimeState.shared.episode(episode.persistentModelID))

        ExpirationService(context: fresh, saveOperation: { _ in
            throw DownloadEventTestError.injected
        }).runExpiration(now: Date())

        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(episode.downloadStatus, .downloaded)
        XCTAssertEqual(episode.downloadPath, name)
        let verify = ModelContext(context.container)
        XCTAssertEqual(try verify.fetch(FetchDescriptor<LocalEpisodeState>()).first?.downloadPath, name)
        XCTAssertEqual(try verify.fetchCount(FetchDescriptor<RecentlyExpired>()), 1)
    }

    func testExpirationSavesBeforeRemovingUnsharedFile() throws {
        let context = TestStore.freshContext()
        let name = "expired-save-success-\(UUID().uuidString).mp3"
        let file = try plantDownloadFile(named: name)
        let episode = Episode(guid: "expiration-success", title: "Expired", audioURL: "https://h/a.mp3",
                              downloadStatus: .downloaded, downloadPath: name)
        try persistLocalDownloadState(for: [episode], in: context)
        context.insert(RecentlyExpired(episode: episode, expiredAt: Date().addingTimeInterval(-9 * 86400)))
        try context.save()
        var saved = false
        ExpirationService(context: context, saveOperation: { target in
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
            try target.save()
            saved = true
        }).runExpiration(now: Date())

        XCTAssertTrue(saved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNil(episode.downloadPath)
    }

    func testFinishedEventFetchFailurePreservesFileForRetry() throws {
        let context = TestStore.freshContext()
        let name = "earshot-test-fetch-failure-\(UUID().uuidString).mp3"
        let fileURL = try plantDownloadFile(named: name)
        defer {
            DownloadManager.setContainerForTesting(nil)
            try? FileManager.default.removeItem(at: fileURL)
        }
        DownloadManager.setContainerForTesting(context.container)
        let handled = DownloadManager.handle(
            PendingDownloadTerminalEvent(taskKey: "waiting", outcome: .finished(fileName: name)),
            resolve: { _, _ in throw DownloadEventTestError.injected }
        )
        XCTAssertFalse(handled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testFinishedEventRetriesSaveAndReplayKeepsOwnedFile() throws {
        let context = TestStore.freshContext()
        let episode = Episode(guid: "retry-save", title: "Retry", audioURL: "https://h/a.mp3",
                              downloadStatus: .downloading)
        try persistLocalDownloadState(for: [episode], in: context)
        let name = "earshot-test-save-failure-\(UUID().uuidString).mp3"
        let fileURL = try plantDownloadFile(named: name)
        defer {
            DownloadManager.setContainerForTesting(nil)
            try? FileManager.default.removeItem(at: fileURL)
        }
        DownloadManager.setContainerForTesting(context.container)
        let event = PendingDownloadTerminalEvent(taskKey: episode.guid, outcome: .finished(fileName: name))
        XCTAssertFalse(DownloadManager.handle(event, persist: { _ in throw DownloadEventTestError.injected }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertTrue(DownloadManager.handle(event))
        XCTAssertTrue(DownloadManager.handle(event))
        XCTAssertEqual(episode.downloadStatus, .downloaded)
        XCTAssertEqual(episode.downloadPath, name)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testJournalRetainsEventAcrossFailedFetchUntilSuccessfulReplay() throws {
        let context = TestStore.freshContext()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = DownloadEventJournal(url: directory.appendingPathComponent("events.json"))
        let event = journal.record(taskKey: "no-such-episode", outcome: .failed)
        DownloadManager.setContainerForTesting(context.container)
        defer { DownloadManager.setContainerForTesting(nil) }

        XCTAssertFalse(DownloadManager.handle(event,
            resolve: { _, _ in throw DownloadEventTestError.injected },
            acknowledge: { journal.acknowledge($0.id) }))
        XCTAssertEqual(DownloadEventJournal(url: directory.appendingPathComponent("events.json")).pendingEvents(), [event])
        XCTAssertTrue(DownloadManager.handle(event, acknowledge: { journal.acknowledge($0.id) }))
        XCTAssertTrue(DownloadEventJournal(url: directory.appendingPathComponent("events.json")).pendingEvents().isEmpty)
    }

    func testFailedJournalAcknowledgementRetriesWithoutDeletingOwnedAudio() throws {
        let context = TestStore.freshContext()
        let episode = Episode(guid: "ack-retry", title: "Retry", audioURL: "https://h/a.mp3",
                              downloadStatus: .downloading)
        try persistLocalDownloadState(for: [episode], in: context)
        let name = "earshot-test-ack-\(UUID().uuidString).mp3"
        let fileURL = try plantDownloadFile(named: name)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            DownloadManager.setContainerForTesting(nil)
            try? FileManager.default.removeItem(at: directory)
        }
        let writer = JournalWriteProbe()
        let path = directory.appendingPathComponent("events.json")
        let journal = DownloadEventJournal(url: path, write: writer.write)
        let event = journal.record(taskKey: episode.guid, outcome: .finished(fileName: name))
        DownloadManager.setContainerForTesting(context.container)
        writer.failNext()

        XCTAssertFalse(DownloadManager.handle(event, acknowledge: { journal.acknowledge($0.id) }))
        XCTAssertEqual(episode.downloadStatus, .downloaded)
        XCTAssertEqual(episode.downloadPath, name)
        XCTAssertEqual(journal.pendingEvents(), [event])
        XCTAssertEqual(DownloadEventJournal(url: path).pendingEvents(), [event])
        XCTAssertTrue(DownloadManager.handle(event, acknowledge: { journal.acknowledge($0.id) }))
        XCTAssertTrue(journal.pendingEvents().isEmpty)
        XCTAssertTrue(DownloadEventJournal(url: path).pendingEvents().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testAcknowledgementRetryDoesNotApplyOldFailureToNewAttempt() throws {
        let context = TestStore.freshContext()
        let episode = Episode(guid: "ack-old-failure", title: "Retry", audioURL: "https://h/a.mp3",
                              downloadStatus: .downloading)
        try persistLocalDownloadState(for: [episode], in: context)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            DownloadManager.setContainerForTesting(nil)
            try? FileManager.default.removeItem(at: directory)
        }
        let writer = JournalWriteProbe()
        let path = directory.appendingPathComponent("events.json")
        let journal = DownloadEventJournal(url: path, write: writer.write)
        let event = journal.record(taskKey: episode.guid, outcome: .failed)
        DownloadManager.setContainerForTesting(context.container)
        writer.failNext()
        XCTAssertFalse(DownloadManager.handle(event, acknowledge: { journal.acknowledge($0.id) }))
        XCTAssertEqual(episode.downloadStatus, .failed)

        ActiveDownload.setDownloadStatus(.downloading, on: episode, in: context)
        try context.save()
        XCTAssertTrue(DownloadManager.handle(event, acknowledge: { journal.acknowledge($0.id) }))
        XCTAssertEqual(episode.downloadStatus, .downloading)
        XCTAssertTrue(DownloadEventJournal(url: path).pendingEvents().isEmpty)
    }

    func test_finishedDownloadSchedulesNotificationWhenEnabled() async throws {
        let context = TestStore.freshContext()
        let episode = Episode(
            guid: "notification-guid",
            title: "Finished episode",
            audioURL: "https://downloads.test/episode.mp3",
            downloadStatus: .downloading
        )
        try persistLocalDownloadState(for: [episode], in: context)
        AppSettingsStore(context: context).setBool(
            true,
            for: SettingsKey.downloadCompletionNotifications
        )
        let center = DownloadCompletionNotificationCenter()
        DownloadManager.setContainerForTesting(context.container)
        DownloadManager.setNotificationCenterForTesting(center)
        defer {
            DownloadManager.setContainerForTesting(nil)
            DownloadManager.setNotificationCenterForTesting(nil)
        }

        DownloadManager.handle(PendingDownloadTerminalEvent(
            taskKey: DownloadTaskKey.key(
                feedURL: episode.podcast?.feedURL,
                guid: episode.guid
            ),
            outcome: .finished(fileName: "notification-guid.mp3")
        ))

        for _ in 0..<100 where await center.addedRequestCount() == 0 {
            await Task.yield()
        }
        let requests = await center.addedRequestSnapshots()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.title, "Download complete")
        XCTAssertEqual(requests.first?.body, "Finished episode")
        XCTAssertEqual(
            requests.first?.categoryIdentifier,
            NotificationService.downloadCompletedCategoryID
        )
        XCTAssertEqual(requests.first?.episodeGUID, "notification-guid")
        XCTAssertEqual(episode.downloadStatus, .downloaded)
        XCTAssertEqual(episode.downloadPath, "notification-guid.mp3")
    }

    func test_finishedDownloadDoesNotScheduleNotificationByDefault() async throws {
        let context = TestStore.freshContext()
        let episode = Episode(
            guid: "quiet-guid",
            title: "Quiet episode",
            audioURL: "https://downloads.test/quiet.mp3",
            downloadStatus: .downloading
        )
        try persistLocalDownloadState(for: [episode], in: context)
        let center = DownloadCompletionNotificationCenter()
        DownloadManager.setContainerForTesting(context.container)
        DownloadManager.setNotificationCenterForTesting(center)
        defer {
            DownloadManager.setContainerForTesting(nil)
            DownloadManager.setNotificationCenterForTesting(nil)
        }

        DownloadManager.handle(PendingDownloadTerminalEvent(
            taskKey: DownloadTaskKey.key(
                feedURL: episode.podcast?.feedURL,
                guid: episode.guid
            ),
            outcome: .finished(fileName: "quiet-guid.mp3")
        ))
        await Task.yield()

        let requestCount = await center.addedRequestCount()
        XCTAssertEqual(requestCount, 0)
    }

    func testLateCompletionFromSupersededSourceIsDeletedAndCannotBecomeDownloaded() throws {
        let context = TestStore.freshContext()
        let podcast = Podcast(feedURL: "https://feed.test/rss", title: "Show")
        let episode = Episode(
            guid: "corrected-guid", title: "Corrected",
            audioURL: "https://cdn.test/new.mp3", downloadStatus: .none
        )
        episode.podcast = podcast
        context.insert(podcast)
        context.insert(episode)
        try context.save()
        let name = "earshot-stale-\(UUID().uuidString).mp3"
        let fileURL = try plantDownloadFile(named: name)
        let identity = DownloadTaskKey.key(feedURL: podcast.feedURL, guid: episode.guid)
        let oldSource = try XCTUnwrap(URL(string: "https://cdn.test/old.mp3"))
        let staleTaskKey = DownloadTransferKey.key(
            identityKey: identity, sourceURL: oldSource
        )
        DownloadManager.setContainerForTesting(context.container)
        defer { DownloadManager.setContainerForTesting(nil) }

        DownloadManager.handle(PendingDownloadTerminalEvent(
            taskKey: staleTaskKey,
            outcome: .finished(fileName: name)
        ))

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(episode.downloadStatus, .none)
        XCTAssertNil(episode.downloadPath)
    }

    func testLateFailureFromSupersededSourceDoesNotFailNewDownload() throws {
        let context = TestStore.freshContext()
        let episode = Episode(guid: "replacement", title: "Replacement",
                              audioURL: "https://cdn.test/new.mp3", downloadStatus: .downloading)
        try persistLocalDownloadState(for: [episode], in: context)
        let oldKey = DownloadTransferKey.key(identityKey: episode.guid,
                                               sourceURL: try XCTUnwrap(URL(string: "https://cdn.test/old.mp3")))
        DownloadManager.setContainerForTesting(context.container)
        defer { DownloadManager.setContainerForTesting(nil) }
        XCTAssertTrue(DownloadManager.handle(PendingDownloadTerminalEvent(taskKey: oldKey, outcome: .failed)))
        XCTAssertEqual(episode.downloadStatus, .downloading)
    }

    func testBBCPreferredSelectorIsAcceptedForCompletionAndFailure() throws {
        let context = TestStore.freshContext()
        let selector = "http://open.live.bbc.co.uk/mediaselector/6/select/version/123/proto/http/format/json"
        let episode = Episode(guid: "bbc-selector", title: "BBC", audioURL: selector,
                              downloadStatus: .downloading)
        try persistLocalDownloadState(for: [episode], in: context)
        let preferred = SecureURL.preferredMediaHTTPS(try XCTUnwrap(URL(string: selector)))
        let key = DownloadTransferKey.key(identityKey: episode.guid, sourceURL: preferred)
        DownloadManager.setContainerForTesting(context.container)
        defer { DownloadManager.setContainerForTesting(nil) }
        XCTAssertTrue(DownloadManager.handle(PendingDownloadTerminalEvent(taskKey: key, outcome: .failed)))
        XCTAssertEqual(episode.downloadStatus, .failed)
        ActiveDownload.setDownloadStatus(.downloading, on: episode, in: context)
        try context.save()
        let name = "bbc-\(UUID().uuidString).mp3"
        _ = try plantDownloadFile(named: name)
        XCTAssertTrue(DownloadManager.handle(PendingDownloadTerminalEvent(taskKey: key, outcome: .finished(fileName: name))))
        XCTAssertEqual(episode.downloadStatus, .downloaded)
        XCTAssertEqual(episode.downloadPath, name)
    }

    func testCancellationResolvesOldWaiterAndChangedSourceDoesNotResolveNewWaiter() async throws {
        let context = TestStore.freshContext()
        let episode = Episode(guid: "wait-cancel", title: "Wait", audioURL: "https://h/old.mp3")
        try persistLocalDownloadState(for: [episode], in: context)
        var started: [String] = []
        let manager = DownloadManager(startTransfer: { _, key in started.append(key) })
        manager.configureForTesting(context: context, isOnWifi: true)
        DownloadManager.setContainerForTesting(context.container)
        defer { DownloadManager.setContainerForTesting(nil) }
        let first = Task { await manager.downloadAndWait(episode, timeout: 2) }
        while started.isEmpty { await Task.yield() }
        let oldKey = try XCTUnwrap(started.first)
        manager.removeDownload(episode)
        let cancelled = await first.value
        XCTAssertFalse(cancelled)

        episode.audioURL = "https://h/new.mp3"
        let second = Task { await manager.downloadAndWait(episode, timeout: 2) }
        while started.count < 2 { await Task.yield() }
        XCTAssertTrue(DownloadManager.handle(PendingDownloadTerminalEvent(taskKey: oldKey, outcome: .failed)))
        XCTAssertEqual(episode.downloadStatus, .downloading)
        let name = "new-\(UUID().uuidString).mp3"
        _ = try plantDownloadFile(named: name)
        XCTAssertTrue(DownloadManager.handle(PendingDownloadTerminalEvent(taskKey: started[1], outcome: .finished(fileName: name))))
        let completed = await second.value
        XCTAssertTrue(completed)
    }

    func testTaskEnumerationSeesEventJournaledDuringEnumeration() async {
        var journal: [String] = []
        let keys = await DownloadManager.liveTaskKeys(taskDescriptions: {
            journal.append("feed|episode")
            return []
        }, pendingKeys: { journal })
        XCTAssertEqual(keys?.contains("feed|episode"), true)
    }

    func testUnknownJournalDoesNotCauseOrphanReconciliation() async throws {
        let context = TestStore.freshContext()
        let episode = Episode(guid: "journal-unavailable", title: "Pending",
                              audioURL: "https://h/a.mp3", downloadStatus: .downloading)
        try persistLocalDownloadState(for: [episode], in: context)
        let manager = makeManager(context)

        let unknown = await DownloadManager.liveTaskKeys(
            taskDescriptions: { [] }, pendingKeys: { nil }
        )
        XCTAssertNil(unknown)
        await manager.reconcileStuckDownloads { unknown }
        XCTAssertEqual(episode.downloadStatus, .downloading)

        // Once the journal is readable, genuinely orphaned work can be reset.
        let empty = await DownloadManager.liveTaskKeys(
            taskDescriptions: { [] }, pendingKeys: { [] }
        )
        await manager.reconcileStuckDownloads { empty }
        XCTAssertEqual(episode.downloadStatus, .failed)
    }

    func testUnreadableJournalAutomaticallyResumesDeferredReconciliation() async throws {
        let context = TestStore.freshContext()
        let episode = Episode(guid: "journal-recovered", title: "Pending",
                              audioURL: "https://h/a.mp3", downloadStatus: .downloading)
        try persistLocalDownloadState(for: [episode], in: context)
        let manager = makeManager(context)
        DownloadManager.setContainerForTesting(context.container)
        defer { DownloadManager.setContainerForTesting(nil) }
        let reader = JournalReadProbe()
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let journal = DownloadEventJournal(url: url, read: reader.read)
        let delegate = DownloadSessionDelegate(journal: journal, retryDelays: [])
        delegate.installTerminalHandler { _, _ in }

        await manager.reconcileStuckDownloads(journalDelegate: delegate) {
            await DownloadManager.liveTaskKeys(taskDescriptions: { [] }, pendingKeys: { delegate.pendingTaskKeys() })
        }
        XCTAssertEqual(episode.downloadStatus, .downloading)
        reader.allowReads()
        // This is the same entry point used on foreground and protected-data availability.
        delegate.retryPendingEvents()
        for _ in 0..<100 where episode.downloadStatus == .downloading {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(episode.downloadStatus, .failed)
    }

    func testDeferredReconciliationDoesNotUseReplacedContext() async throws {
        let oldContext = TestStore.freshContext()
        let episode = Episode(guid: "journal-old-context", title: "Pending",
                              audioURL: "https://h/a.mp3", downloadStatus: .downloading)
        try persistLocalDownloadState(for: [episode], in: oldContext)
        let manager = makeManager(oldContext)
        DownloadManager.setContainerForTesting(oldContext.container)
        defer { DownloadManager.setContainerForTesting(nil) }
        let reader = JournalReadProbe()
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let delegate = DownloadSessionDelegate(journal: DownloadEventJournal(url: url, read: reader.read), retryDelays: [])
        delegate.installTerminalHandler { _, _ in }
        await manager.reconcileStuckDownloads(journalDelegate: delegate) {
            await DownloadManager.liveTaskKeys(taskDescriptions: { [] }, pendingKeys: { delegate.pendingTaskKeys() })
        }
        let replacement = TestStore.freshContext()
        manager.configureForTesting(context: replacement, isOnWifi: true)
        DownloadManager.setContainerForTesting(replacement.container)
        reader.allowReads()
        delegate.retryPendingEvents()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(episode.downloadStatus, .downloading)
    }

    func testReconciliationDoesNotOverwriteCompletionDuringTaskEnumeration() async throws {
        let context = TestStore.freshContext()
        let episode = Episode(guid: "finished-during-reconciliation", title: "Finished",
                              audioURL: "https://h/a.mp3", downloadStatus: .downloading)
        try persistLocalDownloadState(for: [episode], in: context)
        let manager = makeManager(context)
        await manager.reconcileStuckDownloads {
            episode.downloadPath = "finished.mp3"
            ActiveDownload.setDownloadStatus(.downloaded, on: episode, in: context)
            try? context.save()
            return []
        }
        XCTAssertEqual(episode.downloadStatus, .downloaded)
        XCTAssertEqual(episode.downloadPath, "finished.mp3")
    }

    func testDownloadPayloadValidationRejectsEmptyAndKnownNonMediaBodies() {
        XCTAssertFalse(DownloadPayloadValidation.accepts(
            statusCode: 200, contentType: "audio/mpeg", byteCount: 0
        ))
        XCTAssertFalse(DownloadPayloadValidation.accepts(
            statusCode: 200, contentType: "text/html", byteCount: 500
        ))
        XCTAssertFalse(DownloadPayloadValidation.accepts(
            statusCode: 200, contentType: "application/json", byteCount: 500
        ))
        XCTAssertFalse(DownloadPayloadValidation.accepts(
            statusCode: 404, contentType: "audio/mpeg", byteCount: 500
        ))
        XCTAssertTrue(DownloadPayloadValidation.accepts(
            statusCode: 200, contentType: "audio/mpeg", byteCount: 500
        ))
        XCTAssertTrue(DownloadPayloadValidation.accepts(
            statusCode: 200, contentType: "application/octet-stream", byteCount: 500
        ))
    }

    // MARK: DownloadCleanup — delete downloads after played

    func test_removeDownloadAfterPlayed_enabled_deletesFileAndResetsState() throws {
        let context = TestStore.freshContext()
        AppSettingsStore(context: context).setBool(true, for: SettingsKey.deleteDownloadAfterPlayed)
        let name = "earshot-test-afterplayed-\(UUID().uuidString).mp3"
        let fileURL = try plantDownloadFile(named: name)
        let episode = Episode(guid: "p1", title: "Played", audioURL: "https://h/a.mp3",
                              downloadStatus: .downloaded, downloadPath: name)
        context.insert(episode)

        DownloadCleanup.removeDownloadAfterPlayedIfEnabled(episode, in: context)

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertNil(episode.downloadPath)
        XCTAssertEqual(episode.downloadStatus, DownloadStatus.none)
    }

    func test_removeDownloadAfterPlayed_disabledByDefault_keepsFile() throws {
        let context = TestStore.freshContext()
        // Setting is off by default — do not set it.
        let name = "earshot-test-afterplayed-off-\(UUID().uuidString).mp3"
        let fileURL = try plantDownloadFile(named: name)
        let episode = Episode(guid: "p2", title: "Played", audioURL: "https://h/a.mp3",
                              downloadStatus: .downloaded, downloadPath: name)
        context.insert(episode)

        DownloadCleanup.removeDownloadAfterPlayedIfEnabled(episode, in: context)

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path),
                      "Off by default: the file must be kept")
        XCTAssertEqual(episode.downloadPath, name)
        XCTAssertEqual(episode.downloadStatus, .downloaded)
    }

    func test_removeDownloadAfterPlayed_enabledButNotDownloaded_isNoOp() {
        let context = TestStore.freshContext()
        AppSettingsStore(context: context).setBool(true, for: SettingsKey.deleteDownloadAfterPlayed)
        let episode = Episode(guid: "p3", title: "Streaming", audioURL: "https://h/a.mp3",
                              downloadStatus: DownloadStatus.none)
        context.insert(episode)

        DownloadCleanup.removeDownloadAfterPlayedIfEnabled(episode, in: context)

        XCTAssertEqual(episode.downloadStatus, DownloadStatus.none)
        XCTAssertNil(episode.downloadPath)
    }

    func test_inboxMarkPlayed_withDeleteAfterPlayedOn_removesDownload() throws {
        // Integration: proves the mark-played choke point actually fires cleanup.
        let context = TestStore.freshContext()
        AppSettingsStore(context: context).setBool(true, for: SettingsKey.deleteDownloadAfterPlayed)
        let name = "earshot-test-inbox-afterplayed-\(UUID().uuidString).mp3"
        let fileURL = try plantDownloadFile(named: name)
        let episode = Episode(guid: "p4", title: "Inbox", audioURL: "https://h/a.mp3",
                              downloadStatus: .downloaded, downloadPath: name)
        context.insert(episode)

        InboxRepository(context: context).markPlayed(episode)

        XCTAssertTrue(episode.isPlayed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(episode.downloadStatus, DownloadStatus.none)
    }

    func test_clearInbox_withAutomaticCleanupOn_removesDownloadWithoutMarkingPlayed() throws {
        let context = TestStore.freshContext()
        AppSettingsStore(context: context).setBool(true, for: SettingsKey.deleteDownloadAfterPlayed)
        let name = "earshot-test-clear-inbox-\(UUID().uuidString).mp3"
        let fileURL = try plantDownloadFile(named: name)
        let episode = Episode(
            guid: "clear-inbox-on", title: "Dismissed", audioURL: "https://h/inbox.mp3",
            downloadStatus: .downloaded, downloadPath: name
        )
        context.insert(episode)

        InboxRepository(context: context).clearInbox([episode])

        XCTAssertTrue(episode.inboxDismissed)
        XCTAssertFalse(episode.isPlayed, "Clearing Inbox must not count as a completed listen")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertNil(episode.downloadPath)
        XCTAssertEqual(episode.downloadStatus, .none)
    }

    func test_clearInbox_withAutomaticCleanupOff_keepsDownload() throws {
        let context = TestStore.freshContext()
        let name = "earshot-test-clear-inbox-off-\(UUID().uuidString).mp3"
        let fileURL = try plantDownloadFile(named: name)
        let episode = Episode(
            guid: "clear-inbox-off", title: "Dismissed", audioURL: "https://h/inbox.mp3",
            downloadStatus: .downloaded, downloadPath: name
        )
        context.insert(episode)

        InboxRepository(context: context).clearInbox([episode])

        XCTAssertTrue(episode.inboxDismissed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(episode.downloadPath, name)
        XCTAssertEqual(episode.downloadStatus, .downloaded)
    }

    func test_inboxCleanup_respectsPreferenceAcrossActionsAndDownloadStates() throws {
        for enabled in [false, true] {
            for status in [DownloadStatus.downloaded, .pending, .downloading] {
                for action in ["dismiss", "clear", "played"] {
                    let context = TestStore.freshContext()
                    AppSettingsStore(context: context).setBool(enabled, for: SettingsKey.deleteDownloadAfterPlayed)
                    let name = "earshot-inbox-cleanup-\(UUID().uuidString).mp3"
                    let file = status == .downloaded ? try plantDownloadFile(named: name) : nil
                    let episode = Episode(
                        guid: UUID().uuidString, title: "Cleanup", audioURL: "https://h/cleanup.mp3",
                        downloadStatus: status, downloadPath: file == nil ? nil : name
                    )
                    try persistLocalDownloadState(for: [episode], in: context)
                    ActiveDownload.setDownloadStatus(status, on: episode, in: context)
                    try context.save()
                    let repo = InboxRepository(context: context)
                    switch action {
                    case "dismiss": repo.dismiss(episode)
                    case "clear": repo.clearInbox([episode])
                    default: repo.markPlayed(episode)
                    }
                    let scenario = "\(action), \(status), cleanup=\(enabled)"
                    XCTAssertTrue(episode.inboxDismissed, scenario)
                    XCTAssertEqual(episode.isPlayed, action == "played", scenario)
                    XCTAssertEqual(episode.downloadStatus, enabled ? .none : status, scenario)
                    if let file {
                        XCTAssertEqual(FileManager.default.fileExists(atPath: file.path), !enabled, scenario)
                        XCTAssertEqual(episode.downloadPath, enabled ? nil : name, scenario)
                    }
                    if enabled {
                        XCTAssertEqual(ActiveDownload.rows(for: episode, in: context).count, 0, scenario)
                        if status == .downloading {
                            DownloadManager.setContainerForTesting(context.container)
                            defer { DownloadManager.setContainerForTesting(nil) }
                            let lateName = "earshot-late-cleanup-\(UUID().uuidString).mp3"
                            let lateFile = try plantDownloadFile(named: lateName)
                            let key = DownloadTaskKey.key(feedURL: episode.podcast?.feedURL, guid: episode.guid)
                            DownloadManager.handle(PendingDownloadTerminalEvent(taskKey: key, outcome: .finished(fileName: lateName)))
                            XCTAssertFalse(FileManager.default.fileExists(atPath: lateFile.path), scenario)
                            XCTAssertEqual(episode.downloadStatus, .none, scenario)
                        }
                    }
                }
            }
        }
    }

    func test_cancelDownload_onlyCancelsMatchingEpisode() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CleanupHoldingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let matching = session.downloadTask(with: URL(string: "https://h/matching.mp3")!)
        matching.taskDescription = DownloadTransferKey.key(
            identityKey: "target", sourceURL: URL(string: "https://h/matching.mp3")!
        )
        let unrelated = session.downloadTask(with: URL(string: "https://h/unrelated.mp3")!)
        unrelated.taskDescription = "unrelated"
        matching.resume()
        unrelated.resume()
        DownloadManager.cancelDownload(identityKey: "target", using: session)
        for _ in 0..<100 where matching.state == .running {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(matching.state == .canceling || matching.state == .completed)
        XCTAssertEqual(unrelated.state, .running)
    }

    func test_queueRemoval_withAutomaticCleanupOn_removesDownloadWithoutMarkingPlayed() throws {
        let context = TestStore.freshContext()
        AppSettingsStore(context: context).setBool(true, for: SettingsKey.deleteDownloadAfterPlayed)
        let name = "earshot-test-queue-remove-\(UUID().uuidString).mp3"
        let fileURL = try plantDownloadFile(named: name)
        let podcast = Podcast(feedURL: "https://h/feed.xml", title: "Queue cleanup")
        let episode = Episode(guid: "queue-on", title: "Removed", audioURL: "https://h/a.mp3",
                              downloadStatus: .downloaded, downloadPath: name)
        episode.podcast = podcast
        context.insert(podcast)
        context.insert(episode)
        let queue = QueueRepository(context: context)
        queue.add(episode)

        queue.cancelFromQueue(episode)

        XCTAssertNil(episode.queueItem)
        XCTAssertFalse(episode.isPlayed, "Removing from the queue must not count as completion")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertNil(episode.downloadPath)
        XCTAssertEqual(episode.downloadStatus, .none)
    }

    func test_queueRemoval_withAutomaticCleanupOff_keepsDownload() throws {
        let context = TestStore.freshContext()
        let name = "earshot-test-queue-remove-off-\(UUID().uuidString).mp3"
        let fileURL = try plantDownloadFile(named: name)
        let podcast = Podcast(feedURL: "https://h/feed-off.xml", title: "Queue cleanup off")
        let episode = Episode(guid: "queue-off", title: "Kept", audioURL: "https://h/b.mp3",
                              downloadStatus: .downloaded, downloadPath: name)
        episode.podcast = podcast
        context.insert(podcast)
        context.insert(episode)
        let queue = QueueRepository(context: context)
        queue.add(episode)

        queue.cancelFromQueue(episode)

        XCTAssertNil(episode.queueItem)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(episode.downloadPath, name)
        XCTAssertEqual(episode.downloadStatus, .downloaded)
    }

    func test_clearQueue_withAutomaticCleanupOn_removesAllDownloads() throws {
        let context = TestStore.freshContext()
        AppSettingsStore(context: context).setBool(true, for: SettingsKey.deleteDownloadAfterPlayed)
        let firstName = "earshot-test-clear-queue-1-\(UUID().uuidString).mp3"
        let secondName = "earshot-test-clear-queue-2-\(UUID().uuidString).mp3"
        let firstURL = try plantDownloadFile(named: firstName)
        let secondURL = try plantDownloadFile(named: secondName)
        let podcast = Podcast(feedURL: "https://h/clear.xml", title: "Clear cleanup")
        let first = Episode(guid: "clear-1", title: "First", audioURL: "https://h/1.mp3",
                            downloadStatus: .downloaded, downloadPath: firstName)
        let second = Episode(guid: "clear-2", title: "Second", audioURL: "https://h/2.mp3",
                             downloadStatus: .downloaded, downloadPath: secondName)
        first.podcast = podcast
        second.podcast = podcast
        context.insert(podcast)
        context.insert(first)
        context.insert(second)
        let queue = QueueRepository(context: context)
        queue.add([first, second])

        queue.clear()

        XCTAssertTrue(queue.queue().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondURL.path))
        XCTAssertEqual(first.downloadStatus, .none)
        XCTAssertEqual(second.downloadStatus, .none)
    }

    // MARK: downloadQueuedIfEnabled — auto-download queued episodes

    func test_downloadQueuedIfEnabled_on_kicksQueuedNotDownloadedEpisodes() async {
        let context = TestStore.freshContext()
        // Setting is on by default. Invalid audioURL so download() takes the
        // enqueue-failure branch (marks .failed) WITHOUT forcing the shared
        // background session or starting a real transfer — enough to prove the
        // queued episode was handed to download().
        let queued = Episode(guid: "q1", title: "Queued", audioURL: "")
        context.insert(queued)
        context.insert(QueueItem(episode: queued, position: 0))
        // An already-downloaded queued episode must be skipped, not re-kicked.
        let done = Episode(guid: "q2", title: "Done", audioURL: "https://h/a.mp3",
                           downloadStatus: .downloaded, downloadPath: "a.mp3")
        context.insert(done)
        context.insert(QueueItem(episode: done, position: 1))
        let manager = makeManager(context)

        await manager.downloadQueuedIfEnabled()

        XCTAssertEqual(queued.downloadStatus, .failed,
                       "A queued, not-downloaded episode is sent to download()")
        XCTAssertEqual(done.downloadStatus, .downloaded, "Already-downloaded queued episode is skipped")
        XCTAssertEqual(done.downloadPath, "a.mp3")
    }

    func test_downloadQueuedIfEnabled_off_doesNothing() async {
        let context = TestStore.freshContext()
        AppSettingsStore(context: context).setBool(false, for: SettingsKey.autoDownloadQueued)
        let queued = Episode(guid: "q3", title: "Queued", audioURL: "")
        context.insert(queued)
        context.insert(QueueItem(episode: queued, position: 0))
        let manager = makeManager(context)

        await manager.downloadQueuedIfEnabled()

        XCTAssertEqual(queued.downloadStatus, DownloadStatus.none,
                       "Setting off: queued episode is left untouched")
    }

    // MARK: reconcileDownloadPaths (#575)

    // Acceptance criterion: launch reconciliation rewrites legacy absolute
    // values to bare names when the file exists, resets rows whose file is
    // gone, and is idempotent.

    func test_reconcileDownloadPaths_legacyAbsolutePathWithRealFile_rewritesToBareNameKeepsStatus() async throws {
        let context = TestStore.freshContext()
        let name = "earshot-test-reconcile-\(UUID().uuidString).mp3"
        let fileURL = try plantDownloadFile(named: name)
        let legacyPath = "/var/mobile/Containers/Data/Application/OLD-UUID/Documents/Downloads/\(name)"

        let episode = Episode(guid: "r1", title: "Healable", audioURL: "https://h/a.mp3",
                              downloadStatus: .downloaded, downloadPath: legacyPath)
        try persistLocalDownloadState(for: [episode], in: context)
        let manager = makeManager(context)

        await manager.reconcileDownloadPaths()

        XCTAssertEqual(episode.downloadPath, name, "Legacy absolute path is rewritten to the bare file name")
        XCTAssertEqual(episode.downloadStatus, .downloaded, "Status is kept when the file exists")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path), "Healing never deletes the file")
    }

    func test_reconcileDownloadPaths_downloadedWithMissingFile_resetsToNone() async throws {
        let context = TestStore.freshContext()
        let episode = Episode(guid: "r2", title: "Gone", audioURL: "https://h/a.mp3",
                              downloadStatus: .downloaded,
                              downloadPath: "earshot-test-definitely-missing-\(UUID().uuidString).mp3")
        try persistLocalDownloadState(for: [episode], in: context)
        let manager = makeManager(context)

        await manager.reconcileDownloadPaths()

        XCTAssertNil(episode.downloadPath)
        XCTAssertEqual(episode.downloadStatus, DownloadStatus.none,
                       "A downloaded row whose file is gone becomes re-downloadable")
    }

    func test_reconcileDownloadPaths_downloadedWithEmptyPath_resetsToNone() async throws {
        // An empty-string path is still non-nil, so the bounded
        // `downloadPath != nil` query (#701) still finds it and the reset branch
        // still fires.
        let context = TestStore.freshContext()
        let emptyPath = Episode(guid: "r4", title: "Empty path", audioURL: "https://h/b.mp3",
                                downloadStatus: .downloaded, downloadPath: "")
        try persistLocalDownloadState(for: [emptyPath], in: context)
        let manager = makeManager(context)

        await manager.reconcileDownloadPaths()

        XCTAssertNil(emptyPath.downloadPath)
        XCTAssertEqual(emptyPath.downloadStatus, DownloadStatus.none)
    }

    func test_reconcileDownloadPaths_downloadedWithNilPath_isLeftAlone() async throws {
        // Documented, approved narrowing (#701). Reconciliation is now bounded by
        // `downloadPath != nil`, because `downloadStatus` is a Codable enum
        // SwiftData refuses in a #Predicate and the old whole-Episode-table fetch
        // was a launch watchdog kill at 241,979 rows. A row marked .downloaded
        // with NO path at all is the one case that drops out: it is already
        // internally inconsistent, both real purposes of this function (legacy
        // ABSOLUTE path rewriting, #575, and the file-gone reset) act only on
        // non-nil paths, and preserving it would require querying the enum —
        // which is impossible.
        let context = TestStore.freshContext()
        let nilPath = Episode(guid: "r3", title: "Nil path", audioURL: "https://h/a.mp3",
                              downloadStatus: .downloaded, downloadPath: nil)
        try persistLocalDownloadState(for: [nilPath], in: context)
        let manager = makeManager(context)

        await manager.reconcileDownloadPaths()

        XCTAssertNil(nilPath.downloadPath)
        XCTAssertEqual(nilPath.downloadStatus, .downloaded,
                       "Out of the bounded query's scope: left as-is, not reset")
    }

    func test_reconcileDownloadPaths_healthyBareNameRow_isUntouched() async throws {
        let context = TestStore.freshContext()
        let name = "earshot-test-healthy-\(UUID().uuidString).mp3"
        let fileURL = try plantDownloadFile(named: name)

        let episode = Episode(guid: "r5", title: "Healthy", audioURL: "https://h/a.mp3",
                              downloadStatus: .downloaded, downloadPath: name)
        try persistLocalDownloadState(for: [episode], in: context)
        let manager = makeManager(context)

        await manager.reconcileDownloadPaths()

        XCTAssertEqual(episode.downloadPath, name)
        XCTAssertEqual(episode.downloadStatus, .downloaded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func test_reconcileDownloadPaths_secondRun_makesZeroChanges() async throws {
        let context = TestStore.freshContext()
        let name = "earshot-test-idempotent-\(UUID().uuidString).mp3"
        let fileURL = try plantDownloadFile(named: name)
        let legacyPath = "/var/mobile/Containers/Data/Application/OLD-UUID/Documents/Downloads/\(name)"

        let healable = Episode(guid: "r6", title: "Healable", audioURL: "https://h/a.mp3",
                               downloadStatus: .downloaded, downloadPath: legacyPath)
        let missing = Episode(guid: "r7", title: "Gone", audioURL: "https://h/b.mp3",
                              downloadStatus: .downloaded,
                              downloadPath: "earshot-test-missing-\(UUID().uuidString).mp3")
        try persistLocalDownloadState(for: [healable, missing], in: context)
        let manager = makeManager(context)

        await manager.reconcileDownloadPaths()
        try context.save()

        let pathAfterFirst = healable.downloadPath
        let statusAfterFirst = healable.downloadStatus
        XCTAssertEqual(pathAfterFirst, name)
        XCTAssertEqual(statusAfterFirst, .downloaded)
        XCTAssertNil(missing.downloadPath)
        XCTAssertEqual(missing.downloadStatus, DownloadStatus.none)

        // Second pass over the healed store must be a no-op: no rewrites, no
        // resets, no dirty context.
        await manager.reconcileDownloadPaths()

        XCTAssertEqual(healable.downloadPath, pathAfterFirst)
        XCTAssertEqual(healable.downloadStatus, statusAfterFirst)
        XCTAssertNil(missing.downloadPath)
        XCTAssertEqual(missing.downloadStatus, DownloadStatus.none)
        XCTAssertFalse(context.hasChanges, "An idempotent second pass writes nothing")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testReconciliationPreservesFileCompletedDuringScan() async throws {
        let context = TestStore.freshContext()
        let name = "earshot-race-\(UUID().uuidString).mp3"
        let episode = Episode(guid: "race", title: "Race", audioURL: "https://h/a.mp3",
                              downloadStatus: .downloaded, downloadPath: name)
        try persistLocalDownloadState(for: [episode], in: context)
        let manager = makeManager(context)
        await manager.reconcileDownloadPaths { container in
            let corrections = try await DownloadPathReconciliation.scan(container: container)
            XCTAssertEqual(corrections.count, 1)
            _ = try self.plantDownloadFile(named: name)
            return corrections
        }
        XCTAssertEqual(episode.downloadPath, name)
        XCTAssertEqual(episode.downloadStatus, .downloaded)
    }

    func testReconciliationPreservesPathChangedDuringScan() async throws {
        let context = TestStore.freshContext()
        let episode = Episode(guid: "changed", title: "Changed", audioURL: "https://h/a.mp3",
                              downloadStatus: .downloaded, downloadPath: UUID().uuidString)
        try persistLocalDownloadState(for: [episode], in: context)
        let manager = makeManager(context)
        let newName = "earshot-new-\(UUID().uuidString).mp3"
        _ = try plantDownloadFile(named: newName)
        await manager.reconcileDownloadPaths { container in
            let corrections = try await DownloadPathReconciliation.scan(container: container)
            LocalStateStore.setDownloadPath(newName, on: episode, in: context)
            return corrections
        }
        XCTAssertEqual(episode.downloadPath, newName)
        XCTAssertEqual(episode.downloadStatus, .downloaded)
    }

    func testReconciliationPreservesTransferRestartedDuringScan() async throws {
        let context = TestStore.freshContext()
        let name = UUID().uuidString
        let episode = Episode(guid: "restarted", title: "Restarted", audioURL: "https://h/a.mp3",
                              downloadStatus: .downloaded, downloadPath: name)
        try persistLocalDownloadState(for: [episode], in: context)
        let manager = makeManager(context)
        await manager.reconcileDownloadPaths { container in
            let corrections = try await DownloadPathReconciliation.scan(container: container)
            XCTAssertEqual(corrections.count, 1)
            ActiveDownload.setDownloadStatus(.downloading, on: episode, in: context)
            return corrections
        }
        XCTAssertEqual(episode.downloadPath, name)
        XCTAssertEqual(episode.downloadStatus, .downloading)
    }

    func testReconciliationDoesNotApplyAfterPersistenceReleased() async throws {
        let context = TestStore.freshContext()
        let missing = UUID().uuidString
        let episode = Episode(guid: "released", title: "Released", audioURL: "https://h/a.mp3",
                              downloadStatus: .downloaded, downloadPath: missing)
        try persistLocalDownloadState(for: [episode], in: context)
        let manager = makeManager(context)
        await manager.reconcileDownloadPaths { container in
            let corrections = try await DownloadPathReconciliation.scan(container: container)
            await manager.releasePersistence()
            return corrections
        }
        XCTAssertEqual(episode.downloadPath, missing)
        XCTAssertEqual(episode.downloadStatus, .downloaded)
    }

    func testReconciliationRepairsMoreThanOneBatch() async throws {
        let context = TestStore.freshContext()
        let episodes = (0..<125).map { index in
            Episode(guid: "batch-\(index)", title: "Episode", audioURL: "https://h/a.mp3",
                    downloadStatus: .downloaded, downloadPath: "missing-\(UUID().uuidString).mp3")
        }
        try persistLocalDownloadState(for: episodes, in: context)
        let manager = makeManager(context)
        await manager.reconcileDownloadPaths()
        XCTAssertTrue(episodes.allSatisfy { $0.downloadPath == nil && $0.downloadStatus == .none })
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LocalEpisodeState>()), 0)
    }

    func testReconciliationCancellationLeavesStateUntouched() async throws {
        let context = TestStore.freshContext()
        let missing = UUID().uuidString
        let episode = Episode(guid: "cancelled", title: "Cancelled", audioURL: "https://h/a.mp3",
                              downloadStatus: .downloaded, downloadPath: missing)
        try persistLocalDownloadState(for: [episode], in: context)
        let manager = makeManager(context)
        let task = Task {
            await manager.reconcileDownloadPaths { container in
                let corrections = try await DownloadPathReconciliation.scan(container: container)
                withUnsafeCurrentTask { $0?.cancel() }
                return corrections
            }
        }
        await task.value
        XCTAssertEqual(episode.downloadPath, missing)
        XCTAssertEqual(episode.downloadStatus, .downloaded)
    }

    // MARK: downloadAndWait fast paths (#576)

    // Only the paths that return WITHOUT parking a continuation are testable
    // here: a parked waiter needs a real background-session terminal event (or
    // its 120s timeout), which needs a device transfer. The Wi-Fi-gated
    // `.pending` → false fast path is likewise not coverable in-process:
    // `isOnWifi` is private(set) and driven only by a live NWPathMonitor, and
    // the simulator host always reports Wi-Fi/wired, so there is no seam to
    // force the gate closed. The gating decision itself is pure and covered by
    // the DownloadGate tests in DownloadsInboxLogicTests.

    func test_downloadAndWait_alreadyDownloaded_returnsTrueImmediately() async {
        // Acceptance criterion: #576 — export must not park a waiter (and risk a
        // 120s stall) for audio that is already local.
        let context = TestStore.freshContext()
        let episode = Episode(guid: "w1", title: "Local", audioURL: "https://h/a.mp3",
                              downloadStatus: .downloaded, downloadPath: "a.mp3")
        context.insert(episode)
        let manager = makeManager(context)

        let result = await manager.downloadAndWait(episode)

        XCTAssertTrue(result)
        XCTAssertEqual(episode.downloadStatus, .downloaded)
        XCTAssertEqual(episode.downloadPath, "a.mp3", "The fast path must not touch state")
    }

    func test_downloadAndWait_failedToStart_returnsFalseWithoutWaiting() async {
        // Acceptance criterion: #576 — a download that can never produce a
        // terminal event (invalid URL → .failed at enqueue) must return false
        // immediately instead of parking a waiter until the timeout.
        let context = TestStore.freshContext()
        let episode = Episode(guid: "w2", title: "Bad URL", audioURL: "")
        context.insert(episode)
        let manager = makeManager(context)

        let start = Date()
        let result = await manager.downloadAndWait(episode)

        XCTAssertFalse(result)
        XCTAssertEqual(episode.downloadStatus, .failed)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5,
                          "Must return via the fast path, never the 120s timeout")
    }

    func testReconcileLeavesNonDownloadingEpisodesUntouched() async {
        let context = TestStore.freshContext()
        let done = Episode(guid: "d", title: "Done", audioURL: "https://h/d.mp3",
                           downloadStatus: .downloaded, downloadPath: "/tmp/d.mp3")
        let idle = Episode(guid: "i", title: "Idle", audioURL: "https://h/i.mp3",
                           downloadStatus: DownloadStatus.none)
        context.insert(done)
        context.insert(idle)
        let manager = makeManager(context)

        // No episode is marked .downloading, so reconcile short-circuits before it
        // would ever query the shared background session — nothing changes.
        await manager.reconcileStuckDownloads()

        XCTAssertEqual(done.downloadStatus, .downloaded)
        XCTAssertEqual(idle.downloadStatus, DownloadStatus.none)
    }
}

@MainActor
final class DownloadEventRetrierTests: XCTestCase {
    func testRetriesTransientErrorAndStopsAfterSuccess() async {
        let retrier = DownloadEventRetrier(delays: [.zero, .zero, .zero], sleep: { _ in await Task.yield() })
        let event = PendingDownloadTerminalEvent(taskKey: "episode", outcome: .failed)
        var attempts = 0
        retrier.submit(event) { _ in
            attempts += 1
            return attempts == 3
        }
        for _ in 0..<100 where attempts < 3 { await Task.yield() }
        XCTAssertEqual(attempts, 3)
        retrier.cancelAll()
    }

    func testCancellationStopsPendingRetriesAndAllowsReactivation() async {
        let retrier = DownloadEventRetrier(delays: [.seconds(30)])
        let event = PendingDownloadTerminalEvent(taskKey: "episode", outcome: .failed)
        var attempts = 0
        retrier.submit(event) { _ in attempts += 1; return false }
        await Task.yield()
        retrier.cancelAll()
        retrier.submit(event) { _ in attempts += 1; return true }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(attempts, 2)
        retrier.cancelAll()
    }

    func testRetryCountIsBoundedAndLeavesEventAvailableForLaterActivation() async {
        let retrier = DownloadEventRetrier(delays: [.zero, .zero], sleep: { _ in await Task.yield() })
        let event = PendingDownloadTerminalEvent(taskKey: "episode", outcome: .failed)
        var attempts = 0
        retrier.submit(event) { _ in attempts += 1; return false }
        for _ in 0..<100 where attempts < 3 { await Task.yield() }
        XCTAssertEqual(attempts, 3)
        await Task.yield()
        retrier.submit(event) { _ in attempts += 1; return true }
        XCTAssertEqual(attempts, 4)
        retrier.cancelAll()
    }

    func testReplayRequestedDuringRetriesIsResubmittedAfterTheyExhaust() async {
        let retrier = DownloadEventRetrier(delays: [.zero], sleep: { _ in await Task.yield() })
        let event = PendingDownloadTerminalEvent(taskKey: "episode", outcome: .failed)
        var attempts = 0
        let handle: @MainActor (PendingDownloadTerminalEvent) -> Bool = { _ in
            attempts += 1
            return attempts == 3
        }
        retrier.submit(event, handle: handle)
        retrier.submit(event, handle: handle)
        for _ in 0..<100 where attempts < 3 { await Task.yield() }
        XCTAssertEqual(attempts, 3)
        retrier.cancelAll()
    }

    func testRecoveredJournalResubmitsAfterEarlierRetriesExhausted() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("journal-replay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let reader = JournalReadProbe()
        let journal = DownloadEventJournal(url: directory.appendingPathComponent("events.json"), read: reader.read)
        let event = journal.record(taskKey: "live", outcome: .failed)
        let gate = JournalRetryGate()
        let retryStarted = expectation(description: "journal retry waiting")
        let exhausted = expectation(description: "earlier acknowledgement retries exhausted")
        let recovered = expectation(description: "event acknowledged after recovery")
        let delegate = DownloadSessionDelegate(journal: journal, retryDelays: [.zero]) { _ in
            retryStarted.fulfill()
            await gate.wait()
        }
        let retrier = DownloadEventRetrier(delays: [.zero], sleep: { _ in await Task.yield() })
        let attempts = JournalAttemptProbe()
        delegate.installTerminalHandler { event, generation in
            Task { @MainActor in
                guard delegate.isCurrentNormalHandler(generation) else { return }
                DownloadManager.submitJournalEvent(event, delegate: delegate, retrier: retrier) { event in
                    attempts.count += 1
                    let acknowledged = journal.acknowledge(event.id)
                    if attempts.count == 2 { exhausted.fulfill() }
                    if acknowledged { recovered.fulfill() }
                    return acknowledged
                }
            }
        }
        await fulfillment(of: [retryStarted, exhausted], timeout: 3)
        reader.allowReads()
        await gate.release()
        await fulfillment(of: [recovered], timeout: 3)
        XCTAssertEqual(attempts.count, 3)
        XCTAssertTrue(journal.pendingEvents().isEmpty)

        // A stale replay snapshot must not apply an acknowledged event again.
        DownloadManager.submitJournalEvent(event, delegate: delegate, retrier: retrier) { _ in
            attempts.count += 1
            return true
        }
        XCTAssertEqual(attempts.count, 3)
        retrier.cancelAll()
    }
}

private enum DownloadEventTestError: Error { case injected }

private actor DownloadCompletionNotificationCenter: @preconcurrency NotificationScheduling {
    struct RequestSnapshot: Sendable {
        let title: String
        let body: String
        let categoryIdentifier: String
        let episodeGUID: String?
    }

    private var addedRequests: [UNNotificationRequest] = []

    func authorizationStatus() async -> UNAuthorizationStatus { .authorized }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool { true }

    func setNotificationCategories(_ categories: Set<UNNotificationCategory>) async {}

    func add(_ request: UNNotificationRequest) async throws {
        addedRequests.append(request)
    }

    func addedRequestCount() -> Int { addedRequests.count }

    func addedRequestSnapshots() -> [RequestSnapshot] {
        addedRequests.map {
            RequestSnapshot(
                title: $0.content.title,
                body: $0.content.body,
                categoryIdentifier: $0.content.categoryIdentifier,
                episodeGUID: $0.content.userInfo[NotificationService.episodeGUIDKey] as? String
            )
        }
    }
}

/// The URL-session delegate can run before the launch coordinator has a store.
/// These tests keep its compact terminal-event journal restartable without
/// creating a real background transfer.
final class DownloadEventJournalTests: XCTestCase {
    nonisolated(unsafe) private var directory: URL!
    nonisolated(unsafe) private var journalURL: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "download-event-journal-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        journalURL = directory.appendingPathComponent("events.json")
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testEventsPersistAcrossJournalRecreationUntilAcknowledged() {
        let journal = DownloadEventJournal(url: journalURL)
        let finished = journal.record(
            taskKey: "feed|episode-1",
            outcome: .finished(fileName: "episode-1.mp3")
        )
        let failed = journal.record(
            taskKey: "feed|episode-2", outcome: .failed
        )

        XCTAssertEqual(
            DownloadEventJournal(url: journalURL).pendingEvents(),
            [finished, failed]
        )

        journal.acknowledge(finished.id)
        XCTAssertEqual(
            DownloadEventJournal(url: journalURL).pendingEvents(), [failed]
        )

        journal.acknowledge(failed.id)
        XCTAssertTrue(
            DownloadEventJournal(url: journalURL).pendingEvents().isEmpty
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
    }

    func testPersistedJournalIncludesFormatVersion() throws {
        let journal = DownloadEventJournal(url: journalURL)
        journal.record(taskKey: "feed|episode", outcome: .failed)

        let data = try Data(contentsOf: journalURL)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertNotNil(object["events"] as? [Any])
    }

    func testAcknowledgementSucceedsWhenJournalWasAlreadyRemoved() throws {
        let journal = DownloadEventJournal(url: journalURL)
        let event = journal.record(taskKey: "feed|episode", outcome: .failed)
        try FileManager.default.removeItem(at: journalURL)
        XCTAssertTrue(journal.acknowledge(event.id))
        XCTAssertTrue(journal.pendingEvents().isEmpty)
    }

    func testUnsupportedJournalVersionDoesNotDecodeEvents() throws {
        let journal = DownloadEventJournal(url: journalURL)
        journal.record(taskKey: "feed|episode", outcome: .failed)

        let data = try Data(contentsOf: journalURL)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object["version"] = 2
        try JSONSerialization.data(withJSONObject: object).write(
            to: journalURL,
            options: .atomic
        )

        XCTAssertTrue(
            DownloadEventJournal(url: journalURL).pendingEvents().isEmpty
        )
    }

    func testMalformedCurrentJournalVersionDoesNotDecodeEvents() throws {
        let malformed = Data(
            #"{"version":1,"events":"not-an-event-array"}"#.utf8
        )
        try malformed.write(to: journalURL, options: .atomic)

        XCTAssertTrue(
            DownloadEventJournal(url: journalURL).pendingEvents().isEmpty
        )
    }

    func testUnreadableAndUnsupportedJournalsAreNeverOverwritten() throws {
        for original in [Data(#"{"version":1,"events":"broken"}"#.utf8),
                         Data(#"{"version":99,"events":[]}"#.utf8)] {
            try original.write(to: journalURL, options: .atomic)
            let journal = DownloadEventJournal(url: journalURL)
            let event = journal.record(taskKey: "feed|episode", outcome: .failed)
            XCTAssertEqual(journal.pendingEvents(), [event])
            XCTAssertEqual(try Data(contentsOf: journalURL), original)
            XCTAssertFalse(journal.acknowledge(event.id))
            XCTAssertThrowsError(try journal.acknowledgeAllForRecovery())
            XCTAssertEqual(journal.pendingEvents(), [event])
            XCTAssertEqual(try Data(contentsOf: journalURL), original)
        }
    }

    func testUnreadableJournalPathDoesNotGetTreatedAsMissing() throws {
        try FileManager.default.createDirectory(at: journalURL, withIntermediateDirectories: true)
        let marker = journalURL.appendingPathComponent("preserve")
        try Data("original".utf8).write(to: marker)
        let journal = DownloadEventJournal(url: journalURL)
        let event = journal.record(taskKey: "feed|episode", outcome: .failed)
        XCTAssertFalse(journal.acknowledge(event.id))
        XCTAssertThrowsError(try journal.acknowledgeAllForRecovery())
        XCTAssertEqual(try Data(contentsOf: marker), Data("original".utf8))
        XCTAssertEqual(journal.pendingEvents(), [event])
    }

    func testDelegateDistinguishesUnreadableJournalFromEmptyJournal() throws {
        let original = Data(#"{"version":99,"events":[]}"#.utf8)
        try original.write(to: journalURL)
        let delegate = DownloadSessionDelegate(journal: DownloadEventJournal(url: journalURL))
        XCTAssertNil(delegate.pendingTaskKeys())
        XCTAssertEqual(try Data(contentsOf: journalURL), original)

        // A missing journal is a known empty journal, so orphan cleanup can run.
        try FileManager.default.removeItem(at: journalURL)
        XCTAssertEqual(delegate.pendingTaskKeys(), [])
    }

    func testPermissionFailureRetainsJournalUntilItBecomesReadable() throws {
        let originalJournal = DownloadEventJournal(url: journalURL)
        let oldEvent = originalJournal.record(taskKey: "old", outcome: .failed)
        let original = try Data(contentsOf: journalURL)
        let reader = JournalReadProbe()
        let journal = DownloadEventJournal(url: journalURL, read: reader.read)
        let newEvent = journal.record(taskKey: "new", outcome: .failed)
        XCTAssertNil(journal.pendingEventsIfReadable())
        XCTAssertFalse(journal.acknowledge(newEvent.id))
        XCTAssertEqual(try Data(contentsOf: journalURL), original)
        XCTAssertEqual(journal.pendingEvents(), [newEvent])

        reader.allowReads()
        XCTAssertEqual(journal.pendingEventsIfReadable(), [oldEvent, newEvent])
        XCTAssertEqual(journal.pendingEvents(), [oldEvent, newEvent])
        XCTAssertTrue(journal.acknowledge(newEvent.id))
        XCTAssertEqual(DownloadEventJournal(url: journalURL).pendingEvents(), [oldEvent])
    }

    func testFailedRecordWriteRetainsEventAndLaterWritePersistsBoth() {
        let writer = JournalWriteProbe()
        let journal = DownloadEventJournal(url: journalURL, write: writer.write)
        writer.failNext()
        let first = journal.record(taskKey: "feed|first", outcome: .failed)
        XCTAssertEqual(journal.pendingEvents(), [first])
        XCTAssertTrue(DownloadEventJournal(url: journalURL).pendingEvents().isEmpty,
                      "A failed write cannot survive process death")
        let second = journal.record(taskKey: "feed|second", outcome: .failed)
        XCTAssertEqual(DownloadEventJournal(url: journalURL).pendingEvents(), [first, second])
    }

    func testPreviouslyUnreadableJournalCanBeLoadedWithoutLosingNewEvent() throws {
        try Data("unreadable".utf8).write(to: journalURL)
        let journal = DownloadEventJournal(url: journalURL)
        let newEvent = journal.record(taskKey: "new", outcome: .failed)

        let replacementURL = directory.appendingPathComponent("replacement.json")
        let replacement = DownloadEventJournal(url: replacementURL)
        let oldEvent = replacement.record(taskKey: "old", outcome: .failed)
        try Data(contentsOf: replacementURL).write(to: journalURL, options: .atomic)

        XCTAssertTrue(journal.acknowledge(newEvent.id))
        XCTAssertEqual(journal.pendingEvents(), [oldEvent])
        XCTAssertEqual(DownloadEventJournal(url: journalURL).pendingEvents(), [oldEvent])
    }

    func testRecoveryHandlerDoesNotQueuePersistedEventReplay() {
        let journal = DownloadEventJournal(url: journalURL)
        journal.record(taskKey: "feed|episode", outcome: .failed)
        let delegate = DownloadSessionDelegate(journal: journal)
        nonisolated(unsafe) var handled = 0

        delegate.installTerminalHandler(replayingPendingEvents: false) { _, _ in
            handled += 1
        }

        XCTAssertEqual(handled, 0)
        XCTAssertEqual(journal.pendingEvents().count, 1)
    }

    func testDelayedReadableJournalReplaysEvenIfAnotherReaderLoadsIt() async throws {
        let persisted = DownloadEventJournal(url: journalURL)
        let oldEvent = persisted.record(taskKey: "old", outcome: .failed)
        let reader = JournalReadProbe()
        let journal = DownloadEventJournal(url: journalURL, read: reader.read)
        let liveEvent = journal.record(taskKey: "live", outcome: .failed)
        let delivered = JournalDeliveryProbe()
        let replayed = expectation(description: "previously unreadable event replayed")
        let delegate = DownloadSessionDelegate(journal: journal, retryDelays: [.zero]) { _ in
            reader.allowReads()
            // Reconciliation can load the journal before the retry's own read.
            _ = journal.pendingEventsIfReadable()
        }
        delegate.installTerminalHandler { event, _ in
            delivered.record(event)
            if event.id == oldEvent.id { replayed.fulfill() }
        }
        await fulfillment(of: [replayed], timeout: 2)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(delivered.events, [liveEvent, oldEvent, liveEvent])
        XCTAssertEqual(journal.pendingEvents(), [oldEvent, liveEvent])
    }

    func testForegroundRetryCanReadJournalAfterInitialRetryWindow() async throws {
        let persisted = DownloadEventJournal(url: journalURL)
        let oldEvent = persisted.record(taskKey: "old", outcome: .failed)
        let reader = JournalReadProbe()
        let journal = DownloadEventJournal(url: journalURL, read: reader.read)
        let delivered = expectation(description: "event recovered on foreground retry")
        let delegate = DownloadSessionDelegate(journal: journal, retryDelays: [])
        delegate.installTerminalHandler { event, _ in
            if event.id == oldEvent.id { delivered.fulfill() }
        }
        for _ in 0..<100 where delegate.replayInProgressForTesting() {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(delegate.replayInProgressForTesting())
        reader.allowReads()
        delegate.retryPendingEvents()
        await fulfillment(of: [delivered], timeout: 2)
    }

    func testRecoveryHandlerReplacementCancelsDelayedReplay() async throws {
        let persisted = DownloadEventJournal(url: journalURL)
        _ = persisted.record(taskKey: "old", outcome: .failed)
        let reader = JournalReadProbe()
        let journal = DownloadEventJournal(url: journalURL, read: reader.read)
        let started = expectation(description: "retry started")
        let unexpected = expectation(description: "old handler must not receive replay")
        unexpected.isInverted = true
        let gate = JournalRetryGate()
        let delegate = DownloadSessionDelegate(journal: journal, retryDelays: [.zero]) { _ in
            started.fulfill()
            await gate.wait()
        }
        delegate.installTerminalHandler { _, _ in unexpected.fulfill() }
        await fulfillment(of: [started], timeout: 2)
        delegate.installRecoverySuppressionHandler()
        reader.allowReads()
        await gate.release()
        await fulfillment(of: [unexpected], timeout: 0.2)
        XCTAssertEqual(journal.pendingEvents().count, 1)
    }

    func testReplayDeliversEveryEventAcrossMultipleBatches() async {
        let journal = DownloadEventJournal(url: journalURL)
        let events = (0..<40).map { journal.record(taskKey: "episode-\($0)", outcome: .failed) }
        let delivered = JournalDeliveryProbe()
        let replayed = expectation(description: "all pending events delivered")
        replayed.expectedFulfillmentCount = events.count
        let delegate = DownloadSessionDelegate(journal: journal)
        delegate.installTerminalHandler { event, _ in
            delivered.record(event)
            replayed.fulfill()
        }
        await fulfillment(of: [replayed], timeout: 3)
        XCTAssertEqual(delivered.events, events)
    }

    func testReplayWaitsForEachDeliveryBeforeSchedulingTheNext() async throws {
        let journal = DownloadEventJournal(url: journalURL)
        let first = journal.record(taskKey: "one", outcome: .failed)
        let second = journal.record(taskKey: "two", outcome: .failed)
        let gate = JournalRetryGate()
        let started = expectation(description: "first delivery started")
        let completed = expectation(description: "both deliveries completed")
        completed.expectedFulfillmentCount = 2
        let delivered = JournalDeliveryProbe()
        let delegate = DownloadSessionDelegate(journal: journal)
        delegate.installTerminalHandler(replayHandler: { event, _ in
            delivered.record(event)
            if event.id == first.id {
                started.fulfill()
                await gate.wait()
            }
            completed.fulfill()
        }) { _, _ in XCTFail("Replay should use the awaited delivery") }
        await fulfillment(of: [started], timeout: 2)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(delivered.events, [first])
        await gate.release()
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(delivered.events, [first, second])
    }
}

@MainActor
private final class JournalAttemptProbe { var count = 0 }

private final class JournalDeliveryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [PendingDownloadTerminalEvent] = []
    var events: [PendingDownloadTerminalEvent] { lock.withLock { values } }
    func record(_ value: PendingDownloadTerminalEvent) { lock.withLock { values.append(value) } }
}

private actor JournalRetryGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private final class JournalWriteProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldFail = false

    func failNext() { lock.withLock { shouldFail = true } }

    func write(_ url: URL, _ data: Data?) throws {
        let fail = lock.withLock {
            defer { shouldFail = false }
            return shouldFail
        }
        if fail { throw DownloadEventTestError.injected }
        guard let data else {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

private final class JournalReadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var blocked = true

    func allowReads() { lock.withLock { blocked = false } }

    func read(_ url: URL) throws -> Data {
        if lock.withLock({ blocked }) { throw CocoaError(.fileReadNoPermission) }
        return try Data(contentsOf: url)
    }
}

/// Keeps transfers active without network access until the test cancels them.
private final class CleanupHoldingURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
}
