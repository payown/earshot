import XCTest
import SwiftData
@testable import Earshot

@MainActor
final class StoreMigrationV13ToV14Tests: XCTestCase {
    func testV13LocalStoreMigratesValuesAndNilAttemptIdentitySurvivesReopen() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "Earshot-V13-V14-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "device.store")

        let oldSchema = Schema(versionedSchema: EarshotSchemaV13.self)
        let oldContainer = try ModelContainer(
            for: oldSchema,
            configurations: ModelConfiguration(
                "DeviceLocal", schema: Schema(EarshotSchemaV13.localModels),
                url: url, cloudKitDatabase: .none
            )
        )
        let oldContext = ModelContext(oldContainer)
        let podcastState = EarshotSchemaV13.LocalPodcastState()
        podcastState.feedURL = "https://example.com/feed"
        let episodeState = EarshotSchemaV13.LocalEpisodeState()
        episodeState.podcastFeedURL = podcastState.feedURL
        episodeState.episodeGUID = "pending-episode"
        episodeState.downloadStatusRaw = DownloadStatus.pending.rawValue
        episodeState.downloadPath = "existing-file.mp3"
        episodeState.volumeBoostRaw = VolumeBoostLevel.high.rawValue
        let personalAudio = EarshotSchemaV13.PersonalAudioItem()
        personalAudio.id = "personal-audio-id"
        personalAudio.title = "Saved recording"
        personalAudio.originalFilename = "recording.m4a"
        personalAudio.mediaFilename = "media.m4a"
        personalAudio.typeIdentifier = "public.mpeg-4-audio"
        personalAudio.byteSize = 1234
        personalAudio.contentHash = "hash"
        oldContext.insert(podcastState)
        oldContext.insert(episodeState)
        oldContext.insert(personalAudio)
        try oldContext.save()

        // Release the source store before opening its migration destination.
        oldContainer.mainContext.rollback()
        let currentSchema = Schema(versionedSchema: EarshotSchemaV14.self)
        let migrated = try ModelContainer(
            for: currentSchema,
            migrationPlan: EarshotV13ToV14MigrationPlan.self,
            configurations: ModelConfiguration(
                "DeviceLocal", schema: Schema(EarshotSchemaV14.localModels),
                url: url, cloudKitDatabase: .none
            )
        )
        let context = ModelContext(migrated)
        let episode = try XCTUnwrap(context.fetch(FetchDescriptor<LocalEpisodeState>()).first)
        XCTAssertEqual(episode.podcastFeedURL, "https://example.com/feed")
        XCTAssertEqual(episode.episodeGUID, "pending-episode")
        XCTAssertEqual(episode.downloadStatusRaw, DownloadStatus.pending.rawValue)
        XCTAssertEqual(episode.downloadPath, "existing-file.mp3")
        XCTAssertEqual(episode.volumeBoostRaw, VolumeBoostLevel.high.rawValue)
        XCTAssertNil(episode.downloadAttemptID)
        XCTAssertEqual(try context.fetch(FetchDescriptor<LocalPodcastState>()).first?.feedURL,
                       "https://example.com/feed")
        let audio = try XCTUnwrap(context.fetch(FetchDescriptor<PersonalAudioItem>()).first)
        XCTAssertEqual(audio.id, "personal-audio-id")
        XCTAssertEqual(audio.title, "Saved recording")
        XCTAssertEqual(audio.mediaFilename, "media.m4a")
        XCTAssertEqual(audio.contentHash, "hash")

        // A subsequent launch/open must be idempotent, and the new optional
        // field must be writable and durable after migration.
        episode.downloadAttemptID = "attempt-1"
        try context.save()
        migrated.mainContext.rollback()
        let reopened = try ModelContainer(
            for: currentSchema,
            configurations: ModelConfiguration(
                "DeviceLocal", schema: Schema(EarshotSchemaV14.localModels),
                url: url, cloudKitDatabase: .none
            )
        )
        let reopenedContext = ModelContext(reopened)
        XCTAssertEqual(
            try reopenedContext.fetch(FetchDescriptor<LocalEpisodeState>()).first?.downloadAttemptID,
            "attempt-1"
        )
        XCTAssertEqual(try reopenedContext.fetchCount(FetchDescriptor<PersonalAudioItem>()), 1)
    }
}
