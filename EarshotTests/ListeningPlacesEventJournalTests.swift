import Foundation
import SwiftData
import XCTest
@testable import Earshot

@MainActor
final class ListeningPlacesEventJournalTests: XCTestCase {
    private let feed = "https://example.com/journal.xml"

    func testAtoBtoAAcrossReopenAdvancesDurableEventClockWithCloudOff() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = Date(timeIntervalSince1970: 1_000)

        try withStore(at: directory) { context in
            let (podcast, episode) = makeEpisode(position: 0)
            context.insert(podcast)
            context.insert(episode)
            try context.save()
            episode.positionSeconds = 10
            try ListeningPlacesEventJournal.stageLocalMutation(
                of: episode, in: context, deviceID: "phone", now: first
            )
            try context.save()
        }
        try withStore(at: directory) { context in
            let episode = try storedEpisode(in: context)
            XCTAssertEqual(episode.positionSeconds, 10)
            XCTAssertEqual(event(in: context, episode: episode)?.updatedAt, first)
            episode.positionSeconds = 20
            try ListeningPlacesEventJournal.stageLocalMutation(
                of: episode, in: context, deviceID: "phone", now: first.addingTimeInterval(1)
            )
            try context.save()
        }
        try withStore(at: directory) { context in
            let episode = try storedEpisode(in: context)
            XCTAssertEqual(episode.positionSeconds, 20)
            episode.positionSeconds = 10
            try ListeningPlacesEventJournal.stageLocalMutation(
                of: episode, in: context, deviceID: "phone", now: first.addingTimeInterval(2)
            )
            try context.save()
        }
        try withStore(at: directory) { context in
            let episode = try storedEpisode(in: context)
            XCTAssertEqual(episode.positionSeconds, 10)
            XCTAssertEqual(event(in: context, episode: episode)?.updatedAt,
                           first.addingTimeInterval(2))
        }
    }

    func testRollbackLeavesEpisodeAndEventAtPriorSavedValue() throws {
        let container = try ModelContainerFactory.makeInMemory()
        let context = ModelContext(container)
        let (podcast, episode) = makeEpisode(position: 10)
        context.insert(podcast)
        context.insert(episode)
        try ListeningPlacesEventJournal.stageLocalMutation(
            of: episode, in: context, deviceID: "phone",
            now: Date(timeIntervalSince1970: 1_000)
        )
        try context.save()
        episode.positionSeconds = 20
        try ListeningPlacesEventJournal.stageLocalMutation(
            of: episode, in: context, deviceID: "phone",
            now: Date(timeIntervalSince1970: 2_000)
        )
        context.rollback() // Simulate a save-boundary failure; neither fact commits.
        let fresh = ModelContext(container)
        let persisted = try storedEpisode(in: fresh)
        XCTAssertEqual(persisted.positionSeconds, 10)
        XCTAssertEqual(event(in: fresh, episode: persisted)?.updatedAt,
                       Date(timeIntervalSince1970: 1_000))
    }

    func testMetadataOnlyAndNoOpCheckpointDoNotRefreshClock() throws {
        let container = try ModelContainerFactory.makeInMemory()
        let context = ModelContext(container)
        let (podcast, episode) = makeEpisode(position: 10)
        context.insert(podcast)
        context.insert(episode)
        let time = Date(timeIntervalSince1970: 1_000)
        try ListeningPlacesEventJournal.stageLocalMutation(
            of: episode, in: context, deviceID: "phone", now: time
        )
        try context.save()
        podcast.title = "Updated title"
        try context.save()
        XCTAssertFalse(try ListeningPlacesEventJournal.stageLocalMutation(
            of: episode, in: context, deviceID: "phone", now: time.addingTimeInterval(100)
        ))
        XCTAssertEqual(event(in: context, episode: episode)?.updatedAt, time)
    }

    func testLegacyEpisodeWithNoEventKeepsUnknownTime() throws {
        let container = try ModelContainerFactory.makeInMemory()
        let context = ModelContext(container)
        let (podcast, episode) = makeEpisode(position: 45)
        context.insert(podcast)
        context.insert(episode)
        try context.save()
        XCTAssertEqual(try ListeningPlacesEventJournal.read(for: episode, in: context),
                       .unknownLegacy)
    }

    func testPreSaveChangeInventorySeparatesMetadataFromPlaceMutation() throws {
        let container = try ModelContainerFactory.makeInMemory()
        let writer = ModelContext(container)
        let (podcast, episode) = makeEpisode(position: 10)
        writer.insert(podcast)
        writer.insert(episode)
        try writer.save()
        let episodeID = episode.persistentModelID

        episode.title = "New title"
        XCTAssertTrue(writer.changedModelsArray.contains {
            ($0 as? Episode)?.persistentModelID == episodeID
        })
        let persistedMetadata = try XCTUnwrap(
            ModelContext(container).model(for: episodeID) as? Episode
        )
        XCTAssertEqual(persistedMetadata.positionSeconds, 10)
        writer.rollback()

        let changed = try XCTUnwrap(writer.model(for: episodeID) as? Episode)
        changed.positionSeconds = 20
        XCTAssertTrue(writer.changedModelsArray.contains {
            ($0 as? Episode)?.persistentModelID == episodeID
        })
        let persistedPlace = try XCTUnwrap(
            ModelContext(container).model(for: episodeID) as? Episode
        )
        XCTAssertEqual(persistedPlace.positionSeconds, 10)
        XCTAssertEqual(changed.positionSeconds, 20)
    }

    func testSaveBoundaryAdvancesClockAfterOneUnstagedBackwardAndForwardChange() throws {
        let container = try ModelContainerFactory.makeInMemory()
        let writer = ModelContext(container)
        let (podcast, episode) = makeEpisode(position: 10)
        writer.insert(podcast)
        writer.insert(episode)
        let original = Date(timeIntervalSince1970: 1_000)
        try ListeningPlacesEventJournal.stageLocalMutation(
            of: episode, in: writer, deviceID: "phone", now: original
        )
        try writer.save()

        // Reproduce an old writer that saved a position without staging.
        episode.positionSeconds = 20
        try writer.save()
        episode.positionSeconds = 10
        let returned = original.addingTimeInterval(100)
        try ListeningPlacesEventJournal.stageChangedEpisodesBeforeSave(
            in: writer, localDeviceID: "phone", now: returned
        )
        try writer.save()
        let fresh = ModelContext(container)
        let saved = try storedEpisode(in: fresh)
        XCTAssertEqual(event(in: fresh, episode: saved)?.updatedAt, returned)
    }

    func testSaveBoundaryDoesNotStampMetadataAndInvalidatesUnknownPeerOrigin() throws {
        let container = try ModelContainerFactory.makeInMemory()
        let writer = ModelContext(container)
        let (podcast, episode) = makeEpisode(position: 10)
        writer.insert(podcast)
        writer.insert(episode)
        let original = Date(timeIntervalSince1970: 1_000)
        try ListeningPlacesEventJournal.stageLocalMutation(
            of: episode, in: writer, deviceID: "phone", now: original
        )
        try writer.save()

        episode.title = "Publisher corrected title"
        try ListeningPlacesEventJournal.stageChangedEpisodesBeforeSave(
            in: writer, localDeviceID: "phone", now: original.addingTimeInterval(50)
        )
        try writer.save()
        XCTAssertEqual(event(in: writer, episode: episode)?.updatedAt, original)

        episode.positionSeconds = 30
        try ListeningPlacesEventJournal.stageChangedEpisodesBeforeSave(
            in: writer, localDeviceID: nil, now: original.addingTimeInterval(100)
        )
        try writer.save()
        let fresh = ModelContext(container)
        XCTAssertEqual(try ListeningPlacesEventJournal.read(
            for: storedEpisode(in: fresh), in: fresh
        ), .unknownLegacy)
    }

    func testSaveBoundaryDoesNotBlockEpisodeWithoutInterchangeIdentity() throws {
        let container = try ModelContainerFactory.makeInMemory()
        let writer = ModelContext(container)
        let podcast = Podcast(feedURL: "", title: "Catalog row")
        let episode = Episode(guid: "", title: "Audio", audioURL: "", positionSeconds: 10)
        episode.podcast = podcast
        writer.insert(podcast)
        writer.insert(episode)
        try writer.save()

        episode.positionSeconds = 20
        try ListeningPlacesEventJournal.stageChangedEpisodesBeforeSave(
            in: writer, localDeviceID: "phone"
        )
        try writer.save()
        XCTAssertEqual(try storedEpisode(in: ModelContext(container)).positionSeconds, 20)
    }

    func testExistingV14StoreKeepsUnknownClockUntilNewSavedMutation() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try withStore(at: directory) { context in
            let (podcast, episode) = makeEpisode(position: 45)
            context.insert(podcast)
            context.insert(episode)
            try context.save() // Exact pre-feature V14 shape: no journal row.
        }
        try withStore(at: directory) { context in
            let episode = try storedEpisode(in: context)
            XCTAssertEqual(try ListeningPlacesEventJournal.read(for: episode, in: context),
                           .unknownLegacy)
            episode.title = "Publisher corrected title"
            try context.save()
            XCTAssertEqual(try ListeningPlacesEventJournal.read(for: episode, in: context),
                           .unknownLegacy)
            episode.positionSeconds = 46
            try ListeningPlacesEventJournal.stageLocalMutation(
                of: episode, in: context, deviceID: "phone",
                now: Date(timeIntervalSince1970: 2_000)
            )
            try context.save()
        }
        try withStore(at: directory) { context in
            let episode = try storedEpisode(in: context)
            XCTAssertEqual(event(in: context, episode: episode)?.updatedAt,
                           Date(timeIntervalSince1970: 2_000))
        }
    }

    func testPeerClockSurvivesBackwardSeekWithoutImportTimeStamp() throws {
        let container = try ModelContainerFactory.makeInMemory()
        let context = ModelContext(container)
        let (podcast, episode) = makeEpisode(position: 60)
        context.insert(podcast)
        context.insert(episode)
        try ListeningPlacesEventJournal.stageLocalMutation(
            of: episode, in: context, deviceID: "phone",
            now: Date(timeIntervalSince1970: 1_000)
        )
        try context.save()
        let peerTime = Date(timeIntervalSince1970: 1_200)
        episode.positionSeconds = 12
        let peer = ListeningPlacesStateEvent(
            id: ListeningPlacesFormat.episodeID(guid: episode.guid, enclosureURL: episode.audioURL),
            positionMilliseconds: 12_000, played: false, updatedAt: peerTime,
            sourceDeviceID: "desktop", isReset: false
        )
        try ListeningPlacesEventJournal.stagePeerEvent(peer, for: episode, in: context)
        try context.save()
        XCTAssertEqual(event(in: context, episode: episode), peer)
    }

    func testRapidMutationsAdvanceClockWithinOneSecond() throws {
        let container = try ModelContainerFactory.makeInMemory()
        let context = ModelContext(container)
        let (podcast, episode) = makeEpisode(position: 10)
        context.insert(podcast)
        context.insert(episode)
        let wallTime = Date(timeIntervalSince1970: 1_000)
        try ListeningPlacesEventJournal.stageLocalMutation(
            of: episode, in: context, deviceID: "phone", now: wallTime
        )
        try context.save()
        let first = try XCTUnwrap(event(in: context, episode: episode))
        episode.positionSeconds = 11
        try ListeningPlacesEventJournal.stageLocalMutation(
            of: episode, in: context, deviceID: "phone", now: wallTime
        )
        try context.save()
        let second = try XCTUnwrap(event(in: context, episode: episode))
        episode.positionSeconds = 12
        try ListeningPlacesEventJournal.stageLocalMutation(
            of: episode, in: context, deviceID: "phone", now: wallTime
        )
        try context.save()
        let third = try XCTUnwrap(event(in: context, episode: episode))
        XCTAssertLessThan(first.updatedAt, second.updatedAt)
        XCTAssertLessThan(second.updatedAt, third.updatedAt)
    }

    func testSyntheticLargeSettingsStageCostIsRecorded() throws {
        let container = try ModelContainerFactory.makeInMemory()
        let context = ModelContext(container)
        let (podcast, episode) = makeEpisode(position: 0)
        context.insert(podcast)
        context.insert(episode)
        // This measures the AppSetting key lookup in a library-sized scalar
        // table; it is diagnostic evidence, not a physical player benchmark.
        for index in 0..<2_880 {
            context.insert(AppSetting(key: "synthetic_\(index)", value: "value"))
        }
        try context.save()
        var stageSeconds: [Double] = []
        var saveSeconds: [Double] = []
        for index in 1...30 {
            episode.positionSeconds = index
            let stageStart = ProcessInfo.processInfo.systemUptime
            try ListeningPlacesEventJournal.stageLocalMutation(
                of: episode, in: context, deviceID: "phone",
                now: Date(timeIntervalSince1970: Double(1_000 + index))
            )
            stageSeconds.append(ProcessInfo.processInfo.systemUptime - stageStart)
            let saveStart = ProcessInfo.processInfo.systemUptime
            try context.save()
            saveSeconds.append(ProcessInfo.processInfo.systemUptime - saveStart)
        }
        let stageMS = stageSeconds.reduce(0, +) / Double(stageSeconds.count) * 1_000
        let saveMS = saveSeconds.reduce(0, +) / Double(saveSeconds.count) * 1_000
        let maxStageMS = (stageSeconds.max() ?? 0) * 1_000
        print("ListeningPlacesEventJournal 2880 settings, 30 updates: stage mean \(stageMS) ms, stage max \(maxStageMS) ms, save mean \(saveMS) ms")
        XCTAssertEqual(episode.positionSeconds, 30)
        XCTAssertNotNil(event(in: context, episode: episode))
    }

    private func makeEpisode(position: Int) -> (Podcast, Episode) {
        let podcast = Podcast(feedURL: feed, title: "Example")
        let episode = Episode(guid: "episode-1", title: "Episode",
                              audioURL: "https://example.com/audio.mp3",
                              positionSeconds: position)
        episode.podcast = podcast
        return (podcast, episode)
    }

    private func event(in context: ModelContext, episode: Episode) -> ListeningPlacesStateEvent? {
        guard case .event(let value) = try? ListeningPlacesEventJournal.read(
            for: episode, in: context
        ) else { return nil }
        return value
    }

    private func storedEpisode(in context: ModelContext) throws -> Episode {
        try XCTUnwrap(context.fetch(FetchDescriptor<Episode>()).first)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "Earshot-place-journal-\(UUID().uuidString)",
                       directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func withStore(at directory: URL, body: (ModelContext) throws -> Void) throws {
        let schema = Schema(versionedSchema: EarshotSchemaV14.self)
        let container = try ModelContainer(for: schema, configurations:
            ModelConfiguration("FutureMirrored",
                               schema: Schema(EarshotSchemaV14.mirroredModels),
                               url: directory.appending(path: "mirrored.store"),
                               cloudKitDatabase: .none),
            ModelConfiguration("DeviceLocal",
                               schema: Schema(EarshotSchemaV14.localModels),
                               url: directory.appending(path: "local.store"),
                               cloudKitDatabase: .none))
        try body(ModelContext(container))
    }
}
