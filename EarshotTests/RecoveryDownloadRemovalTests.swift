import SwiftData
import XCTest
@testable import Earshot

@MainActor
final class RecoveryDownloadRemovalTests: XCTestCase {
    nonisolated(unsafe) private var directory: URL!
    nonisolated(unsafe) private var markerURL: URL!
    nonisolated(unsafe) private var journalURL: URL!
    nonisolated(unsafe) private var downloadFileURL: URL?

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "RecoveryDownloadRemoval-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        markerURL = directory.appending(path: "pending.json")
        journalURL = directory.appending(path: "events.json")
        RecoveryDownloadRemoval.injectedFailurePoint = nil
        try? RecoveryDownloadRemoval.finish()
    }

    override func tearDownWithError() throws {
        RecoveryDownloadRemoval.injectedFailurePoint = nil
        try? RecoveryDownloadRemoval.finish()
        if let downloadFileURL { try? FileManager.default.removeItem(at: downloadFileURL) }
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testMarkerIsDurableBeforeInjectedCancellationBoundary() throws {
        RecoveryDownloadRemoval.injectedFailurePoint = .afterMarkerCreation

        XCTAssertThrowsError(try RecoveryDownloadRemoval.begin(at: markerURL)) { error in
            XCTAssertEqual(
                error as? RecoveryDownloadRemoval.InjectedFailure,
                .init(point: .afterMarkerCreation)
            )
        }
        XCTAssertTrue(RecoveryDownloadRemoval.isPending(at: markerURL))

        RecoveryDownloadRemoval.injectedFailurePoint = nil
        try RecoveryDownloadRemoval.finish(at: markerURL)
        XCTAssertFalse(RecoveryDownloadRemoval.isPending(at: markerURL))
    }

    func testPartialSweepReportsOnlyActuallyFreedAllocatedBytes() throws {
        let removed = directory.appending(path: "removed.mp3")
        let retained = directory.appending(path: "retained.mp3")
        try Data(repeating: 0xA5, count: 2_000_000).write(to: removed)
        try Data(repeating: 0x5A, count: 3_000_000).write(to: retained)
        let before = RecoveryDownloadRemoval.allocatedBytes(in: directory)

        let result = RecoveryDownloadRemoval.removeContents(of: directory) { url in
            if url.lastPathComponent == retained.lastPathComponent {
                throw CocoaError(.fileWriteNoPermission)
            }
            try FileManager.default.removeItem(at: url)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: removed.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path))
        XCTAssertEqual(result.failedItemCount, 1)
        XCTAssertEqual(result.remainingBytes, RecoveryDownloadRemoval.allocatedBytes(in: directory))
        XCTAssertEqual(result.freedBytes, before - result.remainingBytes)
        XCTAssertGreaterThan(result.freedBytes, 0)
    }

    func testTerminalFinishedEventCannotRecreateAudioWhileMarkerExists() throws {
        let fileName = "late-recovery-\(UUID().uuidString).mp3"
        let fileURL = try DownloadPaths.downloadsDirectory().appending(path: fileName)
        downloadFileURL = fileURL
        try Data(repeating: 7, count: 128).write(to: fileURL)
        try RecoveryDownloadRemoval.begin()
        defer { try? RecoveryDownloadRemoval.finish() }

        DownloadManager.handle(PendingDownloadTerminalEvent(
            taskKey: "https://example.com/feed|episode",
            outcome: .finished(fileName: fileName)
        ))

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertTrue(RecoveryDownloadRemoval.isPending)
    }

    func testForceQuitAfterFileDeletionLeavesMarkerForRetry() throws {
        let downloads = directory.appending(path: "Downloads", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let file = downloads.appending(path: "episode.mp3")
        try Data(repeating: 3, count: 128).write(to: file)
        try RecoveryDownloadRemoval.begin(at: markerURL)
        _ = RecoveryDownloadRemoval.removeContents(of: downloads)
        RecoveryDownloadRemoval.injectedFailurePoint = .afterFileDeletion

        XCTAssertThrowsError(try RecoveryDownloadRemoval.failIfInjected(
            at: .afterFileDeletion
        ))
        XCTAssertTrue(RecoveryDownloadRemoval.isPending(at: markerURL))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testReconciliationClearsMissingAndInflightRowsButKeepsFailedDeletion() throws {
        let container = try ModelContainerFactory.makeInMemory()
        let context = container.mainContext
        let fileName = "recovery-keep-\(UUID().uuidString).mp3"
        let fileURL = try DownloadPaths.downloadsDirectory().appending(path: fileName)
        downloadFileURL = fileURL
        try Data(repeating: 1, count: 32).write(to: fileURL)
        context.insert(LocalEpisodeState(
            podcastFeedURL: "https://example.com/feed", episodeGUID: "kept",
            downloadStatus: .downloading, downloadPath: fileName
        ))
        context.insert(LocalEpisodeState(
            podcastFeedURL: "https://example.com/feed", episodeGUID: "missing",
            downloadStatus: .downloaded, downloadPath: "missing-\(UUID().uuidString).mp3"
        ))
        context.insert(LocalEpisodeState(
            podcastFeedURL: "https://example.com/feed", episodeGUID: "pending",
            downloadStatus: .pending
        ))
        try context.save()
        let journal = DownloadEventJournal(url: journalURL)
        journal.record(taskKey: "feed|missing", outcome: .finished(fileName: "late.mp3"))
        try RecoveryDownloadRemoval.begin(at: markerURL)

        try RecoveryDownloadRemoval.reconcileStoreIfNeeded(
            container: container, markerURL: markerURL, journal: journal
        )

        let rows = try context.fetch(FetchDescriptor<LocalEpisodeState>())
        XCTAssertEqual(rows.map(\.episodeGUID), ["kept"])
        XCTAssertEqual(rows.first?.downloadStatus, .downloaded)
        XCTAssertEqual(rows.first?.downloadPath, fileName)
        XCTAssertTrue(journal.pendingEvents().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
        XCTAssertFalse(RecoveryDownloadRemoval.isPending(at: markerURL))
        try context.save()
    }

    func testForceQuitAfterStoreSaveRetriesJournalAndMarkerCommit() throws {
        let container = try ModelContainerFactory.makeInMemory()
        container.mainContext.insert(LocalEpisodeState(
            podcastFeedURL: "https://example.com/feed", episodeGUID: "missing",
            downloadStatus: .downloading, downloadPath: "gone.mp3"
        ))
        try container.mainContext.save()
        let journal = DownloadEventJournal(url: journalURL)
        journal.record(taskKey: "feed|missing", outcome: .failed)
        try RecoveryDownloadRemoval.begin(at: markerURL)
        RecoveryDownloadRemoval.injectedFailurePoint = .afterStoreSave

        XCTAssertThrowsError(try RecoveryDownloadRemoval.reconcileStoreIfNeeded(
            container: container, markerURL: markerURL, journal: journal
        ))
        XCTAssertTrue(RecoveryDownloadRemoval.isPending(at: markerURL))
        XCTAssertFalse(journal.pendingEvents().isEmpty)
        XCTAssertEqual(
            try container.mainContext.fetchCount(FetchDescriptor<LocalEpisodeState>()), 0
        )

        RecoveryDownloadRemoval.injectedFailurePoint = nil
        try RecoveryDownloadRemoval.reconcileStoreIfNeeded(
            container: container, markerURL: markerURL, journal: journal
        )
        XCTAssertTrue(journal.pendingEvents().isEmpty)
        XCTAssertFalse(RecoveryDownloadRemoval.isPending(at: markerURL))
        try container.mainContext.save()
    }

    func testForceQuitBeforeMarkerRemovalRetriesIdempotently() throws {
        let container = try ModelContainerFactory.makeInMemory()
        let journal = DownloadEventJournal(url: journalURL)
        journal.record(taskKey: "feed|episode", outcome: .failed)
        try RecoveryDownloadRemoval.begin(at: markerURL)
        RecoveryDownloadRemoval.injectedFailurePoint = .beforeMarkerRemoval

        XCTAssertThrowsError(try RecoveryDownloadRemoval.reconcileStoreIfNeeded(
            container: container, markerURL: markerURL, journal: journal
        ))
        XCTAssertTrue(RecoveryDownloadRemoval.isPending(at: markerURL))
        XCTAssertTrue(journal.pendingEvents().isEmpty)

        RecoveryDownloadRemoval.injectedFailurePoint = nil
        try RecoveryDownloadRemoval.reconcileStoreIfNeeded(
            container: container, markerURL: markerURL, journal: journal
        )
        XCTAssertFalse(RecoveryDownloadRemoval.isPending(at: markerURL))
        try container.mainContext.save()
    }
}
