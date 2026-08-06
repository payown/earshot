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

private final class MigrationDiskSampler: @unchecked Sendable {
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
            ModelConfiguration(schema: schema, url: storeURL))
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

    private func seedScaleV6(episodeCount: Int) throws {
        for index in 0..<min(43, episodeCount) {
            try createDownloadFile(named: "\(scaleDownloadPrefix)-\(index).mp3")
        }
        let schema = Schema(versionedSchema: EarshotSchemaV6.self)
        let podcastCount = min(666, max(1, episodeCount))
        try autoreleasepool {
            let container = try ModelContainer(for: schema, configurations:
                ModelConfiguration(schema: schema, url: storeURL))
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
                    ModelConfiguration(schema: schema, url: storeURL))
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

    private func materializeV6FixtureDownloads() throws {
        let schema = Schema(versionedSchema: EarshotSchemaV6.self)
        let storedPaths: [String] = try autoreleasepool {
            let container = try ModelContainer(
                for: schema,
                configurations: ModelConfiguration(schema: schema, url: storeURL)
            )
            return try container.mainContext.fetch(FetchDescriptor<EarshotSchemaV5.Episode>())
                .compactMap(\.downloadPath)
        }
        let downloads = try DownloadPaths.downloadsDirectory()
        for storedPath in storedPaths {
            guard let name = DownloadPaths.storedFileName(storedPath) else { continue }
            let destination = downloads.appending(path: name)
            guard !FileManager.default.fileExists(atPath: destination.path) else { continue }
            try Data("fixture audio".utf8).write(to: destination)
            downloadArtifacts.append(destination)
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
        XCTAssertEqual(AppSettingIdentity.value(for: SettingsKey.wifiOnlyDownloads, in: context), "false")
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
                configurations: ModelConfiguration(schema: schema, url: storeURL)
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
        let reopened = try StoreMigration.openOrMigrate(at: storeURL)
        XCTAssertEqual(try reopened.mainContext.fetchCount(FetchDescriptor<Podcast>()), 1)
        XCTAssertEqual(try reopened.mainContext.fetchCount(FetchDescriptor<LocalEpisodeState>()), 2)
        XCTAssertEqual(LocalAppSettingIdentity.value(for: StoreMigration.splitCompletionKey,
            in: reopened.mainContext), "1")
        XCTAssertEqual(LocalAppSettingIdentity.value(
            for: StoreMigration.identityRepairCompletionKey, in: reopened.mainContext
        ), "1")
        try assertEpisodeSaveSurvivesReopen(reopened)
    }

    func testAlreadySplitV8StoreMovesForwardWithoutBridgeReplay() throws {
        try seedSplitV8()
        XCTAssertEqual(try storeMajorVersion(at: storeURL), 8)

        let migrated = try StoreMigration.openOrMigrate(at: storeURL)
        let context = migrated.mainContext
        XCTAssertEqual(try storeMajorVersion(at: storeURL), 10)
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
        XCTAssertEqual(try storeMajorVersion(at: storeURL), 10)
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
                key: SettingsKey.wifiOnlyDownloads, value: "post-marker-duplicate"
            ))
            try container.mainContext.save()
        }

        let reopened = try StoreMigration.openOrMigrate(at: storeURL)
        let key = SettingsKey.wifiOnlyDownloads
        let rows = try reopened.mainContext.fetch(FetchDescriptor<AppSetting>(
            predicate: #Predicate { $0.key == key }
        ))
        XCTAssertEqual(rows.count, 2, "repairAll must not run after its marker is saved")
        XCTAssertEqual(LocalAppSettingIdentity.value(
            for: StoreMigration.identityRepairCompletionKey, in: reopened.mainContext
        ), "1")
    }

    /// Opt-in proof against a disposable copy of the untouched build-161 V6
    /// backup, not a freshly constructed scale fixture.
    func testRealBuild161V6FixtureThroughRetainedColumnSchema() async throws {
        let variable = "SYNC_MIGRATION_REAL_V6_DIRECTORY"
        guard let path = ProcessInfo.processInfo.environment[variable] else {
            throw XCTSkip("Set TEST_RUNNER_\(variable) to the verified V6 backup directory")
        }
        try copyStoreSet(from: URL(fileURLWithPath: path, isDirectory: true))
        try materializeV6FixtureDownloads()
        let beforeBytes = try storeSetSize()
        let diskSampler = MigrationDiskSampler(url: directory)
        let baselineAvailableBytes = try diskSampler.start()
        let start = DispatchTime.now().uptimeNanoseconds
        let migrated = try await StoreMigrationEngine().openOrMigrate(at: storeURL)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        let minimumAvailableBytes = diskSampler.stop()
        let context = migrated.mainContext

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
        XCTAssertEqual(try storeMajorVersion(at: storeURL), 10)
        XCTAssertEqual(try integrityCheck(at: storeURL), ["ok"])
        XCTAssertEqual(try integrityCheck(at: StoreMigration.localStoreURL(for: storeURL)), ["ok"])
        let afterBytes = try storeSetSize()
        print(String(format:
            "REALV6MIGRATION|seconds|%.3f|beforeMB|%.1f|afterMB|%.1f|peakAdditionalMB|%.1f|peakAdditionalMultiple|%.3f",
            elapsed, Double(beforeBytes) / 1_048_576, Double(afterBytes) / 1_048_576
                , Double(baselineAvailableBytes - minimumAvailableBytes) / 1_048_576,
            Double(baselineAvailableBytes - minimumAvailableBytes) / Double(beforeBytes)
        ))
        XCTAssertLessThan(
            elapsed, 15,
            "Aged-store migration leaves too little margin inside the 20-second launch watchdog"
        )
        try assertEpisodeSaveSurvivesReopen(migrated)
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
        let remainingSampler = MigrationDiskSampler(url: directory)
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
        XCTAssertEqual(try storeMajorVersion(at: storeURL), 10)
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

        XCTAssertEqual(try storeMajorVersion(at: storeURL), 10)
        XCTAssertEqual(try storeMajorVersion(at: localURL), 10)
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
                configurations: ModelConfiguration(schema: schema, url: storeURL))
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
                configurations: ModelConfiguration(schema: schema, url: storeURL)
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
        let recovered = try StoreMigration.openOrMigrate(at: storeURL)
        try assertRecoveredFixture(recovered)

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
        XCTAssertEqual(try storeMajorVersion(at: storeURL), 10)
        XCTAssertEqual(try integrityCheck(at: storeURL), ["ok"])
        XCTAssertEqual(
            try integrityCheck(at: StoreMigration.localStoreURL(for: storeURL)), ["ok"]
        )
        try assertEpisodeSaveSurvivesReopen(container)
    }

    func testScaleMigrationProfile() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUN_SYNC_MIGRATION_SCALE"] != nil,
            "Set TEST_RUNNER_RUN_SYNC_MIGRATION_SCALE=1 to run the 242k migration profile."
        )
        let count = Int(ProcessInfo.processInfo.environment["SYNC_MIGRATION_EPISODES"] ?? "")
            ?? 242_500
        try seedScaleV6(episodeCount: count)
        let memorySampler = MigrationMemorySampler()
        let baselineRSS = memorySampler.start()
        let start = DispatchTime.now().uptimeNanoseconds
        let migrated = try StoreMigration.openOrMigrate(at: storeURL)
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
            "SYNCMIGRATION|podcasts|%d|episodes|%d|relatedEpisodes|%d|migrationMs|%.0f|baselineRssMB|%.0f|migrationPeakRssMB|%.0f|migrationRssGrowthMB|%.0f|processPeakIncludingSeedMB|%.0f",
            666, count, count, elapsed, baselineRSS, migrationPeakRSS,
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
