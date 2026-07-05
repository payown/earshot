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

    // MARK: reconcileDownloadPaths (#575)

    // Acceptance criterion: launch reconciliation rewrites legacy absolute
    // values to bare names when the file exists, resets rows whose file is
    // gone, and is idempotent.

    func test_reconcileDownloadPaths_legacyAbsolutePathWithRealFile_rewritesToBareNameKeepsStatus() throws {
        let context = TestStore.freshContext()
        let name = "earshot-test-reconcile-\(UUID().uuidString).mp3"
        let fileURL = try plantDownloadFile(named: name)
        let legacyPath = "/var/mobile/Containers/Data/Application/OLD-UUID/Documents/Downloads/\(name)"

        let episode = Episode(guid: "r1", title: "Healable", audioURL: "https://h/a.mp3",
                              downloadStatus: .downloaded, downloadPath: legacyPath)
        context.insert(episode)
        let manager = makeManager(context)

        manager.reconcileDownloadPaths()

        XCTAssertEqual(episode.downloadPath, name, "Legacy absolute path is rewritten to the bare file name")
        XCTAssertEqual(episode.downloadStatus, .downloaded, "Status is kept when the file exists")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path), "Healing never deletes the file")
    }

    func test_reconcileDownloadPaths_downloadedWithMissingFile_resetsToNone() {
        let context = TestStore.freshContext()
        let episode = Episode(guid: "r2", title: "Gone", audioURL: "https://h/a.mp3",
                              downloadStatus: .downloaded,
                              downloadPath: "earshot-test-definitely-missing-\(UUID().uuidString).mp3")
        context.insert(episode)
        let manager = makeManager(context)

        manager.reconcileDownloadPaths()

        XCTAssertNil(episode.downloadPath)
        XCTAssertEqual(episode.downloadStatus, DownloadStatus.none,
                       "A downloaded row whose file is gone becomes re-downloadable")
    }

    func test_reconcileDownloadPaths_downloadedWithNilOrEmptyPath_resetsToNone() {
        let context = TestStore.freshContext()
        let nilPath = Episode(guid: "r3", title: "Nil path", audioURL: "https://h/a.mp3",
                              downloadStatus: .downloaded, downloadPath: nil)
        let emptyPath = Episode(guid: "r4", title: "Empty path", audioURL: "https://h/b.mp3",
                                downloadStatus: .downloaded, downloadPath: "")
        context.insert(nilPath)
        context.insert(emptyPath)
        let manager = makeManager(context)

        manager.reconcileDownloadPaths()

        XCTAssertNil(nilPath.downloadPath)
        XCTAssertEqual(nilPath.downloadStatus, DownloadStatus.none)
        XCTAssertNil(emptyPath.downloadPath)
        XCTAssertEqual(emptyPath.downloadStatus, DownloadStatus.none)
    }

    func test_reconcileDownloadPaths_healthyBareNameRow_isUntouched() throws {
        let context = TestStore.freshContext()
        let name = "earshot-test-healthy-\(UUID().uuidString).mp3"
        let fileURL = try plantDownloadFile(named: name)

        let episode = Episode(guid: "r5", title: "Healthy", audioURL: "https://h/a.mp3",
                              downloadStatus: .downloaded, downloadPath: name)
        context.insert(episode)
        let manager = makeManager(context)

        manager.reconcileDownloadPaths()

        XCTAssertEqual(episode.downloadPath, name)
        XCTAssertEqual(episode.downloadStatus, .downloaded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func test_reconcileDownloadPaths_secondRun_makesZeroChanges() throws {
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

        manager.reconcileDownloadPaths()
        try context.save()

        let pathAfterFirst = healable.downloadPath
        let statusAfterFirst = healable.downloadStatus
        XCTAssertEqual(pathAfterFirst, name)
        XCTAssertEqual(statusAfterFirst, .downloaded)
        XCTAssertNil(missing.downloadPath)
        XCTAssertEqual(missing.downloadStatus, DownloadStatus.none)

        // Second pass over the healed store must be a no-op: no rewrites, no
        // resets, no dirty context.
        manager.reconcileDownloadPaths()

        XCTAssertEqual(healable.downloadPath, pathAfterFirst)
        XCTAssertEqual(healable.downloadStatus, statusAfterFirst)
        XCTAssertNil(missing.downloadPath)
        XCTAssertEqual(missing.downloadStatus, DownloadStatus.none)
        XCTAssertFalse(context.hasChanges, "An idempotent second pass writes nothing")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
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
