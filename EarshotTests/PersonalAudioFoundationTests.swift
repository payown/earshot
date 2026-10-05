import AVFoundation
import SwiftData
import XCTest
@testable import Earshot

@MainActor
final class PersonalAudioFoundationTests: XCTestCase {
    private var root: URL!
    private var sourceDirectory: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "personal-audio-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        sourceDirectory = root.appending(path: "source", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testItemPersistsWithStableGeneratedIdentityAndDeviceLocalModel() throws {
        let container = try ModelContainerFactory.makeInMemory()
        let item = PersonalAudioItem(
            title: "Lesson",
            originalFilename: "language-lesson.wav",
            mediaFilename: "\(UUID().uuidString).wav",
            typeIdentifier: "public.wav",
            durationSeconds: 12.5,
            byteSize: 128,
            contentHash: "abc"
        )
        let identity = item.id
        container.mainContext.insert(item)
        try container.mainContext.save()

        let loaded = try XCTUnwrap(
            try ModelContext(container).fetch(FetchDescriptor<PersonalAudioItem>()).first
        )
        XCTAssertEqual(loaded.id, identity)
        XCTAssertEqual(loaded.title, "Lesson")
        XCTAssertEqual(loaded.durationSeconds, 12.5)
        XCTAssertEqual(loaded.positionSeconds, 0)
        XCTAssertFalse(loaded.isPlayed)
        XCTAssertEqual(loaded.contentHash, "abc")
        XCTAssertFalse(Schema(EarshotSchemaV13.mirroredModels).entities.contains {
            $0.name == "PersonalAudioItem"
        })
    }

    func testStorageUsesGeneratedRelativeNamesCopiesSourceAndCanResolveAfterContainerRelocation() throws {
        let source = try makeWaveFile(name: "my recording.wav", audioBytes: 64 * 1024)
        let id = UUID().uuidString
        let storage = PersonalAudioStorage(rootURL: root.appending(path: "container-a/PersonalAudio"))
        let staged = try storage.stageCopy(from: source, id: id)
        XCTAssertEqual(staged.id, id)
        XCTAssertEqual(staged.contentHash.count, 64)
        XCTAssertEqual(staged.byteSize, Int64(64 * 1024 + 44))
        XCTAssertTrue(staged.stagingFilename.hasPrefix(".staging-"))
        XCTAssertTrue(staged.stagingFilename.contains(id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))

        let result = try storage.finalize(staged, artworkStagingFilename: nil)
        XCTAssertEqual(result.mediaFilename, "\(id).wav")
        XCTAssertEqual(storage.resolve(result.mediaFilename)?.lastPathComponent, result.mediaFilename)
        let relocated = PersonalAudioStorage(rootURL: root.appending(path: "container-b/PersonalAudio"))
        XCTAssertEqual(relocated.resolve(result.mediaFilename)?.path, root
            .appending(path: "container-b/PersonalAudio/\(result.mediaFilename)").path)
        XCTAssertFalse(try XCTUnwrap(storage.rootURL.resourceValues(
            forKeys: [.isExcludedFromBackupKey]
        ).isExcludedFromBackup))
        XCTAssertFalse(try XCTUnwrap(storage.resolve(result.mediaFilename)?.resourceValues(
            forKeys: [.isExcludedFromBackupKey]
        ).isExcludedFromBackup))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testStorageReportsBoundedCopyProgressAndPreservesActiveStaging() throws {
        let source = try makeWaveFile(name: "large.wav", audioBytes: 7 * 1_048_576)
        let storage = PersonalAudioStorage(rootURL: root.appending(path: "PersonalAudio"))
        let updates = CopyProgressRecorder()
        let staged = try storage.stageCopy(from: source, id: UUID().uuidString) { updates.append($0) }
        XCTAssertGreaterThanOrEqual(updates.values.count, 2)
        XCTAssertTrue(updates.values.contains { $0.copiedBytes >= 4 * 1_048_576 })
        XCTAssertEqual(staged.byteSize, Int64(7 * 1_048_576 + 44))

        let orphanID = UUID().uuidString
        let orphan = root.appending(path: "PersonalAudio/\(orphanID).mp3")
        try Data([1, 2, 3]).write(to: orphan)
        let oldStaging = root.appending(path: "PersonalAudio/.staging-\(UUID().uuidString).partial.wav")
        try Data([4, 5, 6]).write(to: oldStaging)
        let artworkStaging = try storage.writeStagedArtwork(Data([7, 8, 9]), id: staged.id)
        try storage.reconcile(keeping: [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: storage.rootURL.appending(path: staged.stagingFilename).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: storage.rootURL.appending(path: artworkStaging).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldStaging.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        storage.discardStaged(staged, artworkFilename: artworkStaging)
    }

    func testFileResetRemovesPersonalAudioCopiesWithoutDeletingOriginals() async throws {
        let support = root.appending(path: "support")
        let documents = root.appending(path: "documents")
        let caches = root.appending(path: "caches")
        let storage = PersonalAudioStorage(rootURL: support.appending(path: PersonalAudioStorage.subdirectoryName))
        let source = try makeWaveFile(name: "original.wav", audioBytes: 1_024)
        let staged = try storage.stageCopy(from: source, id: UUID().uuidString)
        let managed = try storage.finalize(staged, artworkStagingFilename: nil)

        let success = await SettingsReset.performFileReset(
            applicationSupport: support, documents: documents, caches: caches
        )
        XCTAssertTrue(success)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.rootURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.appending(path: PersonalAudioStorage.subdirectoryName).appending(path: managed.mediaFilename).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testFileResetRetriesFailedQuarantineCleanup() async throws {
        let support = root.appending(path: "support")
        let documents = root.appending(path: "documents")
        let caches = root.appending(path: "caches")
        let storage = PersonalAudioStorage(rootURL: support.appending(path: PersonalAudioStorage.subdirectoryName))
        try storage.prepare()
        try Data([1, 2, 3]).write(to: storage.rootURL.appending(path: "recording.wav"))

        let firstAttempt = await SettingsReset.performFileReset(
            applicationSupport: support, documents: documents, caches: caches,
            removeQuarantine: { _ in throw CocoaError(.fileWriteNoPermission) }
        )
        XCTAssertFalse(firstAttempt)
        let journal = support.appending(path: "settings-reset-transaction.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))

        let retry = await SettingsReset.performFileReset(
            applicationSupport: support, documents: documents, caches: caches
        )
        XCTAssertTrue(retry)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.rootURL.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: support.path)
        XCTAssertFalse(leftovers.contains { $0.hasPrefix("settings-reset-quarantine-") })
    }

    func testStorageRejectsNonAudioAndCleansCopyOnReadFailure() throws {
        let text = sourceDirectory.appending(path: "notes.txt")
        try Data("not audio".utf8).write(to: text)
        let storage = PersonalAudioStorage(rootURL: root.appending(path: "PersonalAudio"))
        XCTAssertThrowsError(try storage.stageCopy(from: text, id: UUID().uuidString))

        let missing = sourceDirectory.appending(path: "missing.wav")
        XCTAssertThrowsError(try storage.stageCopy(from: missing, id: UUID().uuidString))
        let contents = try FileManager.default.contentsOfDirectory(
            at: storage.rootURL, includingPropertiesForKeys: nil
        )
        XCTAssertTrue(contents.isEmpty)
    }

    func testStorageDeletionRemovesOnlyManagedCopies() throws {
        let source = try makeWaveFile(name: "keep.wav", audioBytes: 16_000)
        let storage = PersonalAudioStorage(rootURL: root.appending(path: "PersonalAudio"))
        let staged = try storage.stageCopy(from: source, id: UUID().uuidString)
        let managed = try storage.finalize(staged, artworkStagingFilename: nil)
        try storage.removeManagedFiles(mediaFilename: managed.mediaFilename, artworkFilename: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.resolve(managed.mediaFilename)!.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testImporterExtractsFallbackTitleAndDurationAndAllowsFilesWithoutChapters() async throws {
        let source = try makePlayableAudioFile(name: "  Field recording.caf", durationSeconds: 1)
        let container = try ModelContainerFactory.makeInMemory()
        let storage = PersonalAudioStorage(rootURL: root.appending(path: "PersonalAudio"))
        let importer = PersonalAudioImporter(storage: storage)

        let outcome = await importer.addToEarshot(fileURL: source, container: container)
        guard case .added(let id) = outcome else {
            return XCTFail("Expected a playable audio file to be added, got \(outcome)")
        }
        let item = try XCTUnwrap(try ModelContext(container).fetch(
            FetchDescriptor<PersonalAudioItem>(predicate: #Predicate { $0.id == id })
        ).first)
        XCTAssertEqual(item.title, "Field recording")
        XCTAssertNil(item.artist)
        XCTAssertNil(item.album)
        XCTAssertEqual(item.durationSeconds ?? 0, 1, accuracy: 0.15)
        XCTAssertFalse(item.hasEmbeddedChapters)
        XCTAssertNil(item.artworkFilename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: storage.resolve(item.mediaFilename)!.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testImporterRejectsCorruptAudioWithoutCreatingItemOrFinalFile() async throws {
        let source = sourceDirectory.appending(path: "corrupt.wav")
        try Data("broken wave".utf8).write(to: source)
        let container = try ModelContainerFactory.makeInMemory()
        let storage = PersonalAudioStorage(rootURL: root.appending(path: "PersonalAudio"))
        let importer = PersonalAudioImporter(storage: storage)

        let outcome = await importer.addToEarshot(fileURL: source, container: container)
        guard case .failed = outcome else { return XCTFail("Expected corrupt audio to fail") }
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<PersonalAudioItem>()), 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(
            at: storage.rootURL, includingPropertiesForKeys: nil
        ).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testExactDuplicatePromptsAndAddAnywayCreatesDifferentIdentityAndFilename() async throws {
        let source = try makePlayableAudioFile(name: "first.caf", durationSeconds: 1)
        let container = try ModelContainerFactory.makeInMemory()
        let storage = PersonalAudioStorage(rootURL: root.appending(path: "PersonalAudio"))
        let importer = PersonalAudioImporter(storage: storage)

        guard case .added(let firstID) = await importer.addToEarshot(fileURL: source, container: container),
              case .duplicateNeedsConfirmation(let prepared) = await importer.addToEarshot(
                fileURL: source, container: container
              ) else { return XCTFail("Exact content should require confirmation") }
        guard case .added(let secondID) = importer.addAnyway(prepared, in: container) else {
            return XCTFail("Add Anyway should create another item")
        }
        XCTAssertNotEqual(firstID, secondID)
        let items = try ModelContext(container).fetch(FetchDescriptor<PersonalAudioItem>())
        XCTAssertEqual(items.count, 2)
        XCTAssertNotEqual(items[0].mediaFilename, items[1].mediaFilename)
        XCTAssertEqual(items[0].contentHash, items[1].contentHash)
    }

    func testDuplicateCancelAndPersistenceFailureLeaveNoManagedOrStagedFiles() async throws {
        let source = try makePlayableAudioFile(name: "source.caf", durationSeconds: 1)
        let container = try ModelContainerFactory.makeInMemory()
        let storage = PersonalAudioStorage(rootURL: root.appending(path: "PersonalAudio"))
        let importer = PersonalAudioImporter(storage: storage)
        guard case .added = await importer.addToEarshot(fileURL: source, container: container),
              case .duplicateNeedsConfirmation(let prepared) = await importer.addToEarshot(
                fileURL: source, container: container
              ) else { return XCTFail("Expected duplicate confirmation") }
        importer.cancel(prepared)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<PersonalAudioItem>()), 1)

        let failureStorage = PersonalAudioStorage(rootURL: root.appending(path: "failed/PersonalAudio"))
        let distinctSource = try makePlayableAudioFile(name: "distinct.caf", durationSeconds: 2)
        let failingImporter = PersonalAudioImporter(storage: failureStorage) { _, _ in
            throw TestFailure.persistence
        }
        guard case .failed(.persistenceFailure) = await failingImporter.addToEarshot(
            fileURL: distinctSource, container: container
        ) else { return XCTFail("Expected persistence failure result") }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(
            at: failureStorage.rootURL, includingPropertiesForKeys: nil
        ).isEmpty)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<PersonalAudioItem>()), 1)
    }


    private enum TestFailure: Error { case persistence }

    private func makeWaveFile(name: String, audioBytes: Int) throws -> URL {
        let url = sourceDirectory.appending(path: name)
        let alignedAudioBytes = audioBytes - audioBytes % 2
        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        data.appendLE(UInt32(36 + alignedAudioBytes))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        data.appendLE(UInt32(16))
        data.appendLE(UInt16(1)) // PCM
        data.appendLE(UInt16(1)) // mono
        data.appendLE(UInt32(8_000))
        data.appendLE(UInt32(16_000))
        data.appendLE(UInt16(2))
        data.appendLE(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        data.appendLE(UInt32(alignedAudioBytes))
        data.append(Data(count: alignedAudioBytes))
        try data.write(to: url)
        return url
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

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}

private final class CopyProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [PersonalAudioCopyProgress] = []

    var values: [PersonalAudioCopyProgress] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: PersonalAudioCopyProgress) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(value)
    }
}
