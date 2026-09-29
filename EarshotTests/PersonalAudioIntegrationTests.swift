import AVFoundation
import SwiftData
import XCTest
@testable import Earshot

@MainActor
final class PersonalAudioIntegrationTests: XCTestCase {
    private var root: URL!
    private var sourceDirectory: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "personal-audio-integration-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        sourceDirectory = root.appending(path: "source", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testNamespacedPersonalAudioRestoresWithCrashPositionAndEpisodeKeyStaysLegacy() throws {
        let source = try makePlayableAudioFile(name: "restore.caf", durationSeconds: 20)
        let storage = PersonalAudioStorage(rootURL: root.appending(path: "PersonalAudio"))
        let staged = try storage.stageCopy(from: source, id: UUID().uuidString)
        let managed = try storage.finalize(staged, artworkStagingFilename: nil)
        let container = try ModelContainerFactory.makeInMemory()
        let context = container.mainContext
        let item = PersonalAudioItem(
            id: staged.id, title: "Restored recording", originalFilename: source.lastPathComponent,
            mediaFilename: managed.mediaFilename, typeIdentifier: staged.typeIdentifier,
            durationSeconds: 20, byteSize: staged.byteSize, positionSeconds: 6,
            contentHash: staged.contentHash
        )
        context.insert(item)
        try context.save()
        let identity = PlaybackContentIdentity.personalAudio(item.id)
        XCTAssertEqual(identity.restorationValue, "personal-audio:\(item.id)")
        XCTAssertEqual(PlaybackContentIdentity(restorationValue: "legacy-guid"), .episode("legacy-guid"))

        let settings = AppSettingsStore(context: context)
        settings.setRawValue(identity.restorationValue, for: SettingsKey.lastPlayingEpisodeID)
        UserDefaults.standard.set(identity.restorationValue, forKey: PlayerService.LivePositionKey.episode)
        UserDefaults.standard.set(12, forKey: PlayerService.LivePositionKey.seconds)
        defer {
            settings.setRawValue("", for: SettingsKey.lastPlayingEpisodeID)
            UserDefaults.standard.removeObject(forKey: PlayerService.LivePositionKey.episode)
            UserDefaults.standard.removeObject(forKey: PlayerService.LivePositionKey.seconds)
        }

        let player = PlayerService(audioSession: TestPersonalAudioSession(), personalAudioStorage: storage)
        player.configure(context: context)
        PlaybackStartup.restoreLastEpisode(into: player, context: context)
        XCTAssertEqual(player.nowPlayingPersonalAudioID, item.id)
        XCTAssertNil(player.nowPlayingEpisodeID)
        XCTAssertEqual(player.currentTitle, "Restored recording")
        XCTAssertEqual(player.currentMediaURLForTesting, storage.resolve(managed.mediaFilename))
        XCTAssertEqual(player.currentPositionSeconds, 12)
        XCTAssertFalse(player.isPlaying)
        player.seek(to: 15)
        XCTAssertEqual(item.positionSeconds, 15)
        player.resume()
        XCTAssertTrue(player.isPlaying)
        player.pause()
        XCTAssertFalse(player.isPlaying)
        player.stopAndUnload()
    }

    func testPersonalAudioSpeedOverrideIsScopedToOneFileAndPreservesGlobalDefault() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let context = container.mainContext
        let storage = PersonalAudioStorage(rootURL: root.appending(path: "PersonalAudio"))
        let firstSource = try makePlayableAudioFile(name: "first.caf", durationSeconds: 2)
        let secondSource = try makePlayableAudioFile(name: "second.caf", durationSeconds: 2)
        // These short fixtures share audio bytes; stage independently to avoid
        // duplicate detection obscuring the per-item rate behavior under test.
        let firstID = UUID().uuidString
        let firstStaged = try storage.stageCopy(from: firstSource, id: firstID)
        let firstManaged = try storage.finalize(firstStaged, artworkStagingFilename: nil)
        let secondID = UUID().uuidString
        let secondStaged = try storage.stageCopy(from: secondSource, id: secondID)
        let secondManaged = try storage.finalize(secondStaged, artworkStagingFilename: nil)
        let first = PersonalAudioItem(
            id: firstID, title: "First", originalFilename: firstSource.lastPathComponent,
            mediaFilename: firstManaged.mediaFilename, typeIdentifier: firstStaged.typeIdentifier,
            durationSeconds: 2, byteSize: firstStaged.byteSize, contentHash: firstStaged.contentHash
        )
        let second = PersonalAudioItem(
            id: secondID, title: "Second", originalFilename: secondSource.lastPathComponent,
            mediaFilename: secondManaged.mediaFilename, typeIdentifier: secondStaged.typeIdentifier,
            durationSeconds: 2, byteSize: secondStaged.byteSize, contentHash: secondStaged.contentHash
        )
        context.insert(first)
        context.insert(second)
        try context.save()
        let settings = AppSettingsStore(context: context)
        settings.setDouble(1.6, for: SettingsKey.globalSpeed)
        let player = PlayerService(personalAudioStorage: storage)
        player.configure(context: context)
        defer {
            player.clearPersonalAudioSpeedOverride()
            player.stopAndUnload()
        }

        player.load(first)
        XCTAssertEqual(player.effectiveRate, 1.6, accuracy: 0.001)
        let initialRateRevision = player.effectiveRateRevision
        player.setPersonalAudioSpeedOverride(2.2, announce: false)
        XCTAssertEqual(player.effectiveRate, 2.2, accuracy: 0.001)
        XCTAssertGreaterThan(player.effectiveRateRevision, initialRateRevision,
                             "The VoiceOver speed value must observe per-file rate changes")
        XCTAssertEqual(settings.double(SettingsKey.globalSpeed, default: 1), 1.6, accuracy: 0.001)

        player.load(second)
        XCTAssertEqual(player.effectiveRate, 1.6, accuracy: 0.001,
                       "A different Personal Audio file should use the global default")
        player.load(first)
        XCTAssertEqual(player.effectiveRate, 2.2, accuracy: 0.001,
                       "The first file should retain its own selected speed")

        player.clearPersonalAudioSpeedOverride()
        XCTAssertEqual(player.effectiveRate, 1.6, accuracy: 0.001)
        XCTAssertEqual(settings.double(SettingsKey.globalSpeed, default: 1), 1.6, accuracy: 0.001)
    }

    func testLibraryEntryCountRepresentsAllItemsWithoutAnInlinePreviewLimit() throws {
        let container = try ModelContainerFactory.makeInMemory()
        let context = container.mainContext
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PersonalAudioItem>()), 0)
        XCTAssertEqual(PersonalAudioLibraryPresentation.itemCountValue(0), "0 items")
        for index in 0..<8 {
            context.insert(PersonalAudioItem(
                title: "Recording \(index)", originalFilename: "\(index).caf",
                mediaFilename: "\(index).caf", typeIdentifier: "public.audio",
                byteSize: 1, contentHash: "hash-\(index)"
            ))
        }
        try context.save()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PersonalAudioItem>()), 8)
        XCTAssertEqual(PersonalAudioLibraryPresentation.itemCountValue(1), "1 item")
        XCTAssertEqual(PersonalAudioLibraryPresentation.itemCountValue(8), "8 items")
    }

    func testPersonalAudioRowRotorOffersOnlyApplicableActionsInPodcastOrder() {
        let unplayed = PersonalAudioRowAction.actions(isPlayed: false)
        XCTAssertEqual(unplayed.map(\.label), ["Play now", "Mark as played", "Delete"])
        XCTAssertEqual(unplayed.map(\.isDestructive), [false, false, true])

        let played = PersonalAudioRowAction.actions(isPlayed: true)
        XCTAssertEqual(played.map(\.label), ["Play now", "Mark as unplayed", "Delete"])
        XCTAssertEqual(played.map(\.isDestructive), [false, false, true])
        XCTAssertEqual(QuickActionsRotor.declarationOrder(unplayed).map(\.id), ["delete", "markPlayed", "playNow"])
        XCTAssertEqual(QuickActionsRotor.declarationOrder(played).map(\.id), ["delete", "markUnplayed", "playNow"])
    }

    func testPersonalAudioChapterServiceReadsMP3AndM4AEmbeddedChapters() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let storage = PersonalAudioStorage(rootURL: root.appending(path: "PersonalAudio"))
        let importer = PersonalAudioImporter(storage: storage)
        let context = container.mainContext
        let player = PlayerService(personalAudioStorage: storage)
        player.configure(context: context)
        for ext in ["mp3", "m4a"] {
            let source = try XCTUnwrap(Bundle(for: Self.self).url(
                forResource: "PersonalAudioChapters", withExtension: ext
            ))
            guard case .added(let id) = await importer.addToEarshot(fileURL: source, container: container) else {
                return XCTFail("Could not import embedded chapter fixture .\(ext)")
            }
            let item = try XCTUnwrap(try context.fetch(
                FetchDescriptor<PersonalAudioItem>(predicate: #Predicate { $0.id == id })
            ).first)
            XCTAssertTrue(item.hasEmbeddedChapters)
            player.load(item)
            try await waitForChapters(player)
            let chapters = player.loadedChapterSnapshot
            XCTAssertEqual(chapters.map(\.title), ["Opening", "Main section"], "format: .\(ext)")
            XCTAssertEqual(chapters.count, 2)
            XCTAssertEqual(chapters[0].startTime, 0, accuracy: 0.01)
            XCTAssertEqual(chapters[1].startTime, 0.9, accuracy: 0.01)
            player.stopAndUnload()
        }
    }

    private func waitForChapters(_ player: PlayerService) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while player.chapterCount == 0 && clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThan(player.chapterCount, 0, "Timed out loading Personal Audio chapters")
    }

    func testDeletingCurrentPersonalAudioClearsPlayerAndOnlyManagedCopy() throws {
        let source = try makePlayableAudioFile(name: "preserve-original.caf", durationSeconds: 2)
        let storage = PersonalAudioStorage(rootURL: root.appending(path: "PersonalAudio"))
        let staged = try storage.stageCopy(from: source, id: UUID().uuidString)
        let managed = try storage.finalize(staged, artworkStagingFilename: nil)
        let container = try ModelContainerFactory.makeInMemory()
        let context = container.mainContext
        let item = PersonalAudioItem(
            id: staged.id, title: "Keep source", originalFilename: source.lastPathComponent,
            mediaFilename: managed.mediaFilename, typeIdentifier: staged.typeIdentifier,
            durationSeconds: 2, byteSize: staged.byteSize, contentHash: staged.contentHash
        )
        context.insert(item)
        try context.save()
        let player = PlayerService(audioSession: TestPersonalAudioSession(), personalAudioStorage: storage)
        player.configure(context: context)
        player.play(item)
        XCTAssertTrue(player.isPlaying)
        player.unloadPersonalAudioIfCurrent(id: item.id)
        try PersonalAudioImporter(storage: storage).delete(itemID: item.id, in: container)

        XCTAssertNil(player.nowPlayingPersonalAudioID)
        XCTAssertNil(player.currentTitle)
        XCTAssertEqual(AppSettingsStore(context: context).rawValue(SettingsKey.lastPlayingEpisodeID), "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(storage.resolve(managed.mediaFilename)).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<PersonalAudioItem>()), 0)
    }

    func testPersonalAudioPlayedStateResetsProgressAndCanBeMarkedUnplayed() throws {
        let storage = PersonalAudioStorage(rootURL: root.appending(path: "PersonalAudio"))
        let container = try ModelContainerFactory.makeInMemory()
        let context = container.mainContext
        let item = PersonalAudioItem(
            title: "Practice", originalFilename: "practice.caf", mediaFilename: "missing.caf",
            typeIdentifier: "public.audio", durationSeconds: 20, byteSize: 1,
            positionSeconds: 9, contentHash: "practice"
        )
        context.insert(item)
        try context.save()
        let player = PlayerService(personalAudioStorage: storage)
        player.configure(context: context)
        player.setPersonalAudioPlayed(item.id, played: true)
        XCTAssertTrue(item.isPlayed)
        XCTAssertEqual(item.positionSeconds, 0)
        XCTAssertNotNil(item.playedAt)
        player.setPersonalAudioPlayed(item.id, played: false)
        XCTAssertFalse(item.isPlayed)
        XCTAssertNil(item.playedAt)
    }

    private func makePlayableAudioFile(name: String, durationSeconds: Double) throws -> URL {
        let url = sourceDirectory.appending(path: name)
        let sampleRate = 8_000.0
        let format = try XCTUnwrap(AVAudioFormat(
            standardFormatWithSampleRate: sampleRate, channels: 1
        ))
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
        ]
        let audioFile = try AVAudioFile(forWriting: url, settings: settings)
        let capacity = AVAudioFrameCount(sampleRate * durationSeconds)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity))
        buffer.frameLength = capacity
        try audioFile.write(from: buffer)
        return url
    }
}

@MainActor
private final class TestPersonalAudioSession: PlayerAudioSession {
    let notificationObject: AnyObject = NSObject()
    func setCategory(
        _ category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions
    ) throws {}
    func activate() throws {}
    func setPreferredOutputNumberOfChannels(_ count: Int) throws {}
}
