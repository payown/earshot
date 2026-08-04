import XCTest
import SwiftData
import Darwin
@testable import Earshot
@MainActor
final class StoreMigrationV6toV8Tests: XCTestCase {
    nonisolated(unsafe) private var directory: URL!
    nonisolated(unsafe) private var storeURL: URL!
    private let refreshed = Date(timeIntervalSince1970: 1_700_000_000)
    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
            "migration-v6v8-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        storeURL = directory.appendingPathComponent("default.store")
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func seedV6() throws {
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
            downloadStatus: .downloaded, downloadPath: "downloaded.mp3", positionSeconds: 37
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
        let schema = Schema(versionedSchema: EarshotSchemaV6.self)
        try autoreleasepool {
            let container = try ModelContainer(for: schema, configurations:
                ModelConfiguration(schema: schema, url: storeURL))
            container.mainContext.insert(EarshotSchemaV5.Podcast(
                feedURL: "https://scale.example/feed", title: "Scale Show", refreshedAt: refreshed
            ))
            try container.mainContext.save()
        }
        let batchSize = 10_000
        for start in stride(from: 0, to: episodeCount, by: batchSize) {
            try autoreleasepool {
                let container = try ModelContainer(for: schema, configurations:
                    ModelConfiguration(schema: schema, url: storeURL))
                let context = container.mainContext
                let podcast = try XCTUnwrap(
                    try context.fetch(FetchDescriptor<EarshotSchemaV5.Podcast>()).first
                )
                for index in start..<min(start + batchSize, episodeCount) {
                    let downloaded = index == 0
                    let pending = index == 1
                    let episode = EarshotSchemaV5.Episode(
                        guid: "scale-\(index)", title: "Episode \(index)",
                        audioURL: "https://scale.example/\(index).mp3",
                        downloadStatus: downloaded ? .downloaded : (pending ? .pending : .none),
                        downloadPath: downloaded ? "scale-0.mp3" : nil
                    )
                    if index < 100 { episode.podcast = podcast }
                    context.insert(episode)
                    if pending {
                        context.insert(EarshotSchemaV5.ActiveDownload(episode: episode, state: .pending))
                    }
                }
                try context.save()
            }
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
        XCTAssertEqual(episodes["downloaded"]?.downloadPath, "downloaded.mp3")
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

    func testMigratedSplitStoreReopensIdempotently() throws {
        try seedV6()
        try autoreleasepool { _ = try StoreMigration.openOrMigrate(at: storeURL) }
        let reopened = try StoreMigration.openOrMigrate(at: storeURL)
        XCTAssertEqual(try reopened.mainContext.fetchCount(FetchDescriptor<Podcast>()), 1)
        XCTAssertEqual(try reopened.mainContext.fetchCount(FetchDescriptor<LocalEpisodeState>()), 2)
        XCTAssertEqual(LocalAppSettingIdentity.value(for: StoreMigration.splitCompletionKey,
            in: reopened.mainContext), "1")
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
    }

    func testScaleMigrationProfile() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUN_SYNC_MIGRATION_SCALE"] != nil,
            "Set TEST_RUNNER_RUN_SYNC_MIGRATION_SCALE=1 to run the 242k migration profile."
        )
        let count = Int(ProcessInfo.processInfo.environment["SYNC_MIGRATION_EPISODES"] ?? "")
            ?? 242_500
        try seedScaleV6(episodeCount: count)
        let start = DispatchTime.now().uptimeNanoseconds
        let migrated = try StoreMigration.openOrMigrate(at: storeURL)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        let peak = Self.peakResidentMemoryMB()
        XCTAssertEqual(try migrated.mainContext.fetchCount(FetchDescriptor<Episode>()), count)
        XCTAssertEqual(try migrated.mainContext.fetchCount(FetchDescriptor<LocalEpisodeState>()), 2)
        print(String(format: "SYNCMIGRATION|episodes|%d|migrationMs|%.0f|peakRssMB|%.0f",
                     count, elapsed, peak))
        XCTAssertLessThan(elapsed, 20_000, "migration entered launch-watchdog territory")
        XCTAssertLessThan(peak, 500, "migration peak approaches known device jetsam territory")
    }
}
