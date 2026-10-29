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

/// Isolated from the default recovery marker and real app downloads.
@MainActor
final class RecoveryVolumeSettingsTests: XCTestCase {
    func testRecoveryKeepsEpisodeBoostAcrossFailedSaveBoundaryAndReopen() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "RecoveryBoost-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let marker = directory.appending(path: "pending.json")
        let journalURL = directory.appending(path: "events.json")
        defer {
            RecoveryDownloadRemoval.injectedFailurePoint = nil
            try? FileManager.default.removeItem(at: directory)
        }
        func open() throws -> ModelContainer {
            let schema = Schema(versionedSchema: EarshotSchemaV13.self)
            return try ModelContainer(for: schema, configurations:
                ModelConfiguration("FutureMirrored", schema: Schema(EarshotSchemaV13.mirroredModels),
                                   url: directory.appending(path: "primary.store"), cloudKitDatabase: .none),
                ModelConfiguration("DeviceLocal", schema: Schema(EarshotSchemaV13.localModels),
                                   url: directory.appending(path: "local.store"), cloudKitDatabase: .none))
        }
        let feed = "https://example.com/feed"
        do {
            let container = try open()
            let context = container.mainContext
            let show = Podcast(feedURL: feed, title: "Show")
            let episode = Episode(guid: "missing", title: "Episode", audioURL: "https://example.com/audio")
            episode.podcast = show
            context.insert(show)
            context.insert(episode)
            context.insert(LocalEpisodeState(podcastFeedURL: feed, episodeGUID: "missing",
                                             downloadStatus: .downloaded, downloadPath: "missing-\(UUID().uuidString).mp3",
                                             volumeBoost: .off))
            context.insert(LocalEpisodeState(podcastFeedURL: feed, episodeGUID: "pending",
                                             downloadStatus: .pending, volumeBoost: .medium))
            context.insert(LocalEpisodeState(podcastFeedURL: feed, episodeGUID: "no-download", volumeBoost: .high))
            let future = LocalEpisodeState(podcastFeedURL: feed, episodeGUID: "future", downloadStatus: .downloading)
            future.volumeBoostRaw = "future-value"
            context.insert(future)
            context.insert(LocalEpisodeState(podcastFeedURL: feed, episodeGUID: "no-boost", downloadStatus: .pending))
            try context.save()
            let journal = DownloadEventJournal(url: journalURL)
            journal.record(taskKey: "feed|missing", outcome: .failed)
            try RecoveryDownloadRemoval.begin(at: marker)
            RecoveryDownloadRemoval.injectedFailurePoint = .afterStoreSave
            XCTAssertThrowsError(try RecoveryDownloadRemoval.reconcileStoreIfNeeded(
                container: container, markerURL: marker, journal: journal,
                resolveDownloadURL: { directory.appending(path: $0) }
            )) {
                XCTAssertEqual($0 as? RecoveryDownloadRemoval.InjectedFailure, .init(point: .afterStoreSave))
            }
            XCTAssertTrue(RecoveryDownloadRemoval.isPending(at: marker))
        }
        RecoveryDownloadRemoval.injectedFailurePoint = nil
        let reopened = try open()
        let journal = DownloadEventJournal(url: journalURL)
        try RecoveryDownloadRemoval.reconcileStoreIfNeeded(
            container: reopened, markerURL: marker, journal: journal,
            resolveDownloadURL: { directory.appending(path: $0) }
        )
        let context = ModelContext(reopened)
        let rows = try context.fetch(FetchDescriptor<LocalEpisodeState>())
        let byGUID = Dictionary(uniqueKeysWithValues: rows.map { ($0.episodeGUID, $0) })
        XCTAssertEqual(Set(byGUID.keys), Set(["missing", "pending", "no-download", "future"]))
        XCTAssertEqual(byGUID["missing"]?.volumeBoostRaw, "off")
        XCTAssertEqual(byGUID["pending"]?.volumeBoostRaw, "medium")
        XCTAssertEqual(byGUID["no-download"]?.volumeBoostRaw, "high")
        XCTAssertEqual(byGUID["future"]?.volumeBoostRaw, "future-value")
        for row in rows {
            XCTAssertEqual(row.downloadStatus, .none)
            XCTAssertNil(row.downloadPath)
        }
        let episode = try XCTUnwrap(context.fetch(FetchDescriptor<Episode>()).first)
        XCTAssertEqual(LocalStateStore.volumeBoost(for: episode, in: context), .off)
        XCTAssertFalse(RecoveryDownloadRemoval.isPending(at: marker))
        XCTAssertTrue(journal.pendingEvents().isEmpty)
    }
}
