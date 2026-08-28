import XCTest
import SwiftData
import CoreData
import SQLite3
import Darwin
@testable import Earshot

private final class MigrationMemorySampler: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "media.payown.earshot.migration-memory")
    private var timer: DispatchSourceTimer?
    private var maximumMB: Double = 0

    func start() -> Double {
        let baseline = Self.currentResidentMemoryMB()
        maximumMB = baseline
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.sample() }
        self.timer = timer
        timer.resume()
        return baseline
    }

    func stop() -> Double {
        timer?.cancel()
        timer = nil
        queue.sync {}
        sample()
        return lock.withLock { maximumMB }
    }

    private func sample() {
        let current = Self.currentResidentMemoryMB()
        lock.withLock { maximumMB = max(maximumMB, current) }
    }

    private static func currentResidentMemoryMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1
    }
}

private final class MigrationVolumeFreeSpaceSampler: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "media.payown.earshot.migration-disk")
    private var timer: DispatchSourceTimer?
    private var minimumAvailableBytes: Int64 = .max

    init(url: URL) {
        self.url = url
    }

    func start() throws -> Int64 {
        let baseline = try availableBytes()
        minimumAvailableBytes = baseline
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.sample() }
        self.timer = timer
        timer.resume()
        return baseline
    }

    func stop() -> Int64 {
        timer?.cancel()
        timer = nil
        queue.sync {}
        sample()
        return lock.withLock { minimumAvailableBytes }
    }

    private func sample() {
        guard let current = try? availableBytes() else { return }
        lock.withLock { minimumAvailableBytes = min(minimumAvailableBytes, current) }
    }

    private func availableBytes() throws -> Int64 {
        var statistics = statfs()
        guard statfs(url.path, &statistics) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        return Int64(statistics.f_bavail) * Int64(statistics.f_bsize)
    }
}

private final class MigrationAllocatedBlockSampler: @unchecked Sendable {
    private let rootURL: URL
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "media.payown.earshot.migration-allocated-blocks")
    private var timer: DispatchSourceTimer?
    private var maximumAllocatedBytes: Int64 = 0
    private var samplingError: Error?

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    func start() throws -> Int64 {
        let baseline = try allocatedBytes()
        maximumAllocatedBytes = baseline
        samplingError = nil
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.sample() }
        self.timer = timer
        timer.resume()
        return baseline
    }

    func stop() throws -> Int64 {
        timer?.cancel()
        timer = nil
        queue.sync {}
        sample()
        return try lock.withLock {
            if let samplingError { throw samplingError }
            return maximumAllocatedBytes
        }
    }

    private func sample() {
        do {
            let current = try allocatedBytes()
            lock.withLock {
                maximumAllocatedBytes = max(maximumAllocatedBytes, current)
            }
        } catch {
            lock.withLock {
                if samplingError == nil { samplingError = error }
            }
        }
    }

    /// `st_blocks` is reported in 512-byte units. Walk the complete test root
    /// without filtering names so SQLite's adjacent WAL, SHM, rollback journal,
    /// Core Data migration scratch files, snapshots, and atomic-write temporaries
    /// are all attributed even when their names are private implementation details.
    private func allocatedBytes() throws -> Int64 {
        var total: Int64 = 0
        try addAllocatedBytes(at: rootURL, to: &total)

        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, error in
                if (error as NSError).code != NSFileNoSuchFileError {
                    enumerationError = error
                }
                return true
            }
        ) else {
            throw CocoaError(.fileReadUnknown)
        }
        while let childURL = enumerator.nextObject() as? URL {
            try addAllocatedBytes(at: childURL, to: &total)
        }
        if let enumerationError { throw enumerationError }
        return total
    }

    private func addAllocatedBytes(at url: URL, to total: inout Int64) throws {
        var information = stat()
        guard lstat(url.path, &information) == 0 else {
            if errno == ENOENT { return }
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        total += Int64(information.st_blocks) * 512
    }
}

private actor MigrationCompletionState {
    private(set) var isFinished = false

    func markFinished() {
        isFinished = true
    }
}

/// Test-only reproduction of build 162's invalid lightweight V8-to-V9 stage.
private enum Build162V8ToV9TestPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [EarshotSchemaV8.self, EarshotSchemaV9.self]
    }

    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: EarshotSchemaV8.self, toVersion: EarshotSchemaV9.self)]
    }
}

@MainActor
final class StoreMigrationV6toV8Tests: XCTestCase {
    nonisolated(unsafe) private var directory: URL!
    nonisolated(unsafe) private var storeURL: URL!
    nonisolated(unsafe) private var downloadArtifacts: [URL] = []
    nonisolated(unsafe) private var fixtureDownloadName = ""
    nonisolated(unsafe) private var scaleDownloadPrefix = ""
    private let refreshed = Date(timeIntervalSince1970: 1_700_000_000)
    override func setUpWithError() throws {
        downloadArtifacts = []
        fixtureDownloadName = "migration-fixture-\(UUID()).mp3"
        scaleDownloadPrefix = "migration-scale-\(UUID())"
        let testRoot = ProcessInfo.processInfo.environment["SYNC_MIGRATION_TEST_ROOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        directory = testRoot.appendingPathComponent(
            "migration-v6v8-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        storeURL = directory.appendingPathComponent("default.store")
    }
    override func tearDownWithError() throws {
        StoreMigration.injectedFailurePoint = nil
        StoreMigration.bypassSafetyBackupForENOSPCTest = false
        MigrationBackupManager.injectedAvailableBytes = nil
        for url in downloadArtifacts { try? FileManager.default.removeItem(at: url) }
        try? FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    private func createDownloadFile(named name: String) throws -> URL {
        let url = try DownloadPaths.downloadsDirectory().appendingPathComponent(name)
        try Data("audio".utf8).write(to: url)
        downloadArtifacts.append(url)
        return url
    }

    private func seedV6() throws {
        try createDownloadFile(named: fixtureDownloadName)
        let schema = Schema(versionedSchema: EarshotSchemaV6.self)
        let container = try ModelContainer(for: schema, configurations:
            ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none))
        let context = container.mainContext
        let podcast = EarshotSchemaV5.Podcast(
            feedURL: "HTTPS://Example.COM:443/feed.xml#old", title: "Migration Show",
            author: nil, introSkipSeconds: 12, refreshedAt: refreshed
        )
        context.insert(podcast)
        let downloaded = EarshotSchemaV5.Episode(
            guid: "downloaded", title: "Downloaded", audioURL: "https://example.com/d.mp3",
            downloadStatus: .downloaded, downloadPath: fixtureDownloadName, positionSeconds: 37
        )
        let pending = EarshotSchemaV5.Episode(
            guid: "pending", title: "Pending", audioURL: "https://example.com/p.mp3",
            downloadStatus: .pending
        )
        let failed = EarshotSchemaV5.Episode(
            guid: "failed", title: "Failed", audioURL: "https://example.com/f.mp3",
            downloadStatus: .failed
        )
        for episode in [downloaded, pending, failed] {
            episode.podcast = podcast
            context.insert(episode)
        }
        context.insert(EarshotSchemaV5.ActiveDownload(episode: pending, state: .pending))
        context.insert(EarshotSchemaV5.QueueItem(episode: pending, position: 4))
        context.insert(EarshotSchemaV5.Bookmark(episode: downloaded, positionSeconds: 21, note: "Keep"))
        context.insert(EarshotSchemaV5.ListeningSession(episode: downloaded, podcast: podcast,
            durationSeconds: 90, speed: 1.5, date: Date(timeIntervalSince1970: 1_699_999_000)))
        context.insert(EarshotSchemaV5.RecentlyExpired(episode: failed, expiredAt: refreshed))
        context.insert(EarshotSchemaV5.QuickActionConfig(contentType: .episode,
            actionKey: EpisodeAction.download.rawValue, sortOrder: 2))
        context.insert(EarshotSchemaV5.AppSetting(key: SettingsKey.wifiOnlyDownloads, value: "false"))
        context.insert(EarshotSchemaV5.AppSetting(key: SettingsKey.lastFeedRefresh, value: "123"))
        let parent = EarshotSchemaV6.PodcastFolder(name: "Parent", sortOrder: 0)
        let child = EarshotSchemaV6.PodcastFolder(name: "Child", sortOrder: 1)
        child.parent = parent
        context.insert(parent)
        context.insert(child)
        context.insert(EarshotSchemaV6.FolderMembership(folder: child, podcast: podcast, sortOrder: 3))
        context.insert(EarshotSchemaV6.EpisodeFolderMembership(folder: child,
            episode: downloaded, sortOrder: 5))
        try context.save()
    }

    private func writeV6Fixture(
        populate: (ModelContext) throws -> Void = { _ in }
    ) throws {
        let schema = Schema(versionedSchema: EarshotSchemaV6.self)
        try autoreleasepool {
            let container = try ModelContainer(
                for: schema,
                configurations: ModelConfiguration(
                    schema: schema, url: storeURL, cloudKitDatabase: .none
                )
            )
            try populate(container.mainContext)
            try container.mainContext.save()
        }
    }

    private func seedScaleV6(episodeCount: Int) throws {
        for index in 0..<min(43, episodeCount) {
            try createDownloadFile(named: "\(scaleDownloadPrefix)-\(index).mp3")
        }
        let schema = Schema(versionedSchema: EarshotSchemaV6.self)
        let podcastCount = min(666, max(1, episodeCount))
        try autoreleasepool {
            let container = try ModelContainer(for: schema, configurations:
                ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none))
            let context = container.mainContext
            var podcasts: [EarshotSchemaV5.Podcast] = []
            for index in 0..<podcastCount {
                let podcast = EarshotSchemaV5.Podcast(
                    feedURL: String(format: "https://scale.example/%04d/feed", index),
                    title: "Scale Show \(index)", refreshedAt: refreshed
                )
                context.insert(podcast)
                podcasts.append(podcast)
            }

            let root = EarshotSchemaV6.PodcastFolder(name: "Scale Root", sortOrder: 0)
            let child = EarshotSchemaV6.PodcastFolder(name: "Scale Child", sortOrder: 1)
            child.parent = root
            context.insert(root)
            context.insert(child)
            for (index, podcast) in podcasts.prefix(5).enumerated() {
                context.insert(EarshotSchemaV6.FolderMembership(
                    folder: index.isMultiple(of: 2) ? root : child,
                    podcast: podcast,
                    sortOrder: index
                ))
            }
            try context.save()
        }
        let batchSize = 10_000
        for start in stride(from: 0, to: episodeCount, by: batchSize) {
            try autoreleasepool {
                let container = try ModelContainer(for: schema, configurations:
                    ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none))
                let context = container.mainContext
                let podcasts = try context.fetch(FetchDescriptor<EarshotSchemaV5.Podcast>(
                    sortBy: [SortDescriptor(\.feedURL)]
                ))
                XCTAssertEqual(podcasts.count, podcastCount)
                for index in start..<min(start + batchSize, episodeCount) {
                    let downloaded = index < 43
                    let pending = index == 43
                    let episode = EarshotSchemaV5.Episode(
                        guid: "scale-\(index)", title: "Episode \(index)",
                        audioURL: "https://scale.example/\(index).mp3",
                        downloadStatus: downloaded ? .downloaded : (pending ? .pending : .none),
                        downloadPath: downloaded ? "\(scaleDownloadPrefix)-\(index).mp3" : nil,
                        positionSeconds: index < 713 ? index % 300 : 0
                    )
                    let podcast = podcasts[index % podcastCount]
                    episode.podcast = podcast
                    context.insert(episode)
                    if pending {
                        context.insert(EarshotSchemaV5.ActiveDownload(episode: episode, state: .pending))
                    }
                    if index < 42 {
                        context.insert(EarshotSchemaV5.QueueItem(episode: episode, position: index))
                    }
                    if index < 713 {
                        context.insert(EarshotSchemaV5.ListeningSession(
                            episode: episode, podcast: podcast,
                            durationSeconds: 60, date: refreshed
                        ))
                    }
                    if index < 10 {
                        context.insert(EarshotSchemaV5.Bookmark(
                            episode: episode, positionSeconds: index, note: "Scale \(index)"
                        ))
                    }
                }
                try context.save()
            }
        }
    }

    /// Builds the exact two-store V8 shape installed by the draft Phase A
    /// device build. This exercises the forward route independently of V7.
    private func seedSplitV8() throws {
        try createDownloadFile(named: fixtureDownloadName)
        let full = Schema(versionedSchema: EarshotSchemaV8.self)
        let localURL = StoreMigration.localStoreURL(for: storeURL)
        try autoreleasepool {
            let container = try ModelContainer(
                for: full,
                configurations:
                    ModelConfiguration(
                        "FutureMirrored", schema: Schema(EarshotSchemaV8.mirroredModels),
                        url: storeURL, cloudKitDatabase: .none
                    ),
                    ModelConfiguration(
                        "DeviceLocal", schema: Schema(EarshotSchemaV8.localModels),
                        url: localURL, cloudKitDatabase: .none
                    )
            )
            let context = container.mainContext

            let podcast = EarshotSchemaV8.Podcast()
            podcast.feedURL = "https://example.com/feed.xml"
            podcast.title = "Already Split"
            podcast.createdAt = Date(timeIntervalSince1970: 1_600_000_000)
            context.insert(podcast)

            let episode = EarshotSchemaV8.Episode()
            episode.guid = "downloaded"
            episode.title = "Downloaded"
            episode.audioURL = "https://example.com/downloaded.mp3"
            episode.createdAt = Date(timeIntervalSince1970: 1_600_000_001)
            episode.podcast = podcast
            context.insert(episode)

            let queueItem = EarshotSchemaV8.QueueItem()
            queueItem.episode = episode
            queueItem.position = 4
            queueItem.addedAt = Date(timeIntervalSince1970: 1_600_000_002)
            context.insert(queueItem)

            let podcastState = EarshotSchemaV8.LocalPodcastState()
            podcastState.feedURL = podcast.feedURL
            podcastState.refreshedAt = refreshed
            context.insert(podcastState)

            let episodeState = EarshotSchemaV8.LocalEpisodeState()
            episodeState.podcastFeedURL = podcast.feedURL
            episodeState.episodeGUID = episode.guid
            episodeState.downloadStatusRaw = DownloadStatus.downloaded.rawValue
            episodeState.downloadPath = fixtureDownloadName
            context.insert(episodeState)

            let splitMarker = EarshotSchemaV8.LocalAppSetting()
            splitMarker.key = StoreMigration.splitCompletionKey
            splitMarker.value = "1"
            context.insert(splitMarker)
            try context.save()
        }
    }

    private func reproduceBuild162V9Migration() throws {
        let schema = Schema(versionedSchema: EarshotSchemaV9.self)
        let stores: [(name: String, url: URL)] = [
            ("FutureMirrored", storeURL),
            ("DeviceLocal", StoreMigration.localStoreURL(for: storeURL)),
        ]
        for (name, url) in stores {
            try autoreleasepool {
                _ = try ModelContainer(
                    for: schema,
                    migrationPlan: Build162V8ToV9TestPlan.self,
                    configurations: ModelConfiguration(
                        name, schema: schema, url: url, cloudKitDatabase: .none
                    )
                )
            }
        }
    }

    private func materializePreSplitFixtureDownloads() throws {
        let storedPaths = try sqliteTextRows(at: storeURL, sql: """
            SELECT ZDOWNLOADPATH FROM ZEPISODE
            WHERE ZDOWNLOADPATH IS NOT NULL AND ZDOWNLOADPATH != ''
            """)
        let downloads = try DownloadPaths.downloadsDirectory()
        for storedPath in storedPaths {
            guard let name = DownloadPaths.storedFileName(storedPath) else { continue }
            let destination = downloads.appending(path: name)
            guard !FileManager.default.fileExists(atPath: destination.path) else { continue }
            try Data("fixture audio".utf8).write(to: destination)
            downloadArtifacts.append(destination)
        }
    }

    private func injectV6FixtureBookmark() throws {
        let schema = Schema(versionedSchema: EarshotSchemaV6.self)
        try autoreleasepool {
            let container = try ModelContainer(
                for: schema,
                configurations: ModelConfiguration(
                    schema: schema, url: storeURL, cloudKitDatabase: .none
                )
            )
            var descriptor = FetchDescriptor<EarshotSchemaV5.Episode>(
                sortBy: [SortDescriptor(\.guid)]
            )
            descriptor.fetchLimit = 1
            let episode = try XCTUnwrap(container.mainContext.fetch(descriptor).first)
            container.mainContext.insert(EarshotSchemaV5.Bookmark(
                episode: episode, positionSeconds: 123, note: "Fixture bookmark"
            ))
            try container.mainContext.save()
        }
    }

    private func storeMajorVersion(at url: URL) throws -> Int? {
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            type: .sqlite, at: url
        )
        let identifier = (metadata[NSStoreModelVersionIdentifiersKey] as? [String])?.first
        return identifier.flatMap { Int($0.split(separator: ".").first ?? "") }
    }

    private func copyStoreSet(from sourceDirectory: URL) throws {
        let fm = FileManager.default
        for name in [
            "default.store", "default.store-wal", "default.store-shm",
            "earshot-local.store", "earshot-local.store-wal", "earshot-local.store-shm",
        ] {
            let source = sourceDirectory.appending(path: name)
            guard fm.fileExists(atPath: source.path) else { continue }
            try fm.copyItem(at: source, to: directory.appending(path: name))
        }
    }

    private func storeSetSize() throws -> Int64 {
        var total: Int64 = 0
        for name in [
            "default.store", "default.store-wal", "default.store-shm",
            "earshot-local.store", "earshot-local.store-wal", "earshot-local.store-shm",
        ] {
            let url = directory.appending(path: name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            total += (attributes[.size] as? NSNumber)?.int64Value ?? 0
        }
        return total
    }

    private func sqliteScalar(at url: URL, sql: String) throws -> Int64 {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw CocoaError(.fileReadUnknown)
        }
        return sqlite3_column_int64(statement, 0)
    }

    private func sqliteTextRows(at url: URL, sql: String) throws -> [String] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_finalize(statement) }
        var rows: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let text = sqlite3_column_text(statement, 0) else {
                rows.append("<NULL>")
                continue
            }
            rows.append(String(cString: text))
        }
        return rows
    }

    private struct RealV6StateSnapshot: Equatable {
        let subscriptions: [String]
        let folders: [String]
        let folderMemberships: [String]
        let episodeFolderMemberships: [String]
        let inbox: [String]
        let queue: [String]
        let positions: [String]
        let bookmarks: [String]
        let history: [String]
        let settings: [String]
        let downloaded: [String]
    }

    private func realV5StateSnapshot() throws -> RealV6StateSnapshot {
        try RealV6StateSnapshot(
            subscriptions: sqliteTextRows(at: storeURL, sql: """
                SELECT COALESCE(quote(ZFEEDURL), 'NULL') || char(31)
                    || COALESCE(quote(ZTITLE), 'NULL') || char(31)
                    || COALESCE(quote(ZAUTHOR), 'NULL') || char(31)
                    || COALESCE(quote(ZAUTOQUEUE), 'NULL')
                FROM ZPODCAST ORDER BY ZFEEDURL
                """),
            folders: sqliteTextRows(at: storeURL, sql: """
                SELECT COALESCE(quote(ZNAME), 'NULL') || char(31)
                    || COALESCE(quote(ZSORTORDER), 'NULL') || char(31) || 'NULL'
                FROM ZPODCASTFOLDER ORDER BY ZNAME
                """),
            folderMemberships: sqliteTextRows(at: storeURL, sql: """
                SELECT COALESCE(quote(f.ZNAME), 'NULL') || char(31)
                    || COALESCE(quote(p.ZFEEDURL), 'NULL') || char(31)
                    || COALESCE(quote(m.ZSORTORDER), 'NULL')
                FROM ZFOLDERMEMBERSHIP m
                LEFT JOIN ZPODCASTFOLDER f ON f.Z_PK = m.ZFOLDER
                LEFT JOIN ZPODCAST p ON p.Z_PK = m.ZPODCAST
                ORDER BY f.ZNAME, p.ZFEEDURL
                """),
            episodeFolderMemberships: [],
            inbox: sqliteTextRows(at: storeURL, sql: """
                SELECT COALESCE(quote(p.ZFEEDURL), 'NULL') || char(31)
                    || COALESCE(quote(e.ZGUID), 'NULL')
                FROM ZEPISODE e LEFT JOIN ZPODCAST p ON p.Z_PK = e.ZPODCAST
                WHERE e.ZSTATUS = 'newEpisode' AND e.ZINBOXDISMISSED = 0
                    AND (p.Z_PK IS NULL OR p.ZINBOXEXCLUDED = 0 OR p.ZINBOXINCLUDED = 1)
                ORDER BY p.ZFEEDURL, e.ZGUID
                """),
            queue: sqliteTextRows(at: storeURL, sql: """
                SELECT COALESCE(quote(p.ZFEEDURL), 'NULL') || char(31)
                    || COALESCE(quote(e.ZGUID), 'NULL') || char(31)
                    || COALESCE(quote(q.ZPOSITION), 'NULL') || char(31)
                    || COALESCE(quote(q.ZADDEDAT), 'NULL')
                FROM ZQUEUEITEM q LEFT JOIN ZEPISODE e ON e.Z_PK = q.ZEPISODE
                LEFT JOIN ZPODCAST p ON p.Z_PK = e.ZPODCAST
                ORDER BY q.ZPOSITION, p.ZFEEDURL, e.ZGUID
                """),
            positions: sqliteTextRows(at: storeURL, sql: """
                SELECT COALESCE(quote(p.ZFEEDURL), 'NULL') || char(31)
                    || COALESCE(quote(e.ZGUID), 'NULL') || char(31)
                    || COALESCE(quote(e.ZPOSITIONSECONDS), 'NULL')
                FROM ZEPISODE e LEFT JOIN ZPODCAST p ON p.Z_PK = e.ZPODCAST
                WHERE e.ZPOSITIONSECONDS > 0 ORDER BY p.ZFEEDURL, e.ZGUID
                """),
            bookmarks: sqliteTextRows(at: storeURL, sql: """
                SELECT COALESCE(quote(p.ZFEEDURL), 'NULL') || char(31)
                    || COALESCE(quote(e.ZGUID), 'NULL') || char(31)
                    || COALESCE(quote(b.ZPOSITIONSECONDS), 'NULL') || char(31)
                    || COALESCE(quote(b.ZNOTE), 'NULL')
                FROM ZBOOKMARK b LEFT JOIN ZEPISODE e ON e.Z_PK = b.ZEPISODE
                LEFT JOIN ZPODCAST p ON p.Z_PK = e.ZPODCAST
                ORDER BY p.ZFEEDURL, e.ZGUID, b.ZPOSITIONSECONDS
                """),
            history: sqliteTextRows(at: storeURL, sql: """
                SELECT COALESCE(quote(p.ZFEEDURL), 'NULL') || char(31)
                    || COALESCE(quote(e.ZGUID), 'NULL') || char(31)
                    || COALESCE(quote(h.ZDURATIONSECONDS), 'NULL') || char(31)
                    || COALESCE(quote(h.ZSPEED), 'NULL') || char(31)
                    || COALESCE(quote(h.ZDATE), 'NULL')
                FROM ZLISTENINGSESSION h LEFT JOIN ZEPISODE e ON e.Z_PK = h.ZEPISODE
                LEFT JOIN ZPODCAST p ON p.Z_PK = h.ZPODCAST
                ORDER BY h.ZDATE, p.ZFEEDURL, e.ZGUID
                """),
            settings: sqliteTextRows(at: storeURL, sql: """
                SELECT COALESCE(quote(ZKEY), 'NULL') || char(31)
                    || COALESCE(quote(ZVALUE), 'NULL')
                FROM ZAPPSETTING ORDER BY ZKEY
                """),
            downloaded: sqliteTextRows(at: storeURL, sql: """
                SELECT COALESCE(quote(p.ZFEEDURL), 'NULL') || char(31)
                    || COALESCE(quote(e.ZGUID), 'NULL') || char(31)
                    || COALESCE(quote(e.ZDOWNLOADSTATUS), 'NULL') || char(31)
                    || COALESCE(quote(e.ZDOWNLOADPATH), 'NULL')
                FROM ZEPISODE e LEFT JOIN ZPODCAST p ON p.Z_PK = e.ZPODCAST
                WHERE e.ZDOWNLOADPATH IS NOT NULL
                ORDER BY p.ZFEEDURL, e.ZGUID
                """)
        )
    }

    private func realV6StateSnapshot() throws -> RealV6StateSnapshot {
        try RealV6StateSnapshot(
            subscriptions: sqliteTextRows(at: storeURL, sql: """
                SELECT COALESCE(quote(ZFEEDURL), 'NULL') || char(31)
                    || COALESCE(quote(ZTITLE), 'NULL') || char(31)
                    || COALESCE(quote(ZAUTHOR), 'NULL') || char(31)
                    || COALESCE(quote(ZAUTOQUEUE), 'NULL')
                FROM ZPODCAST ORDER BY ZFEEDURL
                """),
            folders: sqliteTextRows(at: storeURL, sql: """
                SELECT COALESCE(quote(ZNAME), 'NULL') || char(31)
                    || COALESCE(quote(ZSORTORDER), 'NULL') || char(31)
                    || COALESCE(quote(ZPARENT), 'NULL')
                FROM ZPODCASTFOLDER ORDER BY ZNAME
                """),
            folderMemberships: sqliteTextRows(at: storeURL, sql: """
                SELECT COALESCE(quote(f.ZNAME), 'NULL') || char(31)
                    || COALESCE(quote(p.ZFEEDURL), 'NULL') || char(31)
                    || COALESCE(quote(m.ZSORTORDER), 'NULL')
                FROM ZFOLDERMEMBERSHIP m
                LEFT JOIN ZPODCASTFOLDER f ON f.Z_PK = m.ZFOLDER
                LEFT JOIN ZPODCAST p ON p.Z_PK = m.ZPODCAST
                ORDER BY f.ZNAME, p.ZFEEDURL
                """),
            episodeFolderMemberships: sqliteTextRows(at: storeURL, sql: """
                SELECT COALESCE(quote(f.ZNAME), 'NULL') || char(31)
                    || COALESCE(quote(p.ZFEEDURL), 'NULL') || char(31)
                    || COALESCE(quote(e.ZGUID), 'NULL') || char(31)
                    || COALESCE(quote(m.ZSORTORDER), 'NULL')
                FROM ZEPISODEFOLDERMEMBERSHIP m
                LEFT JOIN ZPODCASTFOLDER f ON f.Z_PK = m.ZFOLDER
                LEFT JOIN ZEPISODE e ON e.Z_PK = m.ZEPISODE
                LEFT JOIN ZPODCAST p ON p.Z_PK = e.ZPODCAST
                ORDER BY f.ZNAME, p.ZFEEDURL, e.ZGUID
                """),
            inbox: sqliteTextRows(at: storeURL, sql: """
                SELECT COALESCE(quote(p.ZFEEDURL), 'NULL') || char(31)
                    || COALESCE(quote(e.ZGUID), 'NULL')
                FROM ZEPISODE e LEFT JOIN ZPODCAST p ON p.Z_PK = e.ZPODCAST
                WHERE e.ZSTATUS = 'newEpisode' AND e.ZINBOXDISMISSED = 0
                    AND (p.Z_PK IS NULL OR p.ZINBOXEXCLUDED = 0 OR p.ZINBOXINCLUDED = 1)
                ORDER BY p.ZFEEDURL, e.ZGUID
                """),
            queue: sqliteTextRows(at: storeURL, sql: """
                SELECT COALESCE(quote(p.ZFEEDURL), 'NULL') || char(31)
                    || COALESCE(quote(e.ZGUID), 'NULL') || char(31)
                    || COALESCE(quote(q.ZPOSITION), 'NULL') || char(31)
                    || COALESCE(quote(q.ZADDEDAT), 'NULL')
                FROM ZQUEUEITEM q LEFT JOIN ZEPISODE e ON e.Z_PK = q.ZEPISODE
                LEFT JOIN ZPODCAST p ON p.Z_PK = e.ZPODCAST
                ORDER BY q.ZPOSITION, p.ZFEEDURL, e.ZGUID
                """),
            positions: sqliteTextRows(at: storeURL, sql: """
                SELECT COALESCE(quote(p.ZFEEDURL), 'NULL') || char(31)
                    || COALESCE(quote(e.ZGUID), 'NULL') || char(31)
                    || COALESCE(quote(e.ZPOSITIONSECONDS), 'NULL')
                FROM ZEPISODE e LEFT JOIN ZPODCAST p ON p.Z_PK = e.ZPODCAST
                WHERE e.ZPOSITIONSECONDS > 0 ORDER BY p.ZFEEDURL, e.ZGUID
                """),
            bookmarks: sqliteTextRows(at: storeURL, sql: """
                SELECT COALESCE(quote(p.ZFEEDURL), 'NULL') || char(31)
                    || COALESCE(quote(e.ZGUID), 'NULL') || char(31)
                    || COALESCE(quote(b.ZPOSITIONSECONDS), 'NULL') || char(31)
                    || COALESCE(quote(b.ZNOTE), 'NULL')
                FROM ZBOOKMARK b LEFT JOIN ZEPISODE e ON e.Z_PK = b.ZEPISODE
                LEFT JOIN ZPODCAST p ON p.Z_PK = e.ZPODCAST
                ORDER BY p.ZFEEDURL, e.ZGUID, b.ZPOSITIONSECONDS
                """),
            history: sqliteTextRows(at: storeURL, sql: """
                SELECT COALESCE(quote(p.ZFEEDURL), 'NULL') || char(31)
                    || COALESCE(quote(e.ZGUID), 'NULL') || char(31)
                    || COALESCE(quote(h.ZDURATIONSECONDS), 'NULL') || char(31)
                    || COALESCE(quote(h.ZSPEED), 'NULL') || char(31)
                    || COALESCE(quote(h.ZDATE), 'NULL')
                FROM ZLISTENINGSESSION h LEFT JOIN ZEPISODE e ON e.Z_PK = h.ZEPISODE
                LEFT JOIN ZPODCAST p ON p.Z_PK = h.ZPODCAST
                ORDER BY h.ZDATE, p.ZFEEDURL, e.ZGUID
                """),
            settings: sqliteTextRows(at: storeURL, sql: """
                SELECT COALESCE(quote(ZKEY), 'NULL') || char(31)
                    || COALESCE(quote(ZVALUE), 'NULL')
                FROM ZAPPSETTING ORDER BY ZKEY
                """),
            downloaded: sqliteTextRows(at: storeURL, sql: """
                SELECT COALESCE(quote(p.ZFEEDURL), 'NULL') || char(31)
                    || COALESCE(quote(e.ZGUID), 'NULL') || char(31)
                    || COALESCE(quote(e.ZDOWNLOADSTATUS), 'NULL') || char(31)
                    || COALESCE(quote(e.ZDOWNLOADPATH), 'NULL')
                FROM ZEPISODE e LEFT JOIN ZPODCAST p ON p.Z_PK = e.ZPODCAST
                WHERE e.ZDOWNLOADPATH IS NOT NULL
                ORDER BY p.ZFEEDURL, e.ZGUID
                """)
        )
    }

    private func realV10StateSnapshot() throws -> RealV6StateSnapshot {
        let localURL = StoreMigration.localStoreURL(for: storeURL)
        return try RealV6StateSnapshot(
            subscriptions: sqliteTextRows(at: storeURL, sql: """
                SELECT COALESCE(quote(ZFEEDURL), 'NULL') || char(31)
                    || COALESCE(quote(ZTITLE), 'NULL') || char(31)
                    || COALESCE(quote(ZAUTHOR), 'NULL') || char(31)
                    || COALESCE(quote(ZAUTOQUEUE), 'NULL')
                FROM ZPODCAST ORDER BY ZFEEDURL
                """),
            folders: sqliteTextRows(at: storeURL, sql: """
                SELECT COALESCE(quote(ZNAME), 'NULL') || char(31)
                    || COALESCE(quote(ZSORTORDER), 'NULL') || char(31)
                    || COALESCE(quote(ZPARENT), 'NULL')
                FROM ZPODCASTFOLDER ORDER BY ZNAME
                """),
            folderMemberships: sqliteTextRows(at: storeURL, sql: """
                SELECT COALESCE(quote(f.ZNAME), 'NULL') || char(31)
                    || COALESCE(quote(p.ZFEEDURL), 'NULL') || char(31)
                    || COALESCE(quote(m.ZSORTORDER), 'NULL')
                FROM ZFOLDERMEMBERSHIP m
                LEFT JOIN ZPODCASTFOLDER f ON f.Z_PK = m.ZFOLDER
                LEFT JOIN ZPODCAST p ON p.Z_PK = m.ZPODCAST
                ORDER BY f.ZNAME, p.ZFEEDURL
                """),
            episodeFolderMemberships: sqliteTextRows(at: storeURL, sql: """
                SELECT COALESCE(quote(f.ZNAME), 'NULL') || char(31)
                    || COALESCE(quote(p.ZFEEDURL), 'NULL') || char(31)
                    || COALESCE(quote(e.ZGUID), 'NULL') || char(31)
                    || COALESCE(quote(m.ZSORTORDER), 'NULL')
                FROM ZEPISODEFOLDERMEMBERSHIP m
                LEFT JOIN ZPODCASTFOLDER f ON f.Z_PK = m.ZFOLDER
                LEFT JOIN ZEPISODE e ON e.Z_PK = m.ZEPISODE
                LEFT JOIN ZPODCAST p ON p.Z_PK = e.ZPODCAST
                ORDER BY f.ZNAME, p.ZFEEDURL, e.ZGUID
                """),
            inbox: sqliteTextRows(at: storeURL, sql: """
                SELECT COALESCE(quote(p.ZFEEDURL), 'NULL') || char(31)
                    || COALESCE(quote(e.ZGUID), 'NULL')
                FROM ZEPISODE e LEFT JOIN ZPODCAST p ON p.Z_PK = e.ZPODCAST
                WHERE e.ZSTATUS = 'newEpisode' AND e.ZINBOXDISMISSED = 0
                    AND (p.Z_PK IS NULL OR p.ZINBOXEXCLUDED = 0 OR p.ZINBOXINCLUDED = 1)
                ORDER BY p.ZFEEDURL, e.ZGUID
                """),
            queue: sqliteTextRows(at: storeURL, sql: """
                SELECT COALESCE(quote(p.ZFEEDURL), 'NULL') || char(31)
                    || COALESCE(quote(e.ZGUID), 'NULL') || char(31)
                    || COALESCE(quote(q.ZPOSITION), 'NULL') || char(31)
                    || COALESCE(quote(q.ZADDEDAT), 'NULL')
                FROM ZQUEUEITEM q LEFT JOIN ZEPISODE e ON e.Z_PK = q.ZEPISODE
                LEFT JOIN ZPODCAST p ON p.Z_PK = e.ZPODCAST
                ORDER BY q.ZPOSITION, p.ZFEEDURL, e.ZGUID
                """),
            positions: sqliteTextRows(at: storeURL, sql: """
                SELECT COALESCE(quote(p.ZFEEDURL), 'NULL') || char(31)
                    || COALESCE(quote(e.ZGUID), 'NULL') || char(31)
                    || COALESCE(quote(e.ZPOSITIONSECONDS), 'NULL')
                FROM ZEPISODE e LEFT JOIN ZPODCAST p ON p.Z_PK = e.ZPODCAST
                WHERE e.ZPOSITIONSECONDS > 0 ORDER BY p.ZFEEDURL, e.ZGUID
                """),
            bookmarks: sqliteTextRows(at: storeURL, sql: """
                SELECT COALESCE(quote(p.ZFEEDURL), 'NULL') || char(31)
                    || COALESCE(quote(e.ZGUID), 'NULL') || char(31)
                    || COALESCE(quote(b.ZPOSITIONSECONDS), 'NULL') || char(31)
                    || COALESCE(quote(b.ZNOTE), 'NULL')
                FROM ZBOOKMARK b LEFT JOIN ZEPISODE e ON e.Z_PK = b.ZEPISODE
                LEFT JOIN ZPODCAST p ON p.Z_PK = e.ZPODCAST
                ORDER BY p.ZFEEDURL, e.ZGUID, b.ZPOSITIONSECONDS
                """),
            history: sqliteTextRows(at: storeURL, sql: """
                SELECT COALESCE(quote(p.ZFEEDURL), 'NULL') || char(31)
                    || COALESCE(quote(e.ZGUID), 'NULL') || char(31)
                    || COALESCE(quote(h.ZDURATIONSECONDS), 'NULL') || char(31)
                    || COALESCE(quote(h.ZSPEED), 'NULL') || char(31)
                    || COALESCE(quote(h.ZDATE), 'NULL')
                FROM ZLISTENINGSESSION h LEFT JOIN ZEPISODE e ON e.Z_PK = h.ZEPISODE
                LEFT JOIN ZPODCAST p ON p.Z_PK = h.ZPODCAST
                ORDER BY h.ZDATE, p.ZFEEDURL, e.ZGUID
                """),
            settings: (sqliteTextRows(at: storeURL, sql: """
                SELECT COALESCE(quote(ZKEY), 'NULL') || char(31)
                    || COALESCE(quote(ZVALUE), 'NULL')
                FROM ZAPPSETTING ORDER BY ZKEY
                """) + sqliteTextRows(at: localURL, sql: """
                SELECT COALESCE(quote(ZKEY), 'NULL') || char(31)
                    || COALESCE(quote(ZVALUE), 'NULL')
                FROM ZLOCALAPPSETTING
                WHERE ZKEY NOT LIKE '__earshot_%' ORDER BY ZKEY
                """)).sorted(),
            downloaded: sqliteTextRows(at: localURL, sql: """
                SELECT COALESCE(quote(ZPODCASTFEEDURL), 'NULL') || char(31)
                    || COALESCE(quote(ZEPISODEGUID), 'NULL') || char(31)
                    || COALESCE(quote(ZDOWNLOADSTATUSRAW), 'NULL') || char(31)
                    || COALESCE(quote(ZDOWNLOADPATH), 'NULL')
                FROM ZLOCALEPISODESTATE WHERE ZDOWNLOADPATH IS NOT NULL
                ORDER BY ZPODCASTFEEDURL, ZEPISODEGUID
                """)
        )
    }

    private func assertRealStatePreserved(
        _ actual: RealV6StateSnapshot,
        _ expected: RealV6StateSnapshot,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let comparisons: [(String, [String], [String])] = [
            ("subscriptions", actual.subscriptions, expected.subscriptions),
            ("folders", actual.folders, expected.folders),
            ("folder memberships", actual.folderMemberships, expected.folderMemberships),
            ("episode folder memberships", actual.episodeFolderMemberships,
             expected.episodeFolderMemberships),
            ("Inbox", actual.inbox, expected.inbox),
            ("Queue", actual.queue, expected.queue),
            ("playback positions", actual.positions, expected.positions),
            ("bookmarks", actual.bookmarks, expected.bookmarks),
            ("history", actual.history, expected.history),
            ("settings", actual.settings, expected.settings),
            ("downloaded state", actual.downloaded, expected.downloaded),
        ]
        for (name, actualRows, expectedRows) in comparisons {
            let mismatch = zip(actualRows, expectedRows).enumerated().first { entry in
                entry.element.0 != entry.element.1
            }?.offset
            let mismatchDescription = mismatch.map(String.init) ?? "count-only"
            XCTAssertTrue(
                actualRows == expectedRows,
                "\(name) mismatch: actual \(actualRows.count), expected "
                    + "\(expectedRows.count), first differing index "
                    + mismatchDescription,
                file: file,
                line: line
            )
        }
    }

    private func assertEpisodeSaveSurvivesReopen(
        _ container: ModelContainer, marker: String = UUID().uuidString
    ) throws {
        var firstEpisode = FetchDescriptor<Episode>()
        firstEpisode.fetchLimit = 1
        let episode = try XCTUnwrap(try container.mainContext.fetch(firstEpisode).first)
        episode.title = marker
        try container.mainContext.save()

        let reopened = try StoreMigration.openOrMigrate(at: storeURL)
        var savedEpisode = FetchDescriptor<Episode>(
            predicate: #Predicate { $0.title == marker }
        )
        savedEpisode.fetchLimit = 1
        XCTAssertEqual(try reopened.mainContext.fetch(savedEpisode).first?.title, marker)
    }

    private func assertSettingSaveSurvivesReopen(
        _ container: ModelContainer, value: String = UUID().uuidString
    ) throws {
        let key = "__migration_fixture_save_\(UUID().uuidString)"
        container.mainContext.insert(AppSetting(key: key, value: value))
        try container.mainContext.save()

        let reopened = try StoreMigration.openOrMigrate(at: storeURL)
        let saved = try reopened.mainContext.fetch(FetchDescriptor<AppSetting>(
            predicate: #Predicate { $0.key == key }
        ))
        XCTAssertEqual(saved.map(\.value), [value])
    }

    private func integrityCheck(at url: URL) throws -> [String] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA integrity_check", -1, &statement, nil)
                == SQLITE_OK else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_finalize(statement) }
        var rows: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) {
                rows.append(String(cString: text))
            }
        }
        return rows
    }

    private struct V8FixtureSnapshot: Equatable {
        let podcasts: Int
        let episodes: Int
        let localPodcastStates: Int
        let localEpisodeStates: [String]
    }

    private func readV8FixtureSnapshot() throws -> V8FixtureSnapshot {
        let full = Schema(versionedSchema: EarshotSchemaV8.self)
        return try autoreleasepool {
            let container = try ModelContainer(
                for: full,
                configurations:
                    ModelConfiguration(
                        "FutureMirrored", schema: Schema(EarshotSchemaV8.mirroredModels),
                        url: storeURL, cloudKitDatabase: .none
                    ),
                    ModelConfiguration(
                        "DeviceLocal", schema: Schema(EarshotSchemaV8.localModels),
                        url: StoreMigration.localStoreURL(for: storeURL),
                        cloudKitDatabase: .none
                    )
            )
            let context = container.mainContext
            return try V8FixtureSnapshot(
                podcasts: context.fetchCount(FetchDescriptor<EarshotSchemaV8.Podcast>()),
                episodes: context.fetchCount(FetchDescriptor<EarshotSchemaV8.Episode>()),
                localPodcastStates: context.fetchCount(
                    FetchDescriptor<EarshotSchemaV8.LocalPodcastState>()
                ),
                localEpisodeStates: context.fetch(
                    FetchDescriptor<EarshotSchemaV8.LocalEpisodeState>()
                ).map {
                    "\($0.podcastFeedURL)\u{1F}\($0.episodeGUID)\u{1F}"
                        + "\($0.downloadStatusRaw)\u{1F}\($0.downloadPath ?? "")"
                }.sorted()
            )
        }
    }

    private static func peakResidentMemoryMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size /
            MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.resident_size_peak) / 1_048_576 : -1
    }

    func testProductionMigrationPreservesGraphAndMovesDeviceState() throws {
        try seedV6()
        let container = try StoreMigration.openOrMigrate(at: storeURL)
        let context = container.mainContext
        let podcast = try XCTUnwrap(try context.fetch(FetchDescriptor<Podcast>()).first)
        XCTAssertEqual(podcast.feedURL, "https://example.com/feed.xml")
        XCTAssertEqual(podcast.refreshedAt, refreshed)
        XCTAssertNil(podcast.author)
        XCTAssertEqual(podcast.introSkipSeconds, 12)
        let episodes = Dictionary(uniqueKeysWithValues: try context
            .fetch(FetchDescriptor<Episode>()).map { ($0.guid, $0) })
        XCTAssertEqual(episodes["downloaded"]?.downloadStatus, .downloaded)
        XCTAssertEqual(episodes["downloaded"]?.downloadPath, fixtureDownloadName)
        XCTAssertEqual(episodes["downloaded"]?.positionSeconds, 37)
        XCTAssertEqual(episodes["pending"]?.downloadStatus, .pending)
        XCTAssertEqual(episodes["failed"]?.downloadStatus, DownloadStatus.none)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<QueueItem>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Bookmark>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ListeningSession>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<RecentlyExpired>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<QuickActionConfig>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FolderMembership>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<EpisodeFolderMembership>()), 1)
        let child = try XCTUnwrap(try context.fetch(FetchDescriptor<PodcastFolder>()).first {
            $0.name == "Child"
        })
        XCTAssertEqual(child.parent?.name, "Parent")
        XCTAssertEqual(child.memberships?.first?.podcast?.title, "Migration Show")
        XCTAssertEqual(child.episodeMemberships?.first?.episode?.guid, "downloaded")
        let localEpisodes = try context.fetch(FetchDescriptor<LocalEpisodeState>())
        XCTAssertEqual(Set(localEpisodes.map(\.episodeGUID)), ["downloaded", "pending"])
        XCTAssertEqual(LocalAppSettingIdentity.value(for: SettingsKey.lastFeedRefresh, in: context), "123")
        XCTAssertNil(AppSettingIdentity.value(for: SettingsKey.lastFeedRefresh, in: context))
        XCTAssertEqual(
            LocalAppSettingIdentity.value(for: SettingsKey.wifiOnlyDownloads, in: context),
            "false"
        )
        XCTAssertNil(AppSettingIdentity.value(for: SettingsKey.wifiOnlyDownloads, in: context))
        let duplicatePodcast = Podcast(
            feedURL: "HTTPS://EXAMPLE.COM:443/feed.xml#duplicate", title: "New metadata"
        )
        let duplicateEpisode = Episode(
            guid: "downloaded", title: "Duplicate episode",
            audioURL: "https://example.com/new.mp3", downloadStatus: .downloaded,
            downloadPath: "duplicate.mp3", createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        duplicateEpisode.podcast = duplicatePodcast
        context.insert(duplicatePodcast)
        context.insert(duplicateEpisode)
        context.insert(FolderMembership(folder: child, podcast: duplicatePodcast, sortOrder: 1))
        context.insert(QueueItem(episode: duplicateEpisode, position: 1))
        context.insert(Bookmark(episode: duplicateEpisode, positionSeconds: 44, note: "Also keep"))
        try context.save()
        let repair = try IdentityRepairService(context: context).repairAll()
        try context.save()
        XCTAssertEqual(repair.podcastsRemoved, 1)
        XCTAssertEqual(repair.episodesRemoved, 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Podcast>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Episode>()), 3)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FolderMembership>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<QueueItem>()), 2)
        XCTAssertEqual(Set(try context.fetch(FetchDescriptor<Bookmark>()).map(\.note)),
                       ["Keep", "Also keep"])
        try assertEpisodeSaveSurvivesReopen(container)
    }

    func testSmallV6LibraryMigratesAndSaves() throws {
        try writeV6Fixture { context in
            let podcast = EarshotSchemaV5.Podcast(
                feedURL: "https://small.example/feed", title: "Small Library"
            )
            let episode = EarshotSchemaV5.Episode(
                guid: "only-episode", title: "Only Episode",
                audioURL: "https://small.example/only.mp3"
            )
            episode.podcast = podcast
            context.insert(podcast)
            context.insert(episode)
        }

        let migrated = try StoreMigration.openOrMigrate(at: storeURL)
        XCTAssertEqual(try migrated.mainContext.fetchCount(FetchDescriptor<Podcast>()), 1)
        XCTAssertEqual(try migrated.mainContext.fetchCount(FetchDescriptor<Episode>()), 1)
        XCTAssertEqual(
            try migrated.mainContext.fetchCount(FetchDescriptor<LocalEpisodeState>()), 0
        )
        try assertEpisodeSaveSurvivesReopen(migrated)
    }

    func testEmptyV6LibraryMigratesAndSaves() throws {
        try writeV6Fixture()

        let migrated = try StoreMigration.openOrMigrate(at: storeURL)
        XCTAssertEqual(try migrated.mainContext.fetchCount(FetchDescriptor<Podcast>()), 0)
        XCTAssertEqual(try migrated.mainContext.fetchCount(FetchDescriptor<Episode>()), 0)
        XCTAssertEqual(
            try migrated.mainContext.fetchCount(FetchDescriptor<LocalEpisodeState>()), 0
        )
        XCTAssertEqual(LocalAppSettingIdentity.value(
            for: StoreMigration.splitCompletionKey, in: migrated.mainContext
        ), "1")
        XCTAssertEqual(LocalAppSettingIdentity.value(
            for: StoreMigration.identityRepairCompletionKey, in: migrated.mainContext
        ), "1")
        try assertSettingSaveSurvivesReopen(migrated)
    }

    func testV6InFlightDownloadsMigrateAndSave() throws {
        try writeV6Fixture { context in
            let podcast = EarshotSchemaV5.Podcast(
                feedURL: "HTTPS://Transfers.Example:443/feed#legacy", title: "Transfers"
            )
            context.insert(podcast)
            for (guid, status, transferState) in [
                ("pending", DownloadStatus.pending, ActiveDownloadState.pending),
                ("downloading", DownloadStatus.downloading, ActiveDownloadState.downloading),
            ] {
                let episode = EarshotSchemaV5.Episode(
                    guid: guid, title: guid.capitalized,
                    audioURL: "https://transfers.example/\(guid).mp3",
                    downloadStatus: status
                )
                episode.podcast = podcast
                context.insert(episode)
                context.insert(EarshotSchemaV5.ActiveDownload(
                    episode: episode, state: transferState
                ))
            }
        }

        let migrated = try StoreMigration.openOrMigrate(at: storeURL)
        let localStates = Dictionary(uniqueKeysWithValues: try migrated.mainContext.fetch(
            FetchDescriptor<LocalEpisodeState>()
        ).map { ($0.episodeGUID, $0.downloadStatus) })
        XCTAssertEqual(localStates, [
            "pending": .pending,
            "downloading": .downloading,
        ])
        let episodes = Dictionary(uniqueKeysWithValues: try migrated.mainContext.fetch(
            FetchDescriptor<Episode>()
        ).map { ($0.guid, $0.downloadStatus) })
        XCTAssertEqual(episodes, [
            "pending": .pending,
            "downloading": .downloading,
        ])
        try assertEpisodeSaveSurvivesReopen(migrated)
    }

    func testV6OrphanedRowsMigrateAndSave() throws {
        try writeV6Fixture { context in
            context.insert(EarshotSchemaV5.QueueItem(position: 1))
            context.insert(EarshotSchemaV5.ListeningSession(durationSeconds: 30))
            context.insert(EarshotSchemaV5.Bookmark(positionSeconds: 12, note: "Orphan"))
            context.insert(EarshotSchemaV5.RecentlyExpired(expiredAt: self.refreshed))
            context.insert(EarshotSchemaV5.ActiveDownload(state: .downloading))
            context.insert(EarshotSchemaV6.FolderMembership(sortOrder: 2))
            context.insert(EarshotSchemaV6.EpisodeFolderMembership(sortOrder: 3))
        }

        let migrated = try StoreMigration.openOrMigrate(at: storeURL)
        XCTAssertEqual(try migrated.mainContext.fetchCount(FetchDescriptor<QueueItem>()), 1)
        XCTAssertEqual(
            try migrated.mainContext.fetchCount(FetchDescriptor<ListeningSession>()), 1
        )
        XCTAssertEqual(try migrated.mainContext.fetchCount(FetchDescriptor<Bookmark>()), 1)
        XCTAssertEqual(
            try migrated.mainContext.fetchCount(FetchDescriptor<RecentlyExpired>()), 1
        )
        XCTAssertEqual(
            try migrated.mainContext.fetchCount(FetchDescriptor<FolderMembership>()), 1
        )
        XCTAssertEqual(
            try migrated.mainContext.fetchCount(FetchDescriptor<EpisodeFolderMembership>()), 1
        )
        XCTAssertEqual(
            try migrated.mainContext.fetchCount(FetchDescriptor<LocalEpisodeState>()), 0,
            "an active transfer without an episode identity must be ignored"
        )
        try assertSettingSaveSurvivesReopen(migrated)
    }

    func testMigrationEngineReportsStagesWhileMainActorRemainsResponsive() async throws {
        try seedScaleV6(episodeCount: 5_000)
        let engine = StoreMigrationEngine()
        let completion = MigrationCompletionState()

        let migration = Task { () throws -> ModelContainer in
            do {
                let container = try await engine.openOrMigrate(at: storeURL)
                await completion.markFinished()
                return container
            } catch {
                await completion.markFinished()
                throw error
            }
        }

        var iterator = engine.progressUpdates.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first, .preparingAndValidating)
        var migrationFinished = await completion.isFinished
        XCTAssertFalse(migrationFinished)

        var heartbeat = 0
        await Task.yield()
        heartbeat += 1
        XCTAssertEqual(heartbeat, 1)
        migrationFinished = await completion.isFinished
        XCTAssertFalse(
            migrationFinished,
            "main-actor work must run while the engine is still migrating"
        )

        var stages = first.map { [$0] } ?? []
        while let stage = await iterator.next() { stages.append(stage) }
        let migrated = try await migration.value

        XCTAssertEqual(stages, StoreMigrationProgress.allCases)
        XCTAssertEqual(
            try migrated.mainContext.fetchCount(FetchDescriptor<Episode>()),
            5_000
        )
        try assertEpisodeSaveSurvivesReopen(migrated)
    }

    func testMigrationPrefersDuplicateDownloadWhoseFileExists() throws {
        let existingName = "migration-existing-\(UUID()).mp3"
        let missingName = "migration-missing-\(UUID()).mp3"
        let existingURL = try createDownloadFile(named: existingName)

        let schema = Schema(versionedSchema: EarshotSchemaV6.self)
        try autoreleasepool {
            let container = try ModelContainer(
                for: schema,
                configurations: ModelConfiguration(
                    schema: schema, url: storeURL, cloudKitDatabase: .none
                )
            )
            let context = container.mainContext
            let olderPodcast = EarshotSchemaV5.Podcast(
                feedURL: "HTTPS://Duplicates.Example:443/feed#old", title: "Older",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
            let newerPodcast = EarshotSchemaV5.Podcast(
                feedURL: "https://duplicates.example/feed", title: "Newer",
                createdAt: Date(timeIntervalSince1970: 1_800_000_000)
            )
            context.insert(olderPodcast)
            context.insert(newerPodcast)

            let existing = EarshotSchemaV5.Episode(
                guid: "duplicate", title: "Existing", audioURL: "https://example.com/old.mp3",
                pubDate: Date(timeIntervalSince1970: 1_700_000_000),
                downloadStatus: .downloaded, downloadPath: existingName,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
            existing.podcast = olderPodcast
            context.insert(existing)

            let missing = EarshotSchemaV5.Episode(
                guid: "duplicate", title: "Missing", audioURL: "https://example.com/new.mp3",
                pubDate: Date(timeIntervalSince1970: 1_800_000_000),
                downloadStatus: .downloaded, downloadPath: missingName,
                createdAt: Date(timeIntervalSince1970: 1_800_000_000)
            )
            missing.podcast = newerPodcast
            context.insert(missing)
            try context.save()
        }

        let migrated = try StoreMigration.openOrMigrate(at: storeURL)
        let episodes = try migrated.mainContext.fetch(FetchDescriptor<Episode>())
            .filter { $0.guid == "duplicate" }
        let survivor = try XCTUnwrap(episodes.first)
        XCTAssertEqual(episodes.count, 1)
        XCTAssertEqual(survivor.downloadStatus, .downloaded)
        XCTAssertEqual(survivor.downloadPath, existingName)
        XCTAssertEqual(survivor.localAudioURL, existingURL)
        try assertEpisodeSaveSurvivesReopen(migrated)
    }

    func testMigratedSplitStoreReopensIdempotently() throws {
        try seedV6()
        try autoreleasepool { _ = try StoreMigration.openOrMigrate(at: storeURL) }
        let backupRoot = MigrationBackupManager.backupRoot(for: storeURL)
        try? FileManager.default.removeItem(at: backupRoot)
        MigrationBackupManager.injectedAvailableBytes = 0
        var progress: [StoreMigrationProgress] = []
        let reopened = try StoreMigration.openOrMigrate(at: storeURL) {
            progress.append($0)
        }
        XCTAssertTrue(progress.isEmpty, "a settled V10 store must not enter preparation")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupRoot.path))
        XCTAssertEqual(try reopened.mainContext.fetchCount(FetchDescriptor<Podcast>()), 1)
        XCTAssertEqual(try reopened.mainContext.fetchCount(FetchDescriptor<LocalEpisodeState>()), 2)
        XCTAssertEqual(LocalAppSettingIdentity.value(for: StoreMigration.splitCompletionKey,
            in: reopened.mainContext), "1")
        XCTAssertEqual(LocalAppSettingIdentity.value(
            for: StoreMigration.identityRepairCompletionKey, in: reopened.mainContext
        ), "1")
        try assertEpisodeSaveSurvivesReopen(reopened)
    }

    func testCompletedV10FinalOpenFailureRemainsNonDestructive() throws {
        try seedV6()
        try autoreleasepool { _ = try StoreMigration.openOrMigrate(at: storeURL) }
        StoreMigration.injectedFailurePoint = .beforeCompletedFinalOpen

        XCTAssertThrowsError(try StoreMigration.openOrMigrate(at: storeURL)) { error in
            guard case StoreMigrationFailure.operational(let underlying) = error else {
                return XCTFail("Expected an operational retry, got \(error)")
            }
            XCTAssertEqual(
                underlying as? StoreMigration.InjectedMigrationFailure,
                .init(point: .beforeCompletedFinalOpen)
            )
        }
        StoreMigration.injectedFailurePoint = nil

        let reopened = try StoreMigration.openOrMigrate(at: storeURL)
        try assertEpisodeSaveSurvivesReopen(reopened)
    }

    func testSettledV10StoreMigratesToV11AndPreservesLocalEpisodeState() throws {
        let localURL = StoreMigration.localStoreURL(for: storeURL)
        try autoreleasepool {
            let full = Schema(versionedSchema: EarshotSchemaV10.self)
            let container = try ModelContainer(
                for: full,
                configurations:
                    ModelConfiguration(
                        "FutureMirrored", schema: Schema(EarshotSchemaV10.mirroredModels),
                        url: storeURL, cloudKitDatabase: .none
                    ),
                    ModelConfiguration(
                        "DeviceLocal", schema: Schema(EarshotSchemaV10.localModels),
                        url: localURL, cloudKitDatabase: .none
                    )
            )
            let podcast = Podcast(feedURL: "https://v10.example/feed", title: "V10")
            let episode = Episode(
                guid: "v10-episode", title: "Episode", audioURL: "https://v10.example/a.mp3"
            )
            episode.podcast = podcast
            container.mainContext.insert(podcast)
            container.mainContext.insert(episode)
            let row = EarshotSchemaV10.LocalEpisodeState()
            row.podcastFeedURL = podcast.feedURL
            row.episodeGUID = episode.guid
            row.downloadStatusRaw = DownloadStatus.downloaded.rawValue
            row.downloadPath = "v10.mp3"
            container.mainContext.insert(row)
            try LocalAppSettingIdentity.setValue(
                "1", for: StoreMigration.splitCompletionKey, in: container.mainContext
            )
            try LocalAppSettingIdentity.setValue(
                "1", for: StoreMigration.identityRepairCompletionKey,
                in: container.mainContext
            )
            try container.mainContext.save()
        }

        let migrated = try StoreMigration.openOrMigrate(at: storeURL)
        XCTAssertEqual(try storeMajorVersion(at: storeURL), 11)
        XCTAssertEqual(try storeMajorVersion(at: localURL), 11)
        let rows = try migrated.mainContext.fetch(FetchDescriptor<LocalEpisodeState>())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.podcastFeedURL, "https://v10.example/feed")
        XCTAssertEqual(rows.first?.episodeGUID, "v10-episode")
        // Startup reconciliation correctly clears a stale path whose file does not exist.
        XCTAssertNil(rows.first?.downloadPath)
        XCTAssertEqual(rows.first?.downloadStatus, DownloadStatus.none)
        XCTAssertNil(rows.first?.volumeBoostRaw)
    }

    func testInterruptedFreshV11CreationResumesWithoutPreparationAndSaves() throws {
        StoreMigration.injectedFailurePoint = .beforeFreshStoreMarkers
        XCTAssertThrowsError(try StoreMigration.openOrMigrate(at: storeURL)) { error in
            XCTAssertEqual(
                error as? StoreMigration.InjectedMigrationFailure,
                .init(point: .beforeFreshStoreMarkers)
            )
        }
        StoreMigration.injectedFailurePoint = nil

        XCTAssertEqual(try storeMajorVersion(at: storeURL), 11)
        XCTAssertEqual(
            try storeMajorVersion(at: StoreMigration.localStoreURL(for: storeURL)), 11
        )
        var progress: [StoreMigrationProgress] = []
        let resumed = try StoreMigration.openOrMigrate(at: storeURL) {
            progress.append($0)
        }

        XCTAssertTrue(progress.isEmpty, "an interrupted fresh store is not a migration")
        XCTAssertEqual(try resumed.mainContext.fetchCount(FetchDescriptor<Podcast>()), 0)
        XCTAssertEqual(try resumed.mainContext.fetchCount(FetchDescriptor<Episode>()), 0)
        XCTAssertEqual(LocalAppSettingIdentity.value(
            for: StoreMigration.splitCompletionKey, in: resumed.mainContext
        ), "1")
        XCTAssertEqual(LocalAppSettingIdentity.value(
            for: StoreMigration.identityRepairCompletionKey, in: resumed.mainContext
        ), "1")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: MigrationBackupManager.backupRoot(for: storeURL).path
        ))
        try assertSettingSaveSurvivesReopen(resumed)
    }

    func testNonemptyUnmarkedV11NeverUsesFreshStoreResume() throws {
        StoreMigration.injectedFailurePoint = .beforeFreshStoreMarkers
        XCTAssertThrowsError(try StoreMigration.openOrMigrate(at: storeURL))
        StoreMigration.injectedFailurePoint = nil

        try autoreleasepool {
            let full = Schema(versionedSchema: EarshotSchemaV11.self)
            let container = try ModelContainer(
                for: full,
                configurations:
                    ModelConfiguration(
                        "FutureMirrored", schema: Schema(EarshotSchemaV11.mirroredModels),
                        url: storeURL, cloudKitDatabase: .none
                    ),
                    ModelConfiguration(
                        "DeviceLocal", schema: Schema(EarshotSchemaV11.localModels),
                        url: StoreMigration.localStoreURL(for: storeURL),
                        cloudKitDatabase: .none
                    )
            )
            container.mainContext.insert(Podcast(
                feedURL: "https://must-not-reset.example/feed", title: "Keep Me"
            ))
            try container.mainContext.save()
        }

        var progress: [StoreMigrationProgress] = []
        XCTAssertThrowsError(try StoreMigration.openOrMigrate(at: storeURL) {
            progress.append($0)
        }) { error in
            guard case StoreOpenError.unreadable = error else {
                return XCTFail("expected nondestructive recovery, got \(error)")
            }
        }
        XCTAssertTrue(progress.isEmpty, "an unmarked V11 store is not a migration")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: MigrationBackupManager.backupRoot(for: storeURL).path
        ))

        let full = Schema(versionedSchema: EarshotSchemaV11.self)
        let preserved = try ModelContainer(
            for: full,
            configurations:
                ModelConfiguration(
                    "FutureMirrored", schema: Schema(EarshotSchemaV11.mirroredModels),
                    url: storeURL, cloudKitDatabase: .none
                ),
                ModelConfiguration(
                    "DeviceLocal", schema: Schema(EarshotSchemaV11.localModels),
                    url: StoreMigration.localStoreURL(for: storeURL),
                    cloudKitDatabase: .none
                )
        )
        XCTAssertEqual(
            try preserved.mainContext.fetch(FetchDescriptor<Podcast>()).map(\.title),
            ["Keep Me"]
        )
        XCTAssertNil(LocalAppSettingIdentity.value(
            for: StoreMigration.splitCompletionKey, in: preserved.mainContext
        ))
    }

    func testInterruptedFreshV10WithOnlyMirroredFileResumesAndSaves() throws {
        let schema = Schema(versionedSchema: EarshotMirroredSchemaV10.self)
        try autoreleasepool {
            _ = try ModelContainer(
                for: schema,
                configurations: ModelConfiguration(
                    "FutureMirrored", schema: schema, url: storeURL,
                    cloudKitDatabase: .none
                )
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: StoreMigration.localStoreURL(for: storeURL).path
        ))

        var progress: [StoreMigrationProgress] = []
        let resumed = try StoreMigration.openOrMigrate(at: storeURL) {
            progress.append($0)
        }

        XCTAssertTrue(progress.isEmpty)
        XCTAssertEqual(LocalAppSettingIdentity.value(
            for: StoreMigration.splitCompletionKey, in: resumed.mainContext
        ), "1")
        try assertSettingSaveSurvivesReopen(resumed)
    }

    func testInterruptedFreshV10WithOnlyLocalFileResumesAndSaves() throws {
        let schema = Schema(versionedSchema: EarshotSchemaV10.self)
        let localURL = StoreMigration.localStoreURL(for: storeURL)
        try autoreleasepool {
            _ = try ModelContainer(
                for: schema,
                configurations: ModelConfiguration(
                    "DeviceLocal", schema: schema, url: localURL,
                    cloudKitDatabase: .none
                )
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeURL.path))

        var progress: [StoreMigrationProgress] = []
        let resumed = try StoreMigration.openOrMigrate(at: storeURL) {
            progress.append($0)
        }

        XCTAssertTrue(progress.isEmpty)
        XCTAssertEqual(LocalAppSettingIdentity.value(
            for: StoreMigration.splitCompletionKey, in: resumed.mainContext
        ), "1")
        try assertSettingSaveSurvivesReopen(resumed)
    }

    func testInterruptedFreshV9WithOnlyMirroredFileMovesForwardAndSaves() throws {
        let schema = Schema(versionedSchema: EarshotMirroredSchemaV9.self)
        try autoreleasepool {
            _ = try ModelContainer(
                for: schema,
                configurations: ModelConfiguration(
                    "FutureMirrored", schema: schema, url: storeURL,
                    cloudKitDatabase: .none
                )
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: StoreMigration.localStoreURL(for: storeURL).path
        ))

        var progress: [StoreMigrationProgress] = []
        let resumed = try StoreMigration.openOrMigrate(at: storeURL) {
            progress.append($0)
        }

        XCTAssertTrue(progress.isEmpty)
        XCTAssertEqual(try storeMajorVersion(at: storeURL), 11)
        XCTAssertEqual(LocalAppSettingIdentity.value(
            for: StoreMigration.splitCompletionKey, in: resumed.mainContext
        ), "1")
        try assertSettingSaveSurvivesReopen(resumed)
    }

    func testInterruptedFreshV9WithOnlyLocalFileMovesForwardAndSaves() throws {
        let schema = Schema(versionedSchema: EarshotSchemaV9.self)
        let localURL = StoreMigration.localStoreURL(for: storeURL)
        try autoreleasepool {
            _ = try ModelContainer(
                for: schema,
                configurations: ModelConfiguration(
                    "DeviceLocal", schema: Schema(EarshotSchemaV9.localModels),
                    url: localURL, cloudKitDatabase: .none
                )
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeURL.path))

        var progress: [StoreMigrationProgress] = []
        let resumed = try StoreMigration.openOrMigrate(at: storeURL) {
            progress.append($0)
        }

        XCTAssertTrue(progress.isEmpty)
        XCTAssertEqual(try storeMajorVersion(at: localURL), 11)
        XCTAssertEqual(LocalAppSettingIdentity.value(
            for: StoreMigration.splitCompletionKey, in: resumed.mainContext
        ), "1")
        try assertSettingSaveSurvivesReopen(resumed)
    }

    func testOrphanedStoreSidecarNeverEntersMigrationPreparation() throws {
        let walURL = storeURL.deletingPathExtension()
            .appendingPathExtension("store-wal")
        let residue = Data("preserve orphaned sqlite residue".utf8)
        try residue.write(to: walURL)

        var progress: [StoreMigrationProgress] = []
        XCTAssertThrowsError(try StoreMigration.openOrMigrate(at: storeURL) {
            progress.append($0)
        }) { error in
            guard case StoreOpenError.unreadable = error else {
                return XCTFail("expected nondestructive recovery, got \(error)")
            }
        }

        XCTAssertTrue(progress.isEmpty)
        XCTAssertEqual(try Data(contentsOf: walURL), residue)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: MigrationBackupManager.backupRoot(for: storeURL).path
        ))
    }

    func testInterruptedFreshV9CreationMovesForwardWithoutPreparationAndSaves() throws {
        let schema = Schema(versionedSchema: EarshotSchemaV9.self)
        let localURL = StoreMigration.localStoreURL(for: storeURL)
        try autoreleasepool {
            _ = try ModelContainer(
                for: schema,
                configurations:
                    ModelConfiguration(
                        "FutureMirrored", schema: Schema(EarshotSchemaV9.mirroredModels),
                        url: storeURL, cloudKitDatabase: .none
                    ),
                    ModelConfiguration(
                        "DeviceLocal", schema: Schema(EarshotSchemaV9.localModels),
                        url: localURL, cloudKitDatabase: .none
                    )
            )
        }
        XCTAssertEqual(try storeMajorVersion(at: storeURL), 9)
        XCTAssertEqual(try storeMajorVersion(at: localURL), 9)

        var progress: [StoreMigrationProgress] = []
        let resumed = try StoreMigration.openOrMigrate(at: storeURL) {
            progress.append($0)
        }

        XCTAssertTrue(progress.isEmpty, "an interrupted fresh V9 store is not a migration")
        XCTAssertEqual(try storeMajorVersion(at: storeURL), 11)
        XCTAssertEqual(try storeMajorVersion(at: localURL), 11)
        XCTAssertEqual(LocalAppSettingIdentity.value(
            for: StoreMigration.splitCompletionKey, in: resumed.mainContext
        ), "1")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: MigrationBackupManager.backupRoot(for: storeURL).path
        ))
        try assertSettingSaveSurvivesReopen(resumed)
    }

    func testInterruptedFreshV9FinalizationResumesMixedV10V9PairAndSaves() throws {
        let schema = Schema(versionedSchema: EarshotSchemaV9.self)
        let localURL = StoreMigration.localStoreURL(for: storeURL)
        try autoreleasepool {
            _ = try ModelContainer(
                for: schema,
                configurations:
                    ModelConfiguration(
                        "FutureMirrored", schema: Schema(EarshotSchemaV9.mirroredModels),
                        url: storeURL, cloudKitDatabase: .none
                    ),
                    ModelConfiguration(
                        "DeviceLocal", schema: Schema(EarshotSchemaV9.localModels),
                        url: localURL, cloudKitDatabase: .none
                    )
            )
        }
        StoreMigration.injectedFailurePoint = .afterFreshV9MirroredFinalization
        XCTAssertThrowsError(try StoreMigration.openOrMigrate(at: storeURL)) { error in
            XCTAssertEqual(
                error as? StoreMigration.InjectedMigrationFailure,
                .init(point: .afterFreshV9MirroredFinalization)
            )
        }
        StoreMigration.injectedFailurePoint = nil
        XCTAssertEqual(try storeMajorVersion(at: storeURL), 11)
        XCTAssertEqual(try storeMajorVersion(at: localURL), 9)

        var progress: [StoreMigrationProgress] = []
        let resumed = try StoreMigration.openOrMigrate(at: storeURL) {
            progress.append($0)
        }

        XCTAssertTrue(progress.isEmpty)
        XCTAssertEqual(try storeMajorVersion(at: storeURL), 11)
        XCTAssertEqual(try storeMajorVersion(at: localURL), 11)
        XCTAssertEqual(LocalAppSettingIdentity.value(
            for: StoreMigration.splitCompletionKey, in: resumed.mainContext
        ), "1")
        try assertSettingSaveSurvivesReopen(resumed)
    }

    func testAlreadySplitV8StoreMovesForwardWithoutBridgeReplay() throws {
        try seedSplitV8()
        XCTAssertEqual(try storeMajorVersion(at: storeURL), 8)

        let migrated = try StoreMigration.openOrMigrate(at: storeURL)
        let context = migrated.mainContext
        XCTAssertEqual(try storeMajorVersion(at: storeURL), 11)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Podcast>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Episode>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LocalPodcastState>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<LocalEpisodeState>()), 1)

        let episode = try XCTUnwrap(try context.fetch(FetchDescriptor<Episode>()).first)
        XCTAssertEqual(episode.downloadStatus, .downloaded)
        XCTAssertEqual(episode.downloadPath, fixtureDownloadName)
        XCTAssertEqual(LocalAppSettingIdentity.value(
            for: StoreMigration.splitCompletionKey, in: context
        ), "1")
        XCTAssertEqual(LocalAppSettingIdentity.value(
            for: StoreMigration.identityRepairCompletionKey, in: context
        ), "1")
        XCTAssertNil(LocalAppSettingIdentity.value(
            for: StoreMigration.bridgeCompletionKey, in: context
        ), "The completed V8 split must not replay the original V7 bridge")
        try assertEpisodeSaveSurvivesReopen(
            migrated, marker: "Saved after V8 to V10 migration"
        )
    }

    func testAlreadySplitV8QueueItemRelationshipSaveSurvivesMigration() throws {
        try seedSplitV8()
        let migrated = try StoreMigration.openOrMigrate(at: storeURL)
        let queueItem = try XCTUnwrap(
            try migrated.mainContext.fetch(FetchDescriptor<QueueItem>()).first
        )
        XCTAssertEqual(queueItem.episode?.guid, "downloaded")
        queueItem.position = 17
        try migrated.mainContext.save()

        let reopened = try StoreMigration.openOrMigrate(at: storeURL)
        let saved = try XCTUnwrap(
            try reopened.mainContext.fetch(FetchDescriptor<QueueItem>()).first
        )
        XCTAssertEqual(saved.position, 17)
        XCTAssertEqual(saved.episode?.guid, "downloaded")
    }

    func testBuild162V9NullTombstoneStoreMovesToV10AndSaves() throws {
        try seedSplitV8()
        try reproduceBuild162V9Migration()
        XCTAssertEqual(try storeMajorVersion(at: storeURL), 9)
        XCTAssertEqual(
            try sqliteScalar(
                at: storeURL,
                sql: "SELECT COUNT(*) FROM ZEPISODE WHERE ZLEGACYDOWNLOADSTATUS IS NULL"
            ),
            1
        )

        let migrated = try StoreMigration.openOrMigrate(at: storeURL)
        XCTAssertEqual(try storeMajorVersion(at: storeURL), 11)
        XCTAssertEqual(
            try sqliteScalar(
                at: storeURL,
                sql: "SELECT COUNT(*) FROM ZEPISODE WHERE ZLEGACYDOWNLOADSTATUS IS NULL"
            ),
            1
        )
        try assertEpisodeSaveSurvivesReopen(
            migrated, marker: "Saved after synthetic build-162 V9 repair"
        )
    }

    func testIdentityRepairCompletionMarkerGatesLaterLaunches() throws {
        try seedV6()
        try autoreleasepool { _ = try StoreMigration.openOrMigrate(at: storeURL) }

        // Introduce a duplicate only after the migration repair and its marker
        // are durable. If repairAll incorrectly runs on every open it will merge
        // this row; a retained pair proves the versioned gate was honored.
        try autoreleasepool {
            let container = try StoreMigration.openOrMigrate(at: storeURL)
            container.mainContext.insert(AppSetting(
                key: SettingsKey.themeOverride, value: "first-post-marker-row"
            ))
            container.mainContext.insert(AppSetting(
                key: SettingsKey.themeOverride, value: "second-post-marker-row"
            ))
            try container.mainContext.save()
        }

        let reopened = try StoreMigration.openOrMigrate(at: storeURL)
        let key = SettingsKey.themeOverride
        let rows = try reopened.mainContext.fetch(FetchDescriptor<AppSetting>(
            predicate: #Predicate { $0.key == key }
        ))
        XCTAssertEqual(rows.count, 2, "repairAll must not run after its marker is saved")
        XCTAssertEqual(LocalAppSettingIdentity.value(
            for: StoreMigration.identityRepairCompletionKey, in: reopened.mainContext
        ), "1")
    }

    /// End-to-end proof against the production-shaped store copied from public
    /// App Store build 155. This is the release-floor fixture, not generated data.
    func testRealBuild155V5FixtureMigratesToV10AndSaves() async throws {
        let variable = "SYNC_MIGRATION_REAL_V5_DIRECTORY"
        guard let path = ProcessInfo.processInfo.environment[variable] else {
            throw XCTSkip("Set TEST_RUNNER_\(variable) to the verified V5 backup directory")
        }
        try copyStoreSet(from: URL(fileURLWithPath: path, isDirectory: true))
        XCTAssertEqual(try storeMajorVersion(at: storeURL), 5)
        let sourceState = try realV5StateSnapshot()
        XCTAssertEqual(sourceState.subscriptions.count, 10)
        XCTAssertEqual(sourceState.folders.count, 0)
        XCTAssertEqual(sourceState.folderMemberships.count, 0)
        XCTAssertEqual(sourceState.episodeFolderMemberships.count, 0)
        XCTAssertEqual(sourceState.inbox.count, 25)
        XCTAssertEqual(sourceState.queue.count, 5)
        XCTAssertEqual(sourceState.positions.count, 2)
        XCTAssertEqual(sourceState.bookmarks.count, 0)
        XCTAssertEqual(sourceState.history.count, 4)
        XCTAssertEqual(sourceState.settings.count, 9)
        XCTAssertEqual(sourceState.downloaded.count, 30)
        try materializePreSplitFixtureDownloads()

        let beforeBytes = try storeSetSize()
        let allocatedBlockSampler = MigrationAllocatedBlockSampler(rootURL: directory)
        let baselineAllocatedBytes = try allocatedBlockSampler.start()
        let volumeSampler = MigrationVolumeFreeSpaceSampler(url: directory)
        let baselineAvailableBytes = try volumeSampler.start()
        let start = DispatchTime.now().uptimeNanoseconds
        let migrated = try await StoreMigrationEngine().openOrMigrate(at: storeURL)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        let maximumAllocatedBytes = try allocatedBlockSampler.stop()
        let minimumAvailableBytes = volumeSampler.stop()
        let attributedPeakBytes = maximumAllocatedBytes - baselineAllocatedBytes
        let attributedPeakMultiple = Double(attributedPeakBytes) / Double(beforeBytes)
        let volumeDiagnosticPeakBytes = baselineAvailableBytes - minimumAvailableBytes
        let volumeDiagnosticPeakMultiple = Double(volumeDiagnosticPeakBytes)
            / Double(beforeBytes)
        let context = migrated.mainContext

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Podcast>()), 10)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Episode>()), 53_946)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<QueueItem>()), 5)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ListeningSession>()), 4)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PodcastFolder>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Bookmark>()), 0)
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<LocalEpisodeState>())
                .filter { $0.downloadPath != nil }.count,
            30
        )
        XCTAssertEqual(try storeMajorVersion(at: storeURL), 11)
        XCTAssertEqual(try integrityCheck(at: storeURL), ["ok"])
        XCTAssertEqual(
            try integrityCheck(at: StoreMigration.localStoreURL(for: storeURL)), ["ok"]
        )
        assertRealStatePreserved(try realV10StateSnapshot(), sourceState)

        // Build 202 was terminated during the first production reconciliation
        // after this migration path. Exercise that transition against the real
        // 53,946-episode fixture, not only the synthetic scale store.
        let projectionSchema = Schema([
            CloudPodcastProjection.self,
            CloudEpisodeStateProjection.self,
            CloudQueueItemProjection.self,
            CloudSettingProjection.self,
            CloudBookmarkProjection.self,
            CloudListeningSessionProjection.self,
            CloudFolderProjection.self,
        ])
        let projection = try ModelContainer(
            for: projectionSchema,
            configurations: ModelConfiguration(
                "RealV5PostMigrationProjection",
                schema: projectionSchema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )
        )
        let reconcileStart = DispatchTime.now().uptimeNanoseconds
        try await CloudProjectionCoordinator(
            applicationContainer: migrated,
            projectionContainer: projection,
            center: NotificationCenter(),
            deviceID: "real-v5-fixture"
        ).reconcile()
        let reconcileElapsed = Double(
            DispatchTime.now().uptimeNanoseconds - reconcileStart
        ) / 1_000_000_000
        XCTAssertEqual(
            try projection.mainContext.fetchCount(FetchDescriptor<CloudPodcastProjection>()),
            10
        )
        XCTAssertLessThan(
            reconcileElapsed, 5,
            "First post-migration reconciliation consumed half the iOS scene watchdog budget"
        )
        print(String(format:
            "REALV5POSTMIGRATION|episodes|%d|projectionSeconds|%.3f",
            53_946, reconcileElapsed
        ))
        let afterBytes = try storeSetSize()
        print(String(format:
            "REALV5MIGRATION|seconds|%.3f|beforeBytes|%lld|afterBytes|%lld"
                + "|attributedPeakBytes|%lld|attributedPeakMultiple|%.6f"
                + "|volumeDiagnosticPeakBytes|%lld|volumeDiagnosticPeakMultiple|%.6f"
                + "|episodes|%d",
            elapsed, beforeBytes, afterBytes,
            attributedPeakBytes, attributedPeakMultiple,
            volumeDiagnosticPeakBytes, volumeDiagnosticPeakMultiple, 53_946
        ))
        XCTAssertLessThan(
            elapsed, 15,
            "Production V5 migration leaves too little margin inside the launch watchdog"
        )
        XCTAssertLessThan(
            attributedPeakMultiple, MigrationBackupManager.initialFreeSpaceMultiplier,
            "The production V5 disk gate must exceed the observed fixture peak"
        )
        try assertEpisodeSaveSurvivesReopen(
            migrated, marker: "Saved after real build-155 V5 migration"
        )
    }

    /// Measures an already-migrated production device store. Build 203 proved
    /// the one-time migration and first projection, but a 169,946-episode store
    /// still spent about 30 seconds on every subsequent preparation screen.
    func testRealCurrentLargeStoreReopensWithinLaunchBudget() async throws {
        let variable = "CURRENT_LARGE_STORE_DIRECTORY"
        guard let path = ProcessInfo.processInfo.environment[variable] else {
            throw XCTSkip("Set TEST_RUNNER_\(variable) to a copied V10 application-support directory")
        }
        try copyStoreSet(from: URL(fileURLWithPath: path, isDirectory: true))
        XCTAssertEqual(try storeMajorVersion(at: storeURL), 10)

        let started = ContinuousClock.now
        let reopened = try await StoreMigrationEngine().openOrMigrate(at: storeURL)
        let elapsed = ContinuousClock.now - started
        let components = elapsed.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        let podcastCount = try reopened.mainContext.fetchCount(FetchDescriptor<Podcast>())
        let episodeCount = try reopened.mainContext.fetchCount(FetchDescriptor<Episode>())

        XCTAssertEqual(podcastCount, 99)
        XCTAssertEqual(episodeCount, 169_946)
        XCTAssertLessThan(
            seconds, 5,
            "An already-migrated library must reopen with margin inside the scene watchdog"
        )
        print(String(format:
            "REALCURRENTOPEN|podcasts|%d|episodes|%d|seconds|%.3f",
            podcastCount, episodeCount, seconds
        ))
    }

    /// Opt-in proof against a disposable copy of the untouched build-161 V6
    /// backup, not a freshly constructed scale fixture.
    func testRealBuild161V6FixtureThroughRetainedColumnSchema() async throws {
        let variable = "SYNC_MIGRATION_REAL_V6_DIRECTORY"
        guard let path = ProcessInfo.processInfo.environment[variable] else {
            throw XCTSkip("Set TEST_RUNNER_\(variable) to the verified V6 backup directory")
        }
        try copyStoreSet(from: URL(fileURLWithPath: path, isDirectory: true))
        try injectV6FixtureBookmark()
        let sourceState = try realV6StateSnapshot()
        XCTAssertEqual(sourceState.subscriptions.count, 666)
        XCTAssertEqual(sourceState.folders.count, 4)
        XCTAssertEqual(sourceState.folderMemberships.count, 5)
        XCTAssertEqual(sourceState.episodeFolderMemberships.count, 1)
        XCTAssertEqual(sourceState.inbox.count, 2_548)
        XCTAssertEqual(sourceState.queue.count, 42)
        XCTAssertEqual(sourceState.positions.count, 14)
        XCTAssertEqual(sourceState.bookmarks.count, 1)
        XCTAssertEqual(sourceState.history.count, 713)
        XCTAssertEqual(sourceState.settings.count, 16)
        XCTAssertEqual(sourceState.downloaded.count, 43)
        try materializePreSplitFixtureDownloads()
        let beforeBytes = try storeSetSize()
        let allocatedBlockSampler = MigrationAllocatedBlockSampler(rootURL: directory)
        let baselineAllocatedBytes = try allocatedBlockSampler.start()
        let volumeSampler = MigrationVolumeFreeSpaceSampler(url: directory)
        let baselineAvailableBytes = try volumeSampler.start()
        let start = DispatchTime.now().uptimeNanoseconds
        let migrated = try await StoreMigrationEngine().openOrMigrate(at: storeURL)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        let maximumAllocatedBytes = try allocatedBlockSampler.stop()
        let minimumAvailableBytes = volumeSampler.stop()
        let context = migrated.mainContext
        let attributedPeakBytes = maximumAllocatedBytes - baselineAllocatedBytes
        let attributedPeakMultiple = Double(attributedPeakBytes) / Double(beforeBytes)
        let volumeDiagnosticPeakBytes = baselineAvailableBytes - minimumAvailableBytes
        let volumeDiagnosticPeakMultiple = Double(volumeDiagnosticPeakBytes)
            / Double(beforeBytes)

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Podcast>()), 666)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Episode>()), 241_759)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<QueueItem>()), 42)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ListeningSession>()), 713)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PodcastFolder>()), 4)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FolderMembership>()), 5)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<EpisodeFolderMembership>()), 1)
        let downloadPaths = try context.fetch(FetchDescriptor<LocalEpisodeState>())
            .filter { $0.downloadPath != nil }
        XCTAssertEqual(downloadPaths.count, 43)
        XCTAssertTrue(downloadPaths.allSatisfy { $0.downloadStatus == .downloaded })
        let internalKeys = [
            StoreMigration.splitCompletionKey, StoreMigration.identityRepairCompletionKey,
        ]
        let settingCount = try context.fetch(FetchDescriptor<AppSetting>()).count
            + context.fetch(FetchDescriptor<LocalAppSetting>())
                .filter { !internalKeys.contains($0.key) }.count
        XCTAssertEqual(settingCount, 16)
        XCTAssertEqual(try storeMajorVersion(at: storeURL), 11)
        XCTAssertEqual(try integrityCheck(at: storeURL), ["ok"])
        XCTAssertEqual(try integrityCheck(at: StoreMigration.localStoreURL(for: storeURL)), ["ok"])
        assertRealStatePreserved(try realV10StateSnapshot(), sourceState)
        let afterBytes = try storeSetSize()
        print(String(format:
            "REALV6MIGRATION|seconds|%.3f|beforeBytes|%lld|afterBytes|%lld"
                + "|attributedPeakBytes|%lld|attributedPeakMultiple|%.6f"
                + "|volumeDiagnosticPeakBytes|%lld|volumeDiagnosticPeakMultiple|%.6f",
            elapsed, beforeBytes, afterBytes,
            attributedPeakBytes, attributedPeakMultiple,
            volumeDiagnosticPeakBytes, volumeDiagnosticPeakMultiple
        ))
        XCTAssertLessThan(
            elapsed, 15,
            "Aged-store migration leaves too little margin inside the 20-second launch watchdog"
        )
        XCTAssertLessThan(
            attributedPeakMultiple, MigrationBackupManager.initialFreeSpaceMultiplier,
            "The initial disk gate must exceed the observed real-fixture peak"
        )
        try assertEpisodeSaveSurvivesReopen(migrated)
    }

    func testRealBuild161V6InsufficientSpaceReportsExactShortfallAndRetries() throws {
        let variable = "SYNC_MIGRATION_REAL_V6_DIRECTORY"
        guard let path = ProcessInfo.processInfo.environment[variable] else {
            throw XCTSkip("Set TEST_RUNNER_\(variable) to the verified V6 backup directory")
        }
        try copyStoreSet(from: URL(fileURLWithPath: path, isDirectory: true))
        try injectV6FixtureBookmark()
        let sourceState = try realV6StateSnapshot()
        try materializePreSplitFixtureDownloads()
        let sourceBytes = try storeSetSize()
        let requiredBytes = Int64(
            (Double(sourceBytes) * MigrationBackupManager.initialFreeSpaceMultiplier)
                .rounded(.up)
        )
        let expectedShortfall: Int64 = 512_000_001
        let availableBytes = requiredBytes - expectedShortfall
        MigrationBackupManager.injectedAvailableBytes = availableBytes

        let firstLoad = ModelContainerFactory.load(at: storeURL)
        guard case .recovery(.backupUnavailable(
            let reportedRequired?, let reportedAvailable?
        )) = firstLoad else {
            return XCTFail("Expected the storage recovery path, got \(firstLoad)")
        }
        XCTAssertEqual(reportedRequired, requiredBytes)
        XCTAssertEqual(reportedAvailable, availableBytes)
        XCTAssertEqual(reportedRequired - reportedAvailable, expectedShortfall)
        XCTAssertEqual(
            StoreRecoveryScreen.formattedStorageRequirement(bytes: expectedShortfall),
            "513 MB"
        )
        XCTAssertEqual(try storeMajorVersion(at: storeURL), 6)
        assertRealStatePreserved(try realV6StateSnapshot(), sourceState)
        XCTAssertNil(MigrationBackupManager.latestRecordedBackup(at: storeURL))

        // Simulate the in-app storage action making the reported requirement
        // available, then drive the same launch retry entry point.
        MigrationBackupManager.injectedAvailableBytes = requiredBytes
        let retryLoad = ModelContainerFactory.load(at: storeURL)
        guard case .ready(let migrated) = retryLoad else {
            return XCTFail("Expected retry to migrate successfully, got \(retryLoad)")
        }
        assertRealStatePreserved(try realV10StateSnapshot(), sourceState)
        print(
            "REALV6GATE|requiredBytes|\(requiredBytes)|availableBytes|\(availableBytes)"
                + "|shortfallBytes|\(expectedShortfall)|spokenShortfall|513 MB"
        )
        try assertEpisodeSaveSurvivesReopen(migrated)
    }

    func testRealBuild161V6InjectedInflightDownloadsMigrateAndSave() throws {
        let variable = "SYNC_MIGRATION_REAL_V6_DIRECTORY"
        guard let path = ProcessInfo.processInfo.environment[variable] else {
            throw XCTSkip("Set TEST_RUNNER_\(variable) to the verified V6 backup directory")
        }
        try copyStoreSet(from: URL(fileURLWithPath: path, isDirectory: true))
        let identities: [(guid: String, status: DownloadStatus)] = try autoreleasepool {
            let schema = Schema(versionedSchema: EarshotSchemaV6.self)
            let container = try ModelContainer(
                for: schema,
                configurations: ModelConfiguration(
                    schema: schema, url: storeURL, cloudKitDatabase: .none
                )
            )
            var descriptor = FetchDescriptor<EarshotSchemaV5.Episode>(
                predicate: #Predicate { $0.downloadPath == nil }
            )
            descriptor.fetchLimit = 2
            let episodes = try container.mainContext.fetch(descriptor)
            XCTAssertEqual(episodes.count, 2)
            let statuses: [(DownloadStatus, ActiveDownloadState)] = [
                (.pending, .pending), (.downloading, .downloading),
            ]
            for (episode, state) in zip(episodes, statuses) {
                episode.downloadStatus = state.0
                container.mainContext.insert(EarshotSchemaV5.ActiveDownload(
                    episode: episode, state: state.1
                ))
            }
            try container.mainContext.save()
            return zip(episodes, statuses).map { ($0.0.guid, $0.1.0) }
        }

        let migrated = try StoreMigration.openOrMigrate(at: storeURL)
        let rows = try migrated.mainContext.fetch(FetchDescriptor<LocalEpisodeState>())
        for identity in identities {
            let row = try XCTUnwrap(rows.first { $0.episodeGUID == identity.guid })
            XCTAssertEqual(row.downloadStatus, identity.status)
        }
        XCTAssertEqual(try storeMajorVersion(at: storeURL), 11)
        XCTAssertEqual(
            try integrityCheck(at: StoreMigration.localStoreURL(for: storeURL)), ["ok"]
        )
        print(
            "REALV6INFLIGHT|pending|1|downloading|1|migratedRows|\(identities.count)"
        )
        try assertEpisodeSaveSurvivesReopen(migrated)
    }

    func testRealBuild161V6ForcedFailureRestoresBackupAndRetries() throws {
        let variable = "SYNC_MIGRATION_REAL_V6_DIRECTORY"
        guard let path = ProcessInfo.processInfo.environment[variable] else {
            throw XCTSkip("Set TEST_RUNNER_\(variable) to the verified V6 backup directory")
        }
        try copyStoreSet(from: URL(fileURLWithPath: path, isDirectory: true))
        try injectV6FixtureBookmark()
        let sourceState = try realV6StateSnapshot()
        try materializePreSplitFixtureDownloads()
        StoreMigration.injectedFailurePoint = .afterSplitMarker

        XCTAssertThrowsError(try autoreleasepool {
            _ = try StoreMigration.openOrMigrate(at: storeURL)
        }) { error in
            XCTAssertEqual(
                error as? StoreMigration.InjectedMigrationFailure,
                .init(point: .afterSplitMarker)
            )
        }
        StoreMigration.injectedFailurePoint = nil
        let backup = try XCTUnwrap(MigrationBackupManager.latestRestorableBackup(at: storeURL))
        XCTAssertEqual(backup.sourceSchemaMajor, 6)
        XCTAssertEqual(backup.targetSchemaMajor, 11)

        try MigrationBackupManager.restore(backup, at: storeURL)
        XCTAssertEqual(try storeMajorVersion(at: storeURL), 6)
        XCTAssertEqual(try integrityCheck(at: storeURL), ["ok"])
        assertRealStatePreserved(try realV6StateSnapshot(), sourceState)

        let retried = try StoreMigration.openOrMigrate(at: storeURL)
        assertRealStatePreserved(try realV10StateSnapshot(), sourceState)
        print(
            "REALV6RESTORE|backupBytes|\(backup.byteCount)|restoredSchema|6|retrySchema|10"
        )
        try assertEpisodeSaveSurvivesReopen(retried)
    }

    func testRealBuild161V6FixtureOnActuallyFullVolume() throws {
        let fixtureVariable = "SYNC_MIGRATION_REAL_V6_DIRECTORY"
        let runVariable = "RUN_SYNC_MIGRATION_ENOSPC"
        guard ProcessInfo.processInfo.environment[runVariable] != nil,
              let path = ProcessInfo.processInfo.environment[fixtureVariable] else {
            throw XCTSkip(
                "Set TEST_RUNNER_\(runVariable)=1 and TEST_RUNNER_\(fixtureVariable) to run the real ENOSPC profile."
            )
        }
        try copyStoreSet(from: URL(fileURLWithPath: path, isDirectory: true))
        let beforeBytes = try storeSetSize()
        _ = try XCTUnwrap(
            ModelContainerFactory.backupStoreFiles(at: storeURL),
            "the real ENOSPC run requires a complete pre-migration backup"
        )
        StoreMigration.bypassSafetyBackupForENOSPCTest = true

        XCTAssertThrowsError(try autoreleasepool {
            _ = try StoreMigration.openOrMigrate(at: storeURL)
        }) { error in
            guard case StoreMigrationFailure.operational(let underlying) = error else {
                return XCTFail("Expected operational ENOSPC, got \(error)")
            }
            var chain: [String] = []
            var current: NSError? = underlying as NSError
            while let error = current {
                chain.append("\(error.domain):\(error.code):\(error.localizedDescription)")
                current = error.userInfo[NSUnderlyingErrorKey] as? NSError
            }
            print("REALV6ENOSPC|errorChain|\(chain.joined(separator: " <- "))")
        }

        let filesAfterFailure = try FileManager.default.subpathsOfDirectory(atPath: directory.path)
            .compactMap { relative -> String? in
                let url = directory.appending(path: relative)
                guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
                    return nil
                }
                return "\(relative):\(size)"
            }
            .sorted()
        print("REALV6ENOSPC|filesAfterFailure|\(filesAfterFailure.joined(separator: ","))")

        let backupRoot = directory.appending(path: "store-backups", directoryHint: .isDirectory)
        let backupDirectories = try FileManager.default.contentsOfDirectory(
            at: backupRoot, includingPropertiesForKeys: nil
        )
        let backupDirectory = try XCTUnwrap(backupDirectories.first)
        let rescuedBackupDirectory = FileManager.default.temporaryDirectory.appending(
            path: "rescued-migration-backup-\(UUID())", directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: rescuedBackupDirectory) }
        try FileManager.default.copyItem(at: backupDirectory, to: rescuedBackupDirectory)

        // Release enough blocks for SQLite to read and recover its WAL after the
        // genuine ENOSPC. The separately rebuilt local store is disposable until
        // its completion marker exists. The backup is copied off the constrained
        // test volume first so both source and snapshot can be inspected.
        try FileManager.default.removeItem(at: backupRoot)
        ModelContainerFactory.removeStoreFiles(
            at: StoreMigration.localStoreURL(for: storeURL)
        )

        // Core Data records V10 before the failed WAL checkpoint. The working
        // source is therefore not the original V6 store after real ENOSPC.
        XCTAssertEqual(try storeMajorVersion(at: storeURL), 10)
        XCTAssertEqual(try integrityCheck(at: storeURL), ["ok"])
        XCTAssertEqual(try sqliteScalar(at: storeURL, sql: "SELECT COUNT(*) FROM ZPODCAST"), 666)
        XCTAssertEqual(
            try sqliteScalar(at: storeURL, sql: "SELECT COUNT(*) FROM ZEPISODE"),
            241_759
        )
        let backupURL = rescuedBackupDirectory.appending(path: "default.store")
        XCTAssertEqual(try storeMajorVersion(at: backupURL), 6)
        XCTAssertEqual(try integrityCheck(at: backupURL), ["ok"])
        let remainingSampler = MigrationVolumeFreeSpaceSampler(url: directory)
        let remainingBytes = try remainingSampler.start()
        _ = remainingSampler.stop()
        print(String(format:
            "REALV6ENOSPC|beforeMB|%.1f|remainingMB|%.1f|backupCount|%d",
            Double(beforeBytes) / 1_048_576,
            Double(remainingBytes) / 1_048_576,
            backupDirectories.count
        ))
    }

    func testRealBuild161V6HardGateStopsBeforeWritingOnConstrainedVolume() throws {
        let fixtureVariable = "SYNC_MIGRATION_REAL_V6_DIRECTORY"
        let runVariable = "RUN_SYNC_MIGRATION_HARD_GATE"
        guard ProcessInfo.processInfo.environment[runVariable] != nil,
              let path = ProcessInfo.processInfo.environment[fixtureVariable] else {
            throw XCTSkip(
                "Set TEST_RUNNER_\(runVariable)=1 and TEST_RUNNER_\(fixtureVariable) to run the real hard-gate profile."
            )
        }
        try copyStoreSet(from: URL(fileURLWithPath: path, isDirectory: true))

        XCTAssertThrowsError(try autoreleasepool {
            _ = try StoreMigration.openOrMigrate(at: storeURL)
        }) { error in
            guard case StoreMigrationFailure.backupUnavailable(let underlying) = error,
                  case MigrationBackupError.insufficientStorage = underlying else {
                return XCTFail("Expected the measured storage gate, got \(error)")
            }
        }

        XCTAssertEqual(try storeMajorVersion(at: storeURL), 6)
        XCTAssertEqual(try integrityCheck(at: storeURL), ["ok"])
        XCTAssertEqual(try sqliteScalar(at: storeURL, sql: "SELECT COUNT(*) FROM ZPODCAST"), 666)
        XCTAssertEqual(
            try sqliteScalar(at: storeURL, sql: "SELECT COUNT(*) FROM ZEPISODE"),
            241_759
        )
        XCTAssertNil(MigrationBackupManager.latestRecordedBackup(at: storeURL))
    }

    /// Opt-in proof against a disposable copy of the settled device's existing
    /// V8 pair. Counts and every local episode-state value must survive exactly;
    /// the V7 bridge marker must remain absent.
    func testRealSettledV8FixtureMovesForwardInPlace() throws {
        let variable = "SYNC_MIGRATION_REAL_V8_DIRECTORY"
        guard let path = ProcessInfo.processInfo.environment[variable] else {
            throw XCTSkip("Set TEST_RUNNER_\(variable) to the settled V8 copy directory")
        }
        try copyStoreSet(from: URL(fileURLWithPath: path, isDirectory: true))
        let source = try readV8FixtureSnapshot()
        XCTAssertGreaterThan(source.episodes, 240_000)
        let beforeBytes = try storeSetSize()
        let start = DispatchTime.now().uptimeNanoseconds
        let migrated = try StoreMigration.openOrMigrate(at: storeURL)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        let context = migrated.mainContext
        let destination = V8FixtureSnapshot(
            podcasts: try context.fetchCount(FetchDescriptor<Podcast>()),
            episodes: try context.fetchCount(FetchDescriptor<Episode>()),
            localPodcastStates: try context.fetchCount(FetchDescriptor<LocalPodcastState>()),
            localEpisodeStates: try context.fetch(FetchDescriptor<LocalEpisodeState>()).map {
                "\($0.podcastFeedURL)\u{1F}\($0.episodeGUID)\u{1F}"
                    + "\($0.downloadStatusRaw)\u{1F}\($0.downloadPath ?? "")"
            }.sorted()
        )
        XCTAssertEqual(destination, source)
        XCTAssertEqual(try storeMajorVersion(at: storeURL), 11)
        XCTAssertNil(LocalAppSettingIdentity.value(
            for: StoreMigration.bridgeCompletionKey, in: context
        ))
        XCTAssertEqual(LocalAppSettingIdentity.value(
            for: StoreMigration.identityRepairCompletionKey, in: context
        ), "1")
        XCTAssertEqual(try integrityCheck(at: storeURL), ["ok"])
        XCTAssertEqual(try integrityCheck(at: StoreMigration.localStoreURL(for: storeURL)), ["ok"])
        let afterBytes = try storeSetSize()
        print(String(format:
            "REALV8MIGRATION|seconds|%.3f|beforeMB|%.1f|afterMB|%.1f|episodes|%d",
            elapsed, Double(beforeBytes) / 1_048_576, Double(afterBytes) / 1_048_576,
            destination.episodes
        ))
        XCTAssertLessThan(
            elapsed, 15,
            "Existing-V8 forward migration leaves too little launch-watchdog margin"
        )
        try assertEpisodeSaveSurvivesReopen(migrated)
    }

    /// Opt-in regression proof against a disposable copy of the build-162 V9
    /// store whose required tombstone is NULL on every existing Episode row.
    func testRealBuild162V9NullTombstoneFixtureMigratesAndSaves() throws {
        let variable = "SYNC_MIGRATION_REAL_V9_DIRECTORY"
        guard let path = ProcessInfo.processInfo.environment[variable] else {
            throw XCTSkip("Set TEST_RUNNER_\(variable) to the preserved build-162 V9 directory")
        }
        try copyStoreSet(from: URL(fileURLWithPath: path, isDirectory: true))
        let localURL = StoreMigration.localStoreURL(for: storeURL)
        XCTAssertEqual(try storeMajorVersion(at: storeURL), 9)
        XCTAssertEqual(try storeMajorVersion(at: localURL), 9)
        XCTAssertEqual(
            try sqliteScalar(
                at: storeURL,
                sql: "SELECT COUNT(*) FROM ZEPISODE WHERE ZLEGACYDOWNLOADSTATUS IS NULL"
            ),
            242_169
        )

        let beforeBytes = try storeSetSize()
        let options = XCTMeasureOptions()
        options.iterationCount = 1
        var migrationResult: Result<ModelContainer, Error>?
        var elapsed = 0.0
        measure(metrics: [XCTStorageMetric()], options: options) {
            let start = DispatchTime.now().uptimeNanoseconds
            migrationResult = Result { try StoreMigration.openOrMigrate(at: storeURL) }
            elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        }
        let migrated = try XCTUnwrap(migrationResult).get()
        let afterBytes = try storeSetSize()

        XCTAssertEqual(try storeMajorVersion(at: storeURL), 11)
        XCTAssertEqual(try storeMajorVersion(at: localURL), 11)
        XCTAssertEqual(
            try migrated.mainContext.fetchCount(FetchDescriptor<Episode>()), 242_169
        )
        XCTAssertEqual(
            try sqliteScalar(
                at: storeURL,
                sql: "SELECT COUNT(*) FROM ZEPISODE WHERE ZLEGACYDOWNLOADSTATUS IS NULL"
            ),
            242_169,
            "V9 to V10 should relax nullability, not backfill the Episode table"
        )
        XCTAssertEqual(LocalAppSettingIdentity.value(
            for: StoreMigration.splitCompletionKey, in: migrated.mainContext
        ), "1")
        XCTAssertEqual(LocalAppSettingIdentity.value(
            for: StoreMigration.identityRepairCompletionKey, in: migrated.mainContext
        ), "1")
        XCTAssertEqual(try integrityCheck(at: storeURL), ["ok"])
        XCTAssertEqual(try integrityCheck(at: localURL), ["ok"])
        print(String(format:
            "REALV9MIGRATION|seconds|%.3f|beforeBytes|%lld|afterBytes|%lld|episodes|%d",
            elapsed, beforeBytes, afterBytes, 242_169
        ))

        try assertEpisodeSaveSurvivesReopen(
            migrated, marker: "Saved after build-162 V9 null repair"
        )
    }

    func testRestartFromCompletedV7PreflightFinishesSplit() throws {
        try seedV6()
        try autoreleasepool {
            let schema = Schema(versionedSchema: EarshotSchemaV7.self)
            let bridge = try ModelContainer(for: schema,
                migrationPlan: EarshotBridgeMigrationPlan.self,
                configurations: ModelConfiguration(
                    schema: schema, url: storeURL, cloudKitDatabase: .none
                ))
            let marker = StoreMigration.bridgeCompletionKey
            let rows = try bridge.mainContext.fetch(FetchDescriptor<EarshotSchemaV7.LocalAppSetting>(
                predicate: #Predicate { $0.key == marker }))
            XCTAssertEqual(rows.count, 1)
        }
        let resumed = try StoreMigration.openOrMigrate(at: storeURL)
        XCTAssertEqual(try resumed.mainContext.fetchCount(FetchDescriptor<Podcast>()), 1)
        XCTAssertEqual(try resumed.mainContext.fetchCount(FetchDescriptor<LocalEpisodeState>()), 2)
        XCTAssertEqual(LocalAppSettingIdentity.value(for: StoreMigration.splitCompletionKey,
            in: resumed.mainContext), "1")
        try assertEpisodeSaveSurvivesReopen(resumed)
    }

    func testRestartAfterInjectedBridgeMarkerFailureRecoversCleanly() throws {
        try seedV6()
        StoreMigration.injectedFailurePoint = .afterBridgeMarker
        XCTAssertThrowsError(try autoreleasepool {
            let schema = Schema(versionedSchema: EarshotSchemaV7.self)
            _ = try ModelContainer(
                for: schema,
                migrationPlan: EarshotBridgeMigrationPlan.self,
                configurations: ModelConfiguration(
                    schema: schema, url: storeURL, cloudKitDatabase: .none
                )
            )
        })
        StoreMigration.injectedFailurePoint = nil

        let recovered = try StoreMigration.openOrMigrate(at: storeURL)
        try assertRecoveredFixture(recovered)
    }

    func testRestartBeforeSplitMarkerRecoversCleanly() throws {
        try assertRestartRecovery(at: .beforeSplitMarker)
    }

    func testRestartAfterSplitMarkerRecoversCleanly() throws {
        try assertRestartRecovery(at: .afterSplitMarker)
    }

    func testRestartBeforeIdentityRepairMarkerRecoversCleanly() throws {
        try assertRestartRecovery(at: .beforeIdentityRepairMarker)
    }

    func testRestartAfterIdentityRepairMarkerRecoversCleanly() throws {
        try assertRestartRecovery(at: .afterIdentityRepairMarker)
    }

    private func assertRestartRecovery(
        at point: StoreMigration.InjectedFailurePoint
    ) throws {
        try seedV6()
        StoreMigration.injectedFailurePoint = point
        XCTAssertThrowsError(try autoreleasepool {
            _ = try StoreMigration.openOrMigrate(at: storeURL)
        }) { error in
            XCTAssertEqual(
                error as? StoreMigration.InjectedMigrationFailure,
                .init(point: point)
            )
        }

        // A real force-quit clears process memory before the next launch.
        StoreMigration.injectedFailurePoint = nil
        var recovered: ModelContainer? = try StoreMigration.openOrMigrate(at: storeURL)
        try assertRecoveredFixture(XCTUnwrap(recovered))
        recovered = nil

        // The recovered result itself must be a stable next-launch state.
        let reopened = try StoreMigration.openOrMigrate(at: storeURL)
        try assertRecoveredFixture(reopened)
    }

    private func assertRecoveredFixture(_ container: ModelContainer) throws {
        let context = container.mainContext
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Podcast>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Episode>()), 3)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<QueueItem>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Bookmark>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ListeningSession>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FolderMembership>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<EpisodeFolderMembership>()), 1)
        XCTAssertEqual(Set(try context.fetch(FetchDescriptor<LocalEpisodeState>()).map(\.episodeGUID)), [
            "downloaded", "pending",
        ])
        XCTAssertEqual(
            LocalAppSettingIdentity.value(for: StoreMigration.splitCompletionKey, in: context),
            "1"
        )
        XCTAssertEqual(
            LocalAppSettingIdentity.value(
                for: StoreMigration.identityRepairCompletionKey, in: context
            ),
            "1"
        )
        XCTAssertEqual(try storeMajorVersion(at: storeURL), 11)
        XCTAssertEqual(try integrityCheck(at: storeURL), ["ok"])
        XCTAssertEqual(
            try integrityCheck(at: StoreMigration.localStoreURL(for: storeURL)), ["ok"]
        )
        try assertEpisodeSaveSurvivesReopen(container)
    }

    func testScaleMigrationProfile() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUN_SYNC_MIGRATION_SCALE"] != nil,
            "Set TEST_RUNNER_RUN_SYNC_MIGRATION_SCALE=1 to run the 242k migration profile."
        )
        let count = Int(ProcessInfo.processInfo.environment["SYNC_MIGRATION_EPISODES"] ?? "")
            ?? 242_500
        try seedScaleV6(episodeCount: count)
        let sourceStoreSetBytes = [
            storeURL,
            URL(fileURLWithPath: storeURL.path + "-wal"),
            URL(fileURLWithPath: storeURL.path + "-shm"),
        ].reduce(Int64(0)) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + Int64(size)
        }
        let memorySampler = MigrationMemorySampler()
        let baselineRSS = memorySampler.start()
        let start = DispatchTime.now().uptimeNanoseconds
        let engine = StoreMigrationEngine()
        let migration = Task { try await engine.openOrMigrate(at: storeURL) }
        var preparationMilliseconds: Double?
        var iterator = engine.progressUpdates.makeAsyncIterator()
        while let stage = await iterator.next() {
            if stage == .migratingMirroredStore, preparationMilliseconds == nil {
                preparationMilliseconds = Double(
                    DispatchTime.now().uptimeNanoseconds - start
                ) / 1_000_000
            }
        }
        let migrated = try await migration.value
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        let migrationPeakRSS = memorySampler.stop()
        let migrationRSSGrowth = max(0, migrationPeakRSS - baselineRSS)
        let processPeakRSS = Self.peakResidentMemoryMB()
        XCTAssertEqual(try migrated.mainContext.fetchCount(FetchDescriptor<Episode>()), count)
        XCTAssertEqual(try migrated.mainContext.fetchCount(FetchDescriptor<Podcast>()), 666)
        XCTAssertEqual(try migrated.mainContext.fetchCount(FetchDescriptor<Episode>(
            predicate: #Predicate { $0.podcast != nil }
        )), count)
        XCTAssertEqual(try migrated.mainContext.fetchCount(FetchDescriptor<LocalEpisodeState>()), 44)
        print(String(format:
            "SYNCMIGRATION|podcasts|%d|episodes|%d|relatedEpisodes|%d|sourceStoreSetBytes|%lld|preparationMs|%.3f|migrationMs|%.0f|baselineRssMB|%.0f|migrationPeakRssMB|%.0f|migrationRssGrowthMB|%.0f|processPeakIncludingSeedMB|%.0f",
            666, count, count, sourceStoreSetBytes, preparationMilliseconds ?? -1,
            elapsed, baselineRSS, migrationPeakRSS,
            migrationRSSGrowth, processPeakRSS
        ))
        XCTAssertLessThan(elapsed, 20_000, "migration entered launch-watchdog territory")
        XCTAssertLessThan(
            migrationRSSGrowth, 500,
            "migration added enough resident memory to approach known device jetsam territory"
        )
        try assertEpisodeSaveSurvivesReopen(migrated)
    }
}

/// Opt-in measurements for the 2026-08-06 Settings reset watchdog incident.
///
/// Uses the repository's existing `RUN_SYNC_MIGRATION_SCALE` opt-in gate. The
/// production reset's NotificationCenter post and both filesystem removals are
/// deliberately excluded: their FileManager locations are process-global and
/// cannot be redirected to a test-owned root. Each timing therefore measures
/// only the exact SwiftData fetch/delete sequence plus `ModelContext.save()`.
@MainActor
final class ResetWatchdogMeasurementTests: XCTestCase {
    private struct StorePaths {
        let root: URL
        let primary: URL
        let local: URL
    }

    private struct Counts {
        let podcasts: Int
        let episodes: Int
        let queueItems: Int
        let listeningSessions: Int
        let bookmarks: Int
        let podcastFolders: Int
        let folderMemberships: Int
        let episodeFolderMemberships: Int
        let recentlyExpired: Int
        let quickActions: Int
        let appSettings: Int
        let localPodcastStates: Int
        let localEpisodeStates: Int
        let localAppSettings: Int

        var text: String {
            [
                "Podcast=\(podcasts)", "Episode=\(episodes)",
                "QueueItem=\(queueItems)", "ListeningSession=\(listeningSessions)",
                "Bookmark=\(bookmarks)", "PodcastFolder=\(podcastFolders)",
                "FolderMembership=\(folderMemberships)",
                "EpisodeFolderMembership=\(episodeFolderMemberships)",
                "RecentlyExpired=\(recentlyExpired)",
                "QuickActionConfig=\(quickActions)", "AppSetting=\(appSettings)",
                "LocalPodcastState=\(localPodcastStates)",
                "LocalEpisodeState=\(localEpisodeStates)",
                "LocalAppSetting=\(localAppSettings)",
            ].joined(separator: ",")
        }
    }

    private enum Candidate: String, CaseIterable {
        case currentA = "a-current-podcasts-first"
        case episodesFirstB = "b-episodes-first"
        case batchC = "c-batch-dependency-order"
        case filesD = "d-remove-store-files"
    }

    private func requireOptIn() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUN_SYNC_MIGRATION_SCALE"] != nil,
            "Set TEST_RUNNER_RUN_SYNC_MIGRATION_SCALE=1 to run opt-in reset measurements."
        )
    }

    func testResetRealShapeCurrentCompletion() throws {
        try requireOptIn()
        let paths = try copiedIncidentStore(label: "real-current")
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let container = try openV10(paths)
        let context = ModelContext(container)
        let before = try counts(context)
        let primaryVersion = try storeVersion(paths.primary)
        let localVersion = try storeVersion(paths.local)
        print("RESETREAL|pre|primaryVersion|\(primaryVersion)|localVersion|\(localVersion)|counts|\(before.text)")

        let sampler = MigrationMemorySampler()
        let baselineRSS = sampler.start()
        let result = runObjectDelete(candidate: .currentA, context: context)
        let peakRSS = sampler.stop()
        let after = try counts(context)
        let primaryIntegrity = try integrityCheck(paths.primary).joined(separator: ",")
        let localIntegrity = try integrityCheck(paths.local).joined(separator: ",")
        let reopen = (try? openV10(paths)) != nil ? "success" : "failure"
        print(String(format:
            "RESETREAL|result|candidate|%@|seconds|%.6f|save|%@|baselineRssMB|%.3f|peakRssMB|%.3f|growthRssMB|%.3f|counts|%@|primaryIntegrity|%@|localIntegrity|%@|reopen|%@|filesystemSteps|skipped",
            Candidate.currentA.rawValue, result.seconds, result.save,
            baselineRSS, peakRSS, max(0, peakRSS - baselineRSS), after.text,
            primaryIntegrity, localIntegrity, reopen
        ))
        XCTAssertEqual(result.save, "success")
        XCTAssertEqual(primaryIntegrity, "ok")
        XCTAssertEqual(localIntegrity, "ok")
        XCTAssertEqual(reopen, "success")
    }

    func testResetScalingSeries() throws {
        try requireOptIn()
        for episodeCount in [2_500, 5_000, 10_000, 20_000, 40_000] {
            do {
                let paths = try syntheticStore(
                    label: "scale-\(episodeCount)", podcastCount: 1,
                    episodeCount: episodeCount
                )
                defer { try? FileManager.default.removeItem(at: paths.root) }
                let container = try openV10(paths)
                let context = ModelContext(container)
                let before = try counts(context)
                let result = runObjectDelete(candidate: .currentA, context: context)
                let after = try counts(context)
                let primaryIntegrity = try integrityCheck(paths.primary).joined(separator: ",")
                let localIntegrity = try integrityCheck(paths.local).joined(separator: ",")
                print(String(format:
                    "RESETSCALE|episodes|%d|podcasts|1|seconds|%.6f|save|%@|before|%@|after|%@|primaryIntegrity|%@|localIntegrity|%@|filesystemSteps|skipped",
                    episodeCount, result.seconds, result.save, before.text, after.text,
                    primaryIntegrity, localIntegrity
                ))
            } catch {
                print("RESETSCALE|episodes|\(episodeCount)|error|\(String(reflecting: error))")
                XCTFail("Scale \(episodeCount) failed: \(error)")
            }
        }
    }

    func testResetParentArrayDiscriminator() throws {
        try requireOptIn()
        for (label, podcastCount) in [("A", 1), ("B", 4), ("C", 16)] {
            do {
                let paths = try syntheticStore(
                    label: "parent-\(label)", podcastCount: podcastCount,
                    episodeCount: 40_000
                )
                defer { try? FileManager.default.removeItem(at: paths.root) }
                let container = try openV10(paths)
                let context = ModelContext(container)
                let result = runObjectDelete(candidate: .currentA, context: context)
                let after = try counts(context)
                print(String(format:
                    "RESETPARENT|config|%@|podcasts|%d|episodes|40000|seconds|%.6f|save|%@|after|%@|primaryIntegrity|%@|localIntegrity|%@|filesystemSteps|skipped",
                    label, podcastCount, result.seconds, result.save, after.text,
                    try integrityCheck(paths.primary).joined(separator: ","),
                    try integrityCheck(paths.local).joined(separator: ",")
                ))
            } catch {
                print("RESETPARENT|config|\(label)|error|\(String(reflecting: error))")
                XCTFail("Parent configuration \(label) failed: \(error)")
            }
        }
    }

    func testResetCandidateRemediesSynthetic() throws {
        try requireOptIn()
        for candidate in Candidate.allCases {
            do {
                let paths = try syntheticStore(
                    label: "candidate-synthetic-\(candidate.rawValue)",
                    podcastCount: 1, episodeCount: 40_000
                )
                defer { try? FileManager.default.removeItem(at: paths.root) }
                try measureCandidate(candidate, paths: paths, shape: "synthetic-1x40000")
            } catch {
                print("RESETCANDIDATE|shape|synthetic-1x40000|candidate|\(candidate.rawValue)|error|\(String(reflecting: error))")
                XCTFail("Synthetic candidate \(candidate.rawValue) failed: \(error)")
            }
        }
    }

    func testResetCandidateRemediesReal() throws {
        try requireOptIn()
        for candidate in Candidate.allCases {
            do {
                let paths = try copiedIncidentStore(label: "candidate-real-\(candidate.rawValue)")
                defer { try? FileManager.default.removeItem(at: paths.root) }
                try measureCandidate(candidate, paths: paths, shape: "real-10x53864")
            } catch {
                print("RESETCANDIDATE|shape|real-10x53864|candidate|\(candidate.rawValue)|error|\(String(reflecting: error))")
                XCTFail("Real candidate \(candidate.rawValue) failed: \(error)")
            }
        }
    }

    func testBatchDeleteErrorIsolation() throws {
        try requireOptIn()

        try diagnoseBatchDelete(
            label: "two-config-no-inbound-cascade",
            open: openV10,
            delete: { context in try context.delete(model: AppSetting.self) }
        )
        try diagnoseBatchDelete(
            label: "two-config-with-cascade",
            open: openV10,
            delete: { context in try context.delete(model: Podcast.self) }
        )
        try diagnoseBatchDelete(
            label: "single-config-no-inbound-cascade",
            open: openMirroredOnly,
            delete: { context in try context.delete(model: AppSetting.self) }
        )
        try diagnoseBatchDelete(
            label: "single-config-with-cascade",
            open: openMirroredOnly,
            delete: { context in try context.delete(model: Podcast.self) }
        )
    }

    func testCurrentRealVarianceOneRun() throws {
        try requireOptIn()
        let mode = try XCTUnwrap(ProcessInfo.processInfo.environment["RESET_VARIANCE_WAL_MODE"])
        let run = try XCTUnwrap(ProcessInfo.processInfo.environment["RESET_VARIANCE_RUN_INDEX"])
        let paths = try copiedIncidentStore(label: "variance-\(mode)-\(run)")
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let primaryWAL = URL(fileURLWithPath: paths.primary.path + "-wal")
        let localWAL = URL(fileURLWithPath: paths.local.path + "-wal")
        let primaryBefore = fileSize(primaryWAL)
        let localBefore = fileSize(localWAL)
        if mode == "checkpointed" {
            try checkpointWAL(paths.primary)
            try checkpointWAL(paths.local)
        } else {
            XCTAssertEqual(mode, "present")
        }
        let primaryAfterPreparation = fileSize(primaryWAL)
        let localAfterPreparation = fileSize(localWAL)
        let container = try openV10(paths)
        let context = ModelContext(container)
        let primaryAtDelete = fileSize(primaryWAL)
        let localAtDelete = fileSize(localWAL)
        let sampler = MigrationMemorySampler()
        let baseline = sampler.start()
        let result = runObjectDelete(candidate: .currentA, context: context)
        let peak = sampler.stop()
        print(String(format: "RESETVARIANCE|mode|%@|run|%@|seconds|%.9f|save|%@|primaryWalBefore|%lld|localWalBefore|%lld|primaryWalAfterPreparation|%lld|localWalAfterPreparation|%lld|primaryWalAtDelete|%lld|localWalAtDelete|%lld|baselineRssMB|%.3f|peakRssMB|%.3f|growthRssMB|%.3f", mode, run, result.seconds, result.save, primaryBefore, localBefore, primaryAfterPreparation, localAfterPreparation, primaryAtDelete, localAtDelete, baseline, peak, max(0, peak - baseline)))
    }

    func testResetFalsifyingTwoByTwentyThousand() throws {
        try requireOptIn()
        let paths = try syntheticStore(
            label: "falsifier-2x20000", podcastCount: 2, episodeCount: 40_000
        )
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let container = try openV10(paths)
        let context = ModelContext(container)
        let sampler = MigrationMemorySampler()
        let baseline = sampler.start()
        let result = runObjectDelete(candidate: .currentA, context: context)
        let peak = sampler.stop()
        print(String(format: "RESETFALSIFIER|podcasts|2|episodesPerPodcast|20000|totalEpisodes|40000|seconds|%.9f|save|%@|baselineRssMB|%.3f|peakRssMB|%.3f|growthRssMB|%.3f|counts|%@|primaryIntegrity|%@|localIntegrity|%@", result.seconds, result.save, baseline, peak, max(0, peak - baseline), try counts(context).text, try integrityCheck(paths.primary).joined(separator: ","), try integrityCheck(paths.local).joined(separator: ",")))
    }

    private func diagnoseBatchDelete(
        label: String,
        open: (StorePaths) throws -> ModelContainer,
        delete: (ModelContext) throws -> Void
    ) throws {
        let paths = try copiedIncidentStore(label: "batch-isolation-\(label)")
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let container = try open(paths)
        let context = ModelContext(container)
        do {
            try delete(context)
            try context.save()
            print("RESETBATCHERROR|case|\(label)|result|success")
        } catch {
            print("RESETBATCHERROR|case|\(label)|result|failure")
            printNSError(error, prefix: "RESETBATCHERROR|case|\(label)|error")
        }
    }

    private func printNSError(_ error: Error, prefix: String) {
        let nsError = error as NSError
        print("\(prefix)|domain|\(nsError.domain)|code|\(nsError.code)|description|\(nsError.localizedDescription)")
        for key in nsError.userInfo.keys.map({ String(describing: $0) }).sorted() {
            let value = nsError.userInfo.first { String(describing: $0.key) == key }?.value
            print("\(prefix)|userInfo|\(key)|\(String(reflecting: value as Any))")
        }
        if let detailed = nsError.userInfo[NSDetailedErrorsKey] as? [NSError] {
            for (index, detail) in detailed.enumerated() {
                printNSError(detail, prefix: "\(prefix)|detailed|\(index)")
            }
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            printNSError(underlying, prefix: "\(prefix)|underlying")
        }
    }

    private func measureCandidate(
        _ candidate: Candidate, paths: StorePaths, shape: String
    ) throws {
        if candidate == .filesD {
            var container: ModelContainer? = try openV10(paths)
            let before = try counts(ModelContext(try XCTUnwrap(container)))
            let start = DispatchTime.now().uptimeNanoseconds
            container = nil
            autoreleasepool { }
            ModelContainerFactory.removeStoreFiles(at: paths.primary)
            ModelContainerFactory.removeStoreFiles(at: paths.local)
            let reopened = try openV10(paths)
            try reopened.mainContext.save()
            let seconds = elapsedSeconds(since: start)
            let after = try counts(reopened.mainContext)
            print(String(format:
                "RESETCANDIDATE|shape|%@|candidate|%@|seconds|%.6f|save|success|before|%@|after|%@|primaryIntegrity|%@|localIntegrity|%@|reopen|success|filesystemSteps|store-files-only|semantics|different",
                shape, candidate.rawValue, seconds, before.text, after.text,
                try integrityCheck(paths.primary).joined(separator: ","),
                try integrityCheck(paths.local).joined(separator: ",")
            ))
            return
        }

        let container = try openV10(paths)
        let context = ModelContext(container)
        let before = try counts(context)
        let result: (seconds: Double, save: String)
        if candidate == .batchC {
            result = runBatchDelete(context: context)
        } else {
            result = runObjectDelete(candidate: candidate, context: context)
        }
        let after = try counts(context)
        let reopen = (try? openV10(paths)) != nil ? "success" : "failure"
        print(String(format:
            "RESETCANDIDATE|shape|%@|candidate|%@|seconds|%.6f|save|%@|before|%@|after|%@|primaryIntegrity|%@|localIntegrity|%@|reopen|%@|filesystemSteps|skipped|semantics|current-database-scope",
            shape, candidate.rawValue, result.seconds, result.save, before.text, after.text,
            try integrityCheck(paths.primary).joined(separator: ","),
            try integrityCheck(paths.local).joined(separator: ","), reopen
        ))
    }

    private func runObjectDelete(
        candidate: Candidate, context: ModelContext
    ) -> (seconds: Double, save: String) {
        let start = DispatchTime.now().uptimeNanoseconds
        if candidate == .episodesFirstB {
            deleteAll(Episode.self, context)
            deleteAll(Podcast.self, context)
        } else {
            deleteAll(Podcast.self, context)
            deleteAll(Episode.self, context)
        }
        deleteAll(QueueItem.self, context)
        deleteAll(ListeningSession.self, context)
        deleteAll(Bookmark.self, context)
        deleteAll(PodcastFolder.self, context)
        deleteAll(FolderMembership.self, context)
        deleteAll(EpisodeFolderMembership.self, context)
        deleteAll(RecentlyExpired.self, context)
        deleteAll(QuickActionConfig.self, context)
        deleteAll(AppSetting.self, context)
        let save: String
        do {
            try context.save()
            save = "success"
        } catch {
            save = "failure:\(String(reflecting: error))"
        }
        return (elapsedSeconds(since: start), save)
    }

    private func runBatchDelete(
        context: ModelContext
    ) -> (seconds: Double, save: String) {
        let start = DispatchTime.now().uptimeNanoseconds
        let save: String
        do {
            try context.delete(model: QueueItem.self)
            try context.delete(model: ListeningSession.self)
            try context.delete(model: Bookmark.self)
            try context.delete(model: FolderMembership.self)
            try context.delete(model: EpisodeFolderMembership.self)
            try context.delete(model: RecentlyExpired.self)
            try context.delete(model: Episode.self)
            try context.delete(model: PodcastFolder.self)
            try context.delete(model: Podcast.self)
            try context.delete(model: QuickActionConfig.self)
            try context.delete(model: AppSetting.self)
            try context.save()
            save = "success"
        } catch {
            save = "failure:\(String(reflecting: error))"
        }
        return (elapsedSeconds(since: start), save)
    }

    private func deleteAll<T: PersistentModel>(_ type: T.Type, _ context: ModelContext) {
        for object in (try? context.fetch(FetchDescriptor<T>())) ?? [] {
            context.delete(object)
        }
    }

    private func syntheticStore(
        label: String, podcastCount: Int, episodeCount: Int
    ) throws -> StorePaths {
        let paths = try temporaryPaths(label: label)
        autoreleasepool {
            do {
                let container = try openV10(paths)
                let context = ModelContext(container)
                let base = episodeCount / podcastCount
                let remainder = episodeCount % podcastCount
                for podcastIndex in 0..<podcastCount {
                    let podcast = Podcast(
                        feedURL: "https://reset-measurement.invalid/\(label)/\(podcastIndex)",
                        title: "Podcast \(podcastIndex)"
                    )
                    context.insert(podcast)
                    let count = base + (podcastIndex < remainder ? 1 : 0)
                    var episodes: [Episode] = []
                    episodes.reserveCapacity(count)
                    for episodeIndex in 0..<count {
                        let episode = Episode(
                            guid: "\(label)-\(podcastIndex)-\(episodeIndex)",
                            title: "Episode \(episodeIndex)",
                            audioURL: "https://reset-measurement.invalid/audio/\(podcastIndex)/\(episodeIndex).mp3",
                            pubDate: Date(timeIntervalSince1970: TimeInterval(episodeIndex))
                        )
                        context.insert(episode)
                        episodes.append(episode)
                    }
                    podcast.episodes = episodes
                    try context.save()
                }
            } catch {
                XCTFail("Synthetic seed \(label) failed: \(error)")
            }
        }
        return paths
    }

    private func copiedIncidentStore(label: String) throws -> StorePaths {
        let fixtureRoot = try XCTUnwrap(
            ProcessInfo.processInfo.environment["RESET_INCIDENT_FIXTURE_ROOT"],
            "Set TEST_RUNNER_RESET_INCIDENT_FIXTURE_ROOT to the read-only container backup."
        )
        let source = URL(fileURLWithPath: fixtureRoot, isDirectory: true)
            .appending(path: "Library/Application Support", directoryHint: .isDirectory)
        let paths = try temporaryPaths(label: label)
        for name in [
            "default.store", "default.store-wal", "default.store-shm",
            "earshot-local.store", "earshot-local.store-wal", "earshot-local.store-shm",
        ] {
            try FileManager.default.copyItem(
                at: source.appending(path: name), to: paths.root.appending(path: name)
            )
        }
        return paths
    }

    private func temporaryPaths(label: String) throws -> StorePaths {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "reset-watchdog-\(label)-\(UUID().uuidString)", directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return StorePaths(
            root: root,
            primary: root.appending(path: "default.store"),
            local: root.appending(path: "earshot-local.store")
        )
    }

    private func openV10(_ paths: StorePaths) throws -> ModelContainer {
        let full = Schema(versionedSchema: EarshotSchemaV11.self)
        let mirrored = ModelConfiguration(
            "FutureMirrored", schema: Schema(EarshotSchemaV11.mirroredModels),
            url: paths.primary, cloudKitDatabase: .none
        )
        let local = ModelConfiguration(
            "DeviceLocal", schema: Schema(EarshotSchemaV11.localModels),
            url: paths.local, cloudKitDatabase: .none
        )
        return try ModelContainer(for: full, configurations: mirrored, local)
    }

    private func openMirroredOnly(_ paths: StorePaths) throws -> ModelContainer {
        let schema = Schema(EarshotSchemaV11.mirroredModels)
        let configuration = ModelConfiguration(
            "FutureMirrored", schema: schema, url: paths.primary, cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: configuration)
    }

    private func checkpointWAL(_ url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil)
                == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private func fileSize(_ url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func counts(_ context: ModelContext) throws -> Counts {
        Counts(
            podcasts: try context.fetchCount(FetchDescriptor<Podcast>()),
            episodes: try context.fetchCount(FetchDescriptor<Episode>()),
            queueItems: try context.fetchCount(FetchDescriptor<QueueItem>()),
            listeningSessions: try context.fetchCount(FetchDescriptor<ListeningSession>()),
            bookmarks: try context.fetchCount(FetchDescriptor<Bookmark>()),
            podcastFolders: try context.fetchCount(FetchDescriptor<PodcastFolder>()),
            folderMemberships: try context.fetchCount(FetchDescriptor<FolderMembership>()),
            episodeFolderMemberships: try context.fetchCount(
                FetchDescriptor<EpisodeFolderMembership>()
            ),
            recentlyExpired: try context.fetchCount(FetchDescriptor<RecentlyExpired>()),
            quickActions: try context.fetchCount(FetchDescriptor<QuickActionConfig>()),
            appSettings: try context.fetchCount(FetchDescriptor<AppSetting>()),
            localPodcastStates: try context.fetchCount(FetchDescriptor<LocalPodcastState>()),
            localEpisodeStates: try context.fetchCount(FetchDescriptor<LocalEpisodeState>()),
            localAppSettings: try context.fetchCount(FetchDescriptor<LocalAppSetting>())
        )
    }

    private func storeVersion(_ url: URL) throws -> String {
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            type: .sqlite, at: url
        )
        return try XCTUnwrap(
            (metadata[NSStoreModelVersionIdentifiersKey] as? [String])?.first
        )
    }

    private func integrityCheck(_ url: URL) throws -> [String] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA integrity_check", -1, &statement, nil)
                == SQLITE_OK else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_finalize(statement) }
        var rows: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) {
                rows.append(String(cString: text))
            }
        }
        return rows
    }

    private func elapsedSeconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
    }
}

/// Opt-in, test-owned filesystem and file-level reset measurements for turn 2
/// of the Settings reset watchdog investigation. Production Documents, Caches,
/// and Application Support paths are never resolved or mutated here.
@MainActor
final class ResetFileLevelMeasurementTests: XCTestCase {
    private enum Interruption: String, CaseIterable {
        case afterMovingJournal
        case afterQuarantine
        case afterCommittedJournal
        case afterQuarantineCleanup
        case afterJournalRemoval
    }

    private struct ResetEntry: Codable {
        let sourcePath: String
        let quarantineName: String
    }

    private struct ResetJournal: Codable {
        enum Phase: String, Codable { case moving, committed }
        let phase: Phase
        let quarantineName: String
        let entries: [ResetEntry]
    }

    private struct Paths {
        let root: URL
        let applicationSupport: URL
        let mirrored: URL
        let local: URL
        let downloads: URL
        let artwork: URL
        let backupRoot: URL
        let journal: URL
    }

    private struct EntityCounts {
        let values: [(String, Int)]
        var text: String { values.map { "\($0.0)=\($0.1)" }.joined(separator: ",") }
        var allZero: Bool { values.allSatisfy { $0.1 == 0 } }
    }

    private func requireOptIn() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUN_SYNC_MIGRATION_SCALE"] != nil,
            "Set TEST_RUNNER_RUN_SYNC_MIGRATION_SCALE=1 to run opt-in reset measurements."
        )
    }

    private var incidentFixture: URL {
        get throws {
            URL(fileURLWithPath: try XCTUnwrap(
                ProcessInfo.processInfo.environment["RESET_INCIDENT_FIXTURE_ROOT"]
            ), isDirectory: true)
        }
    }

    private var filesystemTemplate: URL {
        get throws {
            URL(fileURLWithPath: try XCTUnwrap(
                ProcessInfo.processInfo.environment["RESET_FILESYSTEM_TEMPLATE_ROOT"]
            ), isDirectory: true)
        }
    }

    func testResetFilesystemDeletionSeries() throws {
        try requireOptIn()
        let template = try filesystemTemplate
        let templateDownloads = template.appending(path: "Downloads", directoryHint: .isDirectory)
        let templateArtwork = template.appending(path: "artwork", directoryHint: .isDirectory)
        let allocation = try allocationTotals(at: templateDownloads)
        print("RESETFS|template|files|\(allocation.files)|logicalBytes|\(allocation.logical)|allocatedBytes|\(allocation.allocated)|sparse|\(allocation.allocated < allocation.logical)")

        var downloadTimes: [Double] = []
        var clearTimes: [Double] = []
        var artworkRemovalTimes: [Double] = []
        var artworkRemovalSucceeded: [Bool] = []
        var descriptorsBeforeUnlink: [[String]] = []

        for run in 1...5 {
            let root = try temporaryRoot(label: "fs-download-\(run)")
            let downloads = root.appending(path: "Downloads", directoryHint: .isDirectory)
            try FileManager.default.copyItem(at: templateDownloads, to: downloads)
            let copied = try allocationTotals(at: downloads)
            let start = DispatchTime.now().uptimeNanoseconds
            try FileManager.default.removeItem(at: downloads)
            let seconds = elapsed(since: start)
            downloadTimes.append(seconds)
            print(String(format: "RESETFS|downloads|run|%d|seconds|%.9f|files|%d|logicalBytes|%lld|allocatedBytes|%lld|gone|%@", run, seconds, copied.files, copied.logical, copied.allocated, exists(downloads) ? "false" : "true"))
        }

        for run in 1...5 {
            let root = try temporaryRoot(label: "fs-clear-\(run)")
            let artwork = root.appending(path: "artwork", directoryHint: .isDirectory)
            try FileManager.default.copyItem(at: templateArtwork, to: artwork)
            let cache = URLCache(
                memoryCapacity: ArtworkCache.memoryCapacity,
                diskCapacity: ArtworkCache.diskCapacity,
                directory: artwork
            )
            populate(cache: cache, run: run)
            let before = openDescriptors(under: artwork)
            let start = DispatchTime.now().uptimeNanoseconds
            cache.removeAllCachedResponses()
            let seconds = elapsed(since: start)
            clearTimes.append(seconds)
            let after = openDescriptors(under: artwork)
            print(String(format: "RESETFS|artworkClearPrimitive|run|%d|seconds|%.9f|fdsBefore|%d|fdsAfter|%d|exactSharedSingleton|skipped-unredirectable", run, seconds, before.count, after.count))
            print("RESETFS|artworkClearPrimitive|run|\(run)|fdPathsBefore|\(before.joined(separator: ","))")
            print("RESETFS|artworkClearPrimitive|run|\(run)|fdPathsAfter|\(after.joined(separator: ","))")
        }

        for run in 1...5 {
            let root = try temporaryRoot(label: "fs-artwork-remove-\(run)")
            let artwork = root.appending(path: "artwork", directoryHint: .isDirectory)
            try FileManager.default.copyItem(at: templateArtwork, to: artwork)
            var cache: URLCache? = URLCache(
                memoryCapacity: ArtworkCache.memoryCapacity,
                diskCapacity: ArtworkCache.diskCapacity,
                directory: artwork
            )
            populate(cache: try XCTUnwrap(cache), run: 100 + run)
            let before = openDescriptors(under: artwork)
            descriptorsBeforeUnlink.append(before)
            let start = DispatchTime.now().uptimeNanoseconds
            var errorText = "none"
            do {
                try FileManager.default.removeItem(at: artwork)
                artworkRemovalSucceeded.append(true)
            } catch {
                artworkRemovalSucceeded.append(false)
                errorText = String(reflecting: error)
            }
            let seconds = elapsed(since: start)
            artworkRemovalTimes.append(seconds)
            let after = openDescriptors(under: artwork)
            print(String(format: "RESETFS|artworkDirectoryRemoval|run|%d|seconds|%.9f|fdsBefore|%d|fdsAfter|%d|gone|%@|error|%@", run, seconds, before.count, after.count, exists(artwork) ? "false" : "true", errorText))
            print("RESETFS|artworkDirectoryRemoval|run|\(run)|fdPathsBefore|\(before.joined(separator: ","))")
            print("RESETFS|artworkDirectoryRemoval|run|\(run)|fdPathsAfter|\(after.joined(separator: ","))")
            cache = nil
            autoreleasepool { }
        }

        printStats(name: "downloads", samples: downloadTimes)
        printStats(name: "artworkClearPrimitive", samples: clearTimes)
        printStats(name: "artworkDirectoryRemoval", samples: artworkRemovalTimes)
        let totalSamples = zip(zip(downloadTimes, clearTimes), artworkRemovalTimes).map { pair, artwork in
            pair.0 + pair.1 + artwork
        }
        printStats(name: "filesystemTotal", samples: totalSamples)
        print("RESETFS|openDescriptorRunsBeforeUnlink|\(descriptorsBeforeUnlink.filter { !$0.isEmpty }.count)|of|5")
        print("RESETFS|artworkDirectoryRemovalSucceeded|\(artworkRemovalSucceeded.filter { $0 }.count)|of|5")
    }

    func testFileLevelResetEndToEndSeries() throws {
        try requireOptIn()
        var times: [Double] = []
        var peaks: [Double] = []
        for run in 1...5 {
            let paths = try makeIncidentShape(label: "e2e-\(run)")
            var container: ModelContainer? = try openV10(paths)
            XCTAssertNotNil(container)
            var cache: URLCache? = URLCache(
                memoryCapacity: ArtworkCache.memoryCapacity,
                diskCapacity: ArtworkCache.diskCapacity,
                directory: paths.artwork
            )
            populate(cache: try XCTUnwrap(cache), run: run)
            let sampler = MigrationMemorySampler()
            _ = sampler.start()
            let start = DispatchTime.now().uptimeNanoseconds
            cache?.removeAllCachedResponses()
            cache = nil
            container = nil
            autoreleasepool { }
            LocalRuntimeState.shared.clear()
            let reopened = try performReset(paths: paths, interruptAt: nil)
            let seconds = elapsed(since: start)
            let peak = sampler.stop()
            times.append(seconds)
            peaks.append(peak)
            try reportVerification(run: run, paths: paths, container: reopened, seconds: seconds, peak: peak)
        }
        printStats(name: "fileLevelReset", samples: times)
        printStats(name: "fileLevelResetPeakRssMB", samples: peaks)
    }

    func testShippingFileResetSeries() async throws {
        try requireOptIn()
        var samples: [Double] = []
        var rebuildSamples: [Double] = []
        var peaks: [Double] = []
        for run in 1...5 {
            let paths = try makeIncidentShape(label: "shipping-\(run)")
            var container: ModelContainer? = try openV10(paths)
            container = nil
            let sampler = MigrationMemorySampler()
            _ = sampler.start()
            let start = DispatchTime.now().uptimeNanoseconds
            let ok = await SettingsReset.performFileReset(
                applicationSupport: paths.applicationSupport,
                documents: paths.root.appending(path: "Documents", directoryHint: .isDirectory),
                caches: paths.root.appending(path: "Caches", directoryHint: .isDirectory)
            )
            let transactionSeconds = elapsed(since: start)
            let rebuildStart = DispatchTime.now().uptimeNanoseconds
            let load = await ModelContainerFactory.makeShared(using: StoreMigrationEngine(), at: paths.mirrored)
            let reopened: ModelContainer
            switch load { case .ready(let value): reopened = value; default: XCTFail("fresh store did not open"); continue }
            let rebuildSeconds = elapsed(since: rebuildStart)
            let seconds = elapsed(since: start)
            let peak = sampler.stop()
            let counts = try entityCounts(reopened.mainContext)
            samples.append(seconds); rebuildSamples.append(rebuildSeconds); peaks.append(peak)
            print(String(format: "SHIPPINGRESET|run|%d|seconds|%.9f|transaction|%.9f|rebuild|%.9f|peakRssMB|%.3f|ok|%@|counts|%@|primaryVersion|%@|localVersion|%@|integrity|%@|%@|downloadsGone|%@|artworkGone|%@|snapshotGone|%@", run, seconds, transactionSeconds, rebuildSeconds, peak, ok ? "true" : "false", counts.text, try storeVersion(paths.mirrored), try storeVersion(paths.local), try integrity(paths.mirrored).joined(separator: ","), try integrity(paths.local).joined(separator: ","), exists(paths.downloads) ? "false" : "true", exists(paths.artwork) ? "false" : "true", exists(paths.backupRoot) ? "false" : "true"))
            XCTAssertTrue(ok)
            XCTAssertTrue(counts.values.filter { $0.0 != "AppSetting" }.allSatisfy { $0.1 == 0 })
            XCTAssertEqual(try reopened.mainContext.fetchCount(FetchDescriptor<AppSetting>()), 2)
            XCTAssertEqual(try storeVersion(paths.mirrored), "10.0.0")
            XCTAssertEqual(try storeVersion(paths.local), "10.0.0")
            XCTAssertEqual(try integrity(paths.mirrored), ["ok"])
            XCTAssertEqual(try integrity(paths.local), ["ok"])
        }
        printStats(name: "shippingFileReset", samples: samples)
        printStats(name: "shippingContainerRebuild", samples: rebuildSamples)
        printStats(name: "shippingPeakRssMB", samples: peaks)
    }

    func testCommittedJournalRecoveryLeavesFreshStores() throws {
        try requireOptIn()
        let paths = try makeIncidentShape(label: "committed-journal-recovery")
        var container: ModelContainer? = try openV10(paths)
        container = nil
        do { _ = try performReset(paths: paths, interruptAt: .afterCommittedJournal); XCTFail("expected interruption") }
        catch let error as CocoaError { XCTAssertEqual(error.code, .userCancelled) }
        let recovered = try recoverAndOpen(paths: paths)
        XCTAssertTrue(try entityCounts(recovered.mainContext).allZero)
        XCTAssertFalse(exists(paths.journal))
        XCTAssertTrue(quarantineDirectories(paths).isEmpty)
        XCTAssertEqual(try storeVersion(paths.mirrored), "10.0.0")
        XCTAssertEqual(try storeVersion(paths.local), "10.0.0")
    }

    func testFileLevelResetInterruptionRecovery() throws {
        try requireOptIn()
        for point in Interruption.allCases {
            let paths = try makeIncidentShape(label: "interrupt-\(point.rawValue)")
            var container: ModelContainer? = try openV10(paths)
            XCTAssertNotNil(container)
            container = nil
            autoreleasepool { }
            do {
                _ = try performReset(paths: paths, interruptAt: point)
                XCTFail("Expected interruption at \(point.rawValue)")
            } catch let error as CocoaError where error.code == .userCancelled {
                // Expected simulated process termination.
            }
            let recovered = try recoverAndOpen(paths: paths)
            let counts = try entityCounts(recovered.mainContext)
            let expected = [Interruption.afterMovingJournal, .afterQuarantine].contains(point)
                ? "rolled-back-original" : "committed-fresh"
            let consistent = expected == "rolled-back-original" ? !counts.allZero : counts.allZero
            print("RESETINTERRUPT|point|\(point.rawValue)|expected|\(expected)|counts|\(counts.text)|consistent|\(consistent)|journalGone|\(!exists(paths.journal))|quarantineCount|\(quarantineDirectories(paths).count)|downloadsExists|\(exists(paths.downloads))|artworkExists|\(exists(paths.artwork))|snapshotExists|\(exists(paths.backupRoot))")
            XCTAssertTrue(consistent)
            XCTAssertFalse(exists(paths.journal))
            XCTAssertTrue(quarantineDirectories(paths).isEmpty)
        }
    }

    private func makeIncidentShape(label: String) throws -> Paths {
        let root = try temporaryRoot(label: label)
        let appSupport = root.appending(path: "Application Support", directoryHint: .isDirectory)
        let documents = root.appending(path: "Documents", directoryHint: .isDirectory)
        let caches = root.appending(path: "Caches", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        let sourceAppSupport = try incidentFixture
            .appending(path: "Library/Application Support", directoryHint: .isDirectory)
        for name in [
            "default.store", "default.store-wal", "default.store-shm",
            "earshot-local.store", "earshot-local.store-wal", "earshot-local.store-shm",
        ] {
            try FileManager.default.copyItem(
                at: sourceAppSupport.appending(path: name), to: appSupport.appending(path: name)
            )
        }
        let template = try filesystemTemplate
        try FileManager.default.copyItem(
            at: template.appending(path: "Downloads"),
            to: documents.appending(path: "Downloads", directoryHint: .isDirectory)
        )
        try FileManager.default.copyItem(
            at: template.appending(path: "artwork"),
            to: caches.appending(path: "artwork", directoryHint: .isDirectory)
        )
        let backupRoot = appSupport.appending(path: "store-backups", directoryHint: .isDirectory)
        let snapshot = backupRoot.appending(path: "verified-reset-fixture", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: sourceAppSupport.appending(path: "default.store"),
            to: snapshot.appending(path: "default.store")
        )
        try Data("{\"formatVersion\":1,\"measurementFixture\":true}".utf8)
            .write(to: snapshot.appending(path: "manifest.json"), options: .atomic)
        return Paths(
            root: root, applicationSupport: appSupport,
            mirrored: appSupport.appending(path: "default.store"),
            local: appSupport.appending(path: "earshot-local.store"),
            downloads: documents.appending(path: "Downloads", directoryHint: .isDirectory),
            artwork: caches.appending(path: "artwork", directoryHint: .isDirectory),
            backupRoot: backupRoot,
            journal: appSupport.appending(path: "settings-reset-transaction.json")
        )
    }

    private func performReset(
        paths: Paths, interruptAt: Interruption?
    ) throws -> ModelContainer {
        try recoverTransaction(paths)
        let quarantineName = "settings-reset-quarantine-\(UUID().uuidString)"
        let quarantine = paths.applicationSupport.appending(
            path: quarantineName, directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: quarantine, withIntermediateDirectories: false)
        let candidates = [
            paths.mirrored,
            URL(fileURLWithPath: paths.mirrored.path + "-wal"),
            URL(fileURLWithPath: paths.mirrored.path + "-shm"),
            URL(fileURLWithPath: paths.mirrored.path + "-journal"),
            paths.local,
            URL(fileURLWithPath: paths.local.path + "-wal"),
            URL(fileURLWithPath: paths.local.path + "-shm"),
            URL(fileURLWithPath: paths.local.path + "-journal"),
            paths.backupRoot, paths.downloads, paths.artwork,
        ].filter(exists)
        let entries = candidates.enumerated().map {
            ResetEntry(sourcePath: $0.element.path, quarantineName: "\($0.offset)-\($0.element.lastPathComponent)")
        }
        var journal = ResetJournal(
            phase: .moving, quarantineName: quarantineName, entries: entries
        )
        try write(journal, to: paths.journal)
        try interruptIfRequested(.afterMovingJournal, requested: interruptAt)
        for entry in entries {
            try FileManager.default.moveItem(
                at: URL(fileURLWithPath: entry.sourcePath),
                to: quarantine.appending(path: entry.quarantineName)
            )
        }
        try interruptIfRequested(.afterQuarantine, requested: interruptAt)
        journal = ResetJournal(
            phase: .committed, quarantineName: quarantineName, entries: entries
        )
        try write(journal, to: paths.journal)
        try interruptIfRequested(.afterCommittedJournal, requested: interruptAt)
        try FileManager.default.removeItem(at: quarantine)
        try interruptIfRequested(.afterQuarantineCleanup, requested: interruptAt)
        try FileManager.default.removeItem(at: paths.journal)
        try interruptIfRequested(.afterJournalRemoval, requested: interruptAt)
        return try openV10(paths)
    }

    private func recoverAndOpen(paths: Paths) throws -> ModelContainer {
        try recoverTransaction(paths)
        return try openV10(paths)
    }

    private func recoverTransaction(_ paths: Paths) throws {
        guard exists(paths.journal) else { return }
        let journal = try JSONDecoder().decode(
            ResetJournal.self, from: Data(contentsOf: paths.journal)
        )
        let quarantine = paths.applicationSupport.appending(
            path: journal.quarantineName, directoryHint: .isDirectory
        )
        if journal.phase == .moving {
            for entry in journal.entries {
                let staged = quarantine.appending(path: entry.quarantineName)
                guard exists(staged) else { continue }
                let source = URL(fileURLWithPath: entry.sourcePath)
                try FileManager.default.createDirectory(
                    at: source.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try FileManager.default.moveItem(at: staged, to: source)
            }
        }
        if exists(quarantine) { try FileManager.default.removeItem(at: quarantine) }
        try FileManager.default.removeItem(at: paths.journal)
    }

    private func reportVerification(
        run: Int, paths: Paths, container: ModelContainer, seconds: Double, peak: Double
    ) throws {
        let counts = try entityCounts(container.mainContext)
        let primaryVersion = try storeVersion(paths.mirrored)
        let localVersion = try storeVersion(paths.local)
        let primaryIntegrity = try integrity(paths.mirrored).joined(separator: ",")
        let localIntegrity = try integrity(paths.local).joined(separator: ",")
        print(String(format: "RESETE2E|run|%d|seconds|%.9f|peakRssMB|%.3f|primaryVersion|%@|localVersion|%@|primaryIntegrity|%@|localIntegrity|%@|counts|%@|downloadsGone|%@|artworkGone|%@|snapshotGone|%@|journalGone|%@|quarantineCount|%d", run, seconds, peak, primaryVersion, localVersion, primaryIntegrity, localIntegrity, counts.text, exists(paths.downloads) ? "false" : "true", exists(paths.artwork) ? "false" : "true", exists(paths.backupRoot) ? "false" : "true", exists(paths.journal) ? "false" : "true", quarantineDirectories(paths).count))
        XCTAssertTrue(counts.allZero)
        XCTAssertEqual(primaryVersion, "11.0.0")
        XCTAssertEqual(localVersion, "11.0.0")
        XCTAssertEqual(primaryIntegrity, "ok")
        XCTAssertEqual(localIntegrity, "ok")
        XCTAssertFalse(exists(paths.downloads))
        XCTAssertFalse(exists(paths.artwork))
        XCTAssertFalse(exists(paths.backupRoot))
        XCTAssertFalse(exists(paths.journal))
        XCTAssertTrue(quarantineDirectories(paths).isEmpty)
    }

    private func openV10(_ paths: Paths) throws -> ModelContainer {
        let schema = Schema(versionedSchema: EarshotSchemaV11.self)
        let mirrored = ModelConfiguration(
            "FutureMirrored", schema: Schema(EarshotSchemaV11.mirroredModels),
            url: paths.mirrored, cloudKitDatabase: .none
        )
        let local = ModelConfiguration(
            "DeviceLocal", schema: Schema(EarshotSchemaV11.localModels),
            url: paths.local, cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: mirrored, local)
    }

    private func entityCounts(_ context: ModelContext) throws -> EntityCounts {
        EntityCounts(values: [
            ("Podcast", try context.fetchCount(FetchDescriptor<Podcast>())),
            ("Episode", try context.fetchCount(FetchDescriptor<Episode>())),
            ("QueueItem", try context.fetchCount(FetchDescriptor<QueueItem>())),
            ("ListeningSession", try context.fetchCount(FetchDescriptor<ListeningSession>())),
            ("Bookmark", try context.fetchCount(FetchDescriptor<Bookmark>())),
            ("PodcastFolder", try context.fetchCount(FetchDescriptor<PodcastFolder>())),
            ("FolderMembership", try context.fetchCount(FetchDescriptor<FolderMembership>())),
            ("EpisodeFolderMembership", try context.fetchCount(FetchDescriptor<EpisodeFolderMembership>())),
            ("RecentlyExpired", try context.fetchCount(FetchDescriptor<RecentlyExpired>())),
            ("QuickActionConfig", try context.fetchCount(FetchDescriptor<QuickActionConfig>())),
            ("AppSetting", try context.fetchCount(FetchDescriptor<AppSetting>())),
            ("LocalPodcastState", try context.fetchCount(FetchDescriptor<LocalPodcastState>())),
            ("LocalEpisodeState", try context.fetchCount(FetchDescriptor<LocalEpisodeState>())),
            ("LocalAppSetting", try context.fetchCount(FetchDescriptor<LocalAppSetting>())),
        ])
    }

    private func populate(cache: URLCache, run: Int) {
        let url = URL(string: "https://reset-measurement.invalid/artwork-\(run).png")!
        let request = URLRequest(url: url)
        let response = URLResponse(
            url: url, mimeType: "image/png", expectedContentLength: 4096,
            textEncodingName: nil
        )
        cache.storeCachedResponse(
            CachedURLResponse(response: response, data: Data(repeating: UInt8(run), count: 4096)),
            for: request
        )
        _ = cache.cachedResponse(for: request)
    }

    private func allocationTotals(at directory: URL) throws -> (
        files: Int, logical: Int64, allocated: Int64
    ) {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ).filter { url in
            (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        var logical: Int64 = 0
        var allocated: Int64 = 0
        for file in files {
            var info = stat()
            guard lstat(file.path, &info) == 0 else { throw CocoaError(.fileReadUnknown) }
            logical += Int64(info.st_size)
            allocated += Int64(info.st_blocks) * 512
        }
        return (files.count, logical, allocated)
    }

    private func openDescriptors(under directory: URL) -> [String] {
        let prefix = directory.standardizedFileURL.path
        return (0..<1024).compactMap { descriptor -> String? in
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let descriptorPath = "/dev/fd/\(descriptor)"
            let count = descriptorPath.withCString { path in
                buffer.withUnsafeMutableBufferPointer {
                    readlink(path, $0.baseAddress, $0.count - 1)
                }
            }
            guard count > 0 else { return nil }
            buffer[Int(count)] = 0
            let path = String(
                decoding: buffer.prefix(Int(count)).map { UInt8(bitPattern: $0) },
                as: UTF8.self
            )
            return path.hasPrefix(prefix) ? path : nil
        }.sorted()
    }

    private func storeVersion(_ url: URL) throws -> String {
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            type: .sqlite, at: url
        )
        return try XCTUnwrap(
            (metadata[NSStoreModelVersionIdentifiersKey] as? [String])?.first
        )
    }

    private func integrity(_ url: URL) throws -> [String] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA integrity_check", -1, &statement, nil)
                == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_finalize(statement) }
        var rows: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) {
                rows.append(String(cString: text))
            }
        }
        return rows
    }

    private func temporaryRoot(label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "reset-turn2-\(label)-\(UUID().uuidString)", directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func quarantineDirectories(_ paths: Paths) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: paths.applicationSupport, includingPropertiesForKeys: nil
        )) ?? []).filter { $0.lastPathComponent.hasPrefix("settings-reset-quarantine-") }
    }

    private func interruptIfRequested(
        _ point: Interruption, requested: Interruption?
    ) throws {
        guard point == requested else { return }
        throw CocoaError(.userCancelled)
    }

    private func write(_ journal: ResetJournal, to url: URL) throws {
        try JSONEncoder().encode(journal).write(to: url, options: .atomic)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func elapsed(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
    }

    private func printStats(name: String, samples: [Double]) {
        let mean = samples.reduce(0, +) / Double(samples.count)
        let variance = samples.reduce(0) { $0 + pow($1 - mean, 2) } / Double(samples.count)
        let standardDeviation = sqrt(variance)
        print(String(format: "RESETSTATS|name|%@|samples|%@|mean|%.9f|populationStdDev|%.9f|min|%.9f|max|%.9f", name, samples.map { String(format: "%.9f", $0) }.joined(separator: ","), mean, standardDeviation, samples.min()!, samples.max()!))
    }
}
