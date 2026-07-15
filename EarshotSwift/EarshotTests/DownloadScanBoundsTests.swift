import XCTest
import SwiftData
@testable import Earshot

/// The three launch-path scans must find exactly the right rows now that they are
/// bounded (#701).
///
/// `DownloadManager` used to fetch the ENTIRE `Episode` table on the main actor at
/// three points on the launch path and filter in memory. On a real 241,979-row
/// library that is a scene-create watchdog kill (0x8BADF00D). The scans now query
/// the tiny `ActiveDownload` table (pending / downloading) or a bounded
/// `downloadPath != nil` predicate (path healing). These tests pin down that the
/// narrower queries still select the same rows the in-memory filters used to.
@MainActor
final class DownloadScanBoundsTests: XCTestCase {

    private func makeManager(_ context: ModelContext) -> DownloadManager {
        let manager = DownloadManager()
        manager.configure(context: context)
        return manager
    }

    /// An episode with an EMPTY audioURL: the Wi-Fi gate passes on the simulator
    /// host, `URL(string: "")` is nil, so `download(_:)` takes the invalid-URL
    /// branch and marks it `.failed` WITHOUT enqueuing a real background transfer.
    /// That makes "the scan reached this episode" observable in-process.
    private func makeUnstartableEpisode(_ context: ModelContext, guid: String) -> Episode {
        let podcast = Podcast(feedURL: "https://ex.com/\(guid).xml", title: "Show \(guid)")
        context.insert(podcast)
        let episode = Episode(guid: guid, title: "Ep \(guid)", audioURL: "")
        episode.podcast = podcast
        context.insert(episode)
        return episode
    }

    private func rows(in context: ModelContext) -> [ActiveDownload] {
        (try? context.fetch(FetchDescriptor<ActiveDownload>())) ?? []
    }

    // MARK: startPendingDownloads

    /// The pending scan must reach an episode parked by the Wi-Fi gate, and must
    /// NOT reach episodes in any other state.
    func test_startPendingDownloads_startsOnlyPendingEpisodes() async throws {
        let context = TestStore.freshContext()
        let pending = makeUnstartableEpisode(context, guid: "sp-pending")
        let idle = makeUnstartableEpisode(context, guid: "sp-idle")
        let done = makeUnstartableEpisode(context, guid: "sp-done")
        try context.save()

        // Only `pending` gets an ActiveDownload row, via the production writer.
        ActiveDownload.setDownloadStatus(.pending, on: pending, in: context)
        ActiveDownload.setDownloadStatus(.downloaded, on: done, in: context)
        try context.save()
        XCTAssertEqual(rows(in: context).count, 1, "only the pending episode is tracked")

        let manager = makeManager(context)
        await manager.startPendingDownloads()

        // The pending episode was picked up and driven through download(_:),
        // which failed on its invalid URL — proof the scan found it.
        XCTAssertEqual(pending.downloadStatus, .failed, "the pending row was started")
        XCTAssertEqual(idle.downloadStatus, DownloadStatus.none, "untracked row untouched")
        XCTAssertEqual(done.downloadStatus, .downloaded, "downloaded row untouched")

        // .failed is terminal, so the row is gone: the invariant held throughout.
        XCTAssertTrue(rows(in: context).isEmpty)
    }

    /// No pending rows: the scan short-circuits and touches nothing.
    func test_startPendingDownloads_withNoPendingRows_isANoOp() async throws {
        let context = TestStore.freshContext()
        let done = makeUnstartableEpisode(context, guid: "sp-none")
        try context.save()
        ActiveDownload.setDownloadStatus(.downloaded, on: done, in: context)
        try context.save()

        let manager = makeManager(context)
        await manager.startPendingDownloads()

        XCTAssertEqual(done.downloadStatus, .downloaded)
        XCTAssertTrue(rows(in: context).isEmpty)
    }

    // MARK: reconcileStuckDownloads

    /// An episode left at `.downloading` by a kill mid-transfer has an
    /// ActiveDownload row and no live background task, so it is orphaned: it must
    /// be reset to `.failed` AND lose its row.
    func test_reconcileStuckDownloads_orphanedRow_failsEpisodeAndDropsRow() async throws {
        let context = TestStore.freshContext()
        let stuck = makeUnstartableEpisode(context, guid: "rs-stuck")
        try context.save()

        // Simulate the pre-kill state: .downloading with a tracking row, but no
        // task was ever enqueued on the shared session, so liveTaskKeys() is empty
        // and this row is an orphan.
        ActiveDownload.setDownloadStatus(.downloading, on: stuck, in: context)
        try context.save()
        XCTAssertEqual(rows(in: context).count, 1)

        let manager = makeManager(context)
        await manager.reconcileStuckDownloads()

        XCTAssertEqual(stuck.downloadStatus, .failed,
                       "an orphaned .downloading episode must not hang forever (#544)")
        XCTAssertTrue(rows(in: context).isEmpty,
                      "the row must go with the terminal state")
    }

    /// Episodes NOT tracked as downloading are invisible to the scan, whatever
    /// their downloadStatus says.
    func test_reconcileStuckDownloads_ignoresUntrackedEpisodes() async throws {
        let context = TestStore.freshContext()
        let done = makeUnstartableEpisode(context, guid: "rs-done")
        let idle = makeUnstartableEpisode(context, guid: "rs-idle")
        let pending = makeUnstartableEpisode(context, guid: "rs-pending")
        try context.save()

        ActiveDownload.setDownloadStatus(.downloaded, on: done, in: context)
        ActiveDownload.setDownloadStatus(.pending, on: pending, in: context)
        try context.save()

        let manager = makeManager(context)
        await manager.reconcileStuckDownloads()

        XCTAssertEqual(done.downloadStatus, .downloaded)
        XCTAssertEqual(idle.downloadStatus, DownloadStatus.none)
        XCTAssertEqual(pending.downloadStatus, .pending,
                       "a Wi-Fi-gated episode is not a stuck download")
        XCTAssertEqual(rows(in: context).count, 1, "the pending row survives")
    }

    // MARK: reconcileDownloadPaths

    /// The `downloadPath != nil` predicate must select every row that has a path
    /// and skip those that do not — the bounded replacement for the whole-table
    /// fetch.
    func test_reconcileDownloadPaths_selectsEveryNonNilPathRow() async throws {
        let context = TestStore.freshContext()

        // Two rows WITH paths, both pointing at files that do not exist, so the
        // reset branch fires and proves each was visited.
        let missingA = Episode(guid: "rp-a", title: "A", audioURL: "https://h/a.mp3",
                               downloadStatus: .downloaded,
                               downloadPath: "earshot-test-absent-a-\(UUID().uuidString).mp3")
        let missingB = Episode(guid: "rp-b", title: "B", audioURL: "https://h/b.mp3",
                               downloadStatus: .downloaded,
                               downloadPath: "earshot-test-absent-b-\(UUID().uuidString).mp3")
        // A row with NO path is out of the query's scope entirely.
        let noPath = Episode(guid: "rp-c", title: "C", audioURL: "https://h/c.mp3",
                             downloadStatus: DownloadStatus.none, downloadPath: nil)
        context.insert(missingA)
        context.insert(missingB)
        context.insert(noPath)
        let manager = makeManager(context)

        await manager.reconcileDownloadPaths()

        XCTAssertEqual(missingA.downloadStatus, DownloadStatus.none)
        XCTAssertNil(missingA.downloadPath)
        XCTAssertEqual(missingB.downloadStatus, DownloadStatus.none)
        XCTAssertNil(missingB.downloadPath)
        XCTAssertEqual(noPath.downloadStatus, DownloadStatus.none, "never had a path; unchanged")
    }

    /// A path row that also carries an ActiveDownload row (a download that
    /// finished writing its path but was still tracked) loses the row when the
    /// reset drives it terminal.
    func test_reconcileDownloadPaths_resetDropsAnyActiveDownloadRow() async throws {
        let context = TestStore.freshContext()
        let episode = makeUnstartableEpisode(context, guid: "rp-tracked")
        episode.downloadPath = "earshot-test-absent-\(UUID().uuidString).mp3"
        try context.save()
        ActiveDownload.setDownloadStatus(.downloading, on: episode, in: context)
        try context.save()
        XCTAssertEqual(rows(in: context).count, 1)

        let manager = makeManager(context)
        await manager.reconcileDownloadPaths()

        XCTAssertEqual(episode.downloadStatus, DownloadStatus.none)
        XCTAssertTrue(rows(in: context).isEmpty,
                      "the reset is terminal, so the tracking row must go too")
    }
}
