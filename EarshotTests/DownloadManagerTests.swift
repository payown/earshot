import XCTest
import SwiftData
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
        context.insert(a)
        context.insert(b)
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
        context.insert(episode)
        let manager = makeManager(context)

        let removed = await manager.clearAllDownloads()

        XCTAssertEqual(removed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path),
                       "The real file at the resolved location must be deleted")
        XCTAssertNil(episode.downloadPath)
        XCTAssertEqual(episode.downloadStatus, DownloadStatus.none)
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
        context.insert(episode)
        let manager = makeManager(context)

        await manager.reconcileDownloadPaths()

        XCTAssertEqual(episode.downloadPath, name, "Legacy absolute path is rewritten to the bare file name")
        XCTAssertEqual(episode.downloadStatus, .downloaded, "Status is kept when the file exists")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path), "Healing never deletes the file")
    }

    func test_reconcileDownloadPaths_downloadedWithMissingFile_resetsToNone() async {
        let context = TestStore.freshContext()
        let episode = Episode(guid: "r2", title: "Gone", audioURL: "https://h/a.mp3",
                              downloadStatus: .downloaded,
                              downloadPath: "earshot-test-definitely-missing-\(UUID().uuidString).mp3")
        context.insert(episode)
        let manager = makeManager(context)

        await manager.reconcileDownloadPaths()

        XCTAssertNil(episode.downloadPath)
        XCTAssertEqual(episode.downloadStatus, DownloadStatus.none,
                       "A downloaded row whose file is gone becomes re-downloadable")
    }

    func test_reconcileDownloadPaths_downloadedWithEmptyPath_resetsToNone() async {
        // An empty-string path is still non-nil, so the bounded
        // `downloadPath != nil` query (#701) still finds it and the reset branch
        // still fires.
        let context = TestStore.freshContext()
        let emptyPath = Episode(guid: "r4", title: "Empty path", audioURL: "https://h/b.mp3",
                                downloadStatus: .downloaded, downloadPath: "")
        context.insert(emptyPath)
        let manager = makeManager(context)

        await manager.reconcileDownloadPaths()

        XCTAssertNil(emptyPath.downloadPath)
        XCTAssertEqual(emptyPath.downloadStatus, DownloadStatus.none)
    }

    func test_reconcileDownloadPaths_downloadedWithNilPath_isLeftAlone() async {
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
        context.insert(nilPath)
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
        context.insert(episode)
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
        context.insert(healable)
        context.insert(missing)
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
}
