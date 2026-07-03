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
        // A real temp file so we can assert it is actually removed.
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("earshot-test-\(UUID().uuidString).mp3")
        try Data("audio".utf8).write(to: fileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        let episode = Episode(guid: "g3", title: "Downloaded", audioURL: "https://h/a.mp3",
                              downloadStatus: .downloaded, downloadPath: fileURL.path)
        context.insert(episode)
        let manager = makeManager(context)

        manager.removeDownload(episode)

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertNil(episode.downloadPath)
        XCTAssertEqual(episode.downloadStatus, DownloadStatus.none)
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
