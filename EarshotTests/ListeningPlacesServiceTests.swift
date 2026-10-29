import SwiftData
import XCTest
@testable import Earshot

@MainActor
final class ListeningPlacesServiceTests: XCTestCase {
    func testOlderFileClassificationRequiresMatchingMetadataAndStrictVersion() {
        func isOlder(app: String, device: String = "1234abcd", format: String = "listening-places/1", current: String = "1.2.5") -> Bool {
            let snapshot = ListeningPlacesRestoredSnapshot(records: [], signatures: [:], updatedAtByID: [:], fileFormat: format, fileDevice: device, fileApp: app)
            return snapshot.isOlderEarshotFile(deviceID: "1234abcd", currentVersion: current)
        }
        XCTAssertTrue(isOlder(app: "earshot/1.2.4"))
        XCTAssertTrue(isOlder(app: "earshot/1.1.99"))
        XCTAssertFalse(isOlder(app: "earshot/1.2.5"))
        XCTAssertFalse(isOlder(app: "earshot/1.2.6"))
        XCTAssertFalse(isOlder(app: "other/1.2.4"))
        XCTAssertFalse(isOlder(app: "earshot/1.2.4", device: "87654321"))
        XCTAssertFalse(isOlder(app: "earshot/1.2.4", format: "other/1"))
        for invalid in ["earshot/1.2", "earshot/1.2.4-beta", "earshot/1.02.4", "earshot/1.2.-1", "earshot/1.2.４", "earshot/1.2.999999999999999999999999"] {
            XCTAssertFalse(isOlder(app: invalid), invalid)
        }
        XCTAssertFalse(isOlder(app: "earshot/1.2.4", current: "unknown"))
    }

    func testOlderFileFailureAnnouncementIsForegroundOnlyDeduplicatedAndResetBySuccess() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try makeContainer()
        let podcast = Podcast(feedURL: "https://example.com/feed", title: "Show")
        let episode = Episode(guid: "old-file-failure", title: "Episode", audioURL: "https://example.com/audio", positionSeconds: 30)
        episode.podcast = podcast
        container.mainContext.insert(podcast)
        container.mainContext.insert(episode)
        try container.mainContext.save()
        let initial = ListeningPlacesService()
        initial.configure(context: container.mainContext)
        await initial.chooseFolder(directory)
        let file = try deviceFile(in: directory)
        initial.releasePersistence()
        try setSelfReportedApp("earshot/0.0.1", in: file)

        let writer = LegacyFailureWriter()
        var canSpeak = false
        var announcements: [String] = []
        let service = ListeningPlacesService(
            writeDeviceFile: { bookmark, deviceID, data in try await writer.write(bookmark: bookmark, deviceID: deviceID, data: data) },
            canAnnounce: { canSpeak },
            announceOlderFileFailure: { announcements.append($0) }
        )
        service.configure(context: container.mainContext)
        await service.chooseFolder(directory)
        let broken = directory.appending(path: "broken", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("file".utf8).write(to: broken.appending(path: "Listening Places"))
        canSpeak = true
        await service.chooseFolder(broken)
        XCTAssertTrue(announcements.isEmpty, "A folder-preparation failure is not a device-file write failure")
        canSpeak = false
        await service.setIncludeLabels(true)
        XCTAssertTrue(announcements.isEmpty, "A background or VoiceOver-off failure must not be spoken")
        canSpeak = true
        await service.writeNow()
        XCTAssertEqual(announcements, ["Could not write listening places."])
        await service.writeNow()
        XCTAssertEqual(announcements.count, 1, "Repeated failures should be announced once")

        await writer.setFailing(false)
        await service.writeNow()
        await writer.setFailing(true)
        await service.setIncludeLabels(false)
        XCTAssertEqual(announcements.count, 1, "A successful write ends the older-file observation")

        try setSelfReportedApp("earshot/0.0.1", in: file)
        await service.chooseFolder(directory)
        XCTAssertEqual(announcements.count, 2, "A newly observed old file may report a new failure")
        service.releasePersistence()
    }

    func testForeignFileWriteFailureIsNotAnnounced() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try makeContainer()
        let podcast = Podcast(feedURL: "https://example.com/feed", title: "Show")
        let episode = Episode(guid: "foreign-file", title: "Episode", audioURL: "https://example.com/audio", positionSeconds: 30)
        episode.podcast = podcast
        container.mainContext.insert(podcast)
        container.mainContext.insert(episode)
        try container.mainContext.save()
        let initial = ListeningPlacesService()
        initial.configure(context: container.mainContext)
        await initial.chooseFolder(directory)
        let file = try deviceFile(in: directory)
        initial.releasePersistence()
        try setSelfReportedApp("another-app/0.0.1", in: file)
        let writer = LegacyFailureWriter()
        var announcements: [String] = []
        let service = ListeningPlacesService(
            writeDeviceFile: { bookmark, deviceID, data in try await writer.write(bookmark: bookmark, deviceID: deviceID, data: data) },
            canAnnounce: { true }, announceOlderFileFailure: { announcements.append($0) }
        )
        service.configure(context: container.mainContext)
        await service.chooseFolder(directory)
        await service.setIncludeLabels(true)
        guard case .failed = service.status else { return XCTFail("The injected write must fail") }
        XCTAssertTrue(announcements.isEmpty)
        service.releasePersistence()
    }

    func testOlderFileWriteFailureDoesNotAnnounceAfterCancellationOrSupersession() async throws {
        for cancel in [true, false] {
            let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let container = try makeContainer()
            let podcast = Podcast(feedURL: "https://example.com/feed", title: "Show")
            let episode = Episode(guid: "old-stale", title: "Episode", audioURL: "https://example.com/audio", positionSeconds: 30)
            episode.podcast = podcast
            container.mainContext.insert(podcast)
            container.mainContext.insert(episode)
            try container.mainContext.save()
            let initial = ListeningPlacesService()
            initial.configure(context: container.mainContext)
            await initial.chooseFolder(directory)
            let file = try deviceFile(in: directory)
            initial.releasePersistence()
            try setSelfReportedApp("earshot/0.0.1", in: file)
            let writer = LegacyFailureWriter()
            var announcements: [String] = []
            let service = ListeningPlacesService(
                writeDeviceFile: { bookmark, deviceID, data in try await writer.write(bookmark: bookmark, deviceID: deviceID, data: data) },
                canAnnounce: { true }, announceOlderFileFailure: { announcements.append($0) }
            )
            service.configure(context: container.mainContext)
            await service.chooseFolder(directory)
            await writer.holdNextWrite()
            let write = Task { await service.setIncludeLabels(true) }
            await writer.waitUntilHeld()
            if cancel { write.cancel() } else { await service.setEnabled(false) }
            await writer.resumeWrite()
            await write.value
            XCTAssertTrue(announcements.isEmpty)
            service.releasePersistence()
        }
    }

    private func setSelfReportedApp(_ app: String, in file: URL) throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        json["app"] = app
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: file, options: .atomic)
    }

    func testSnapshotPreparationRunsOffMainAndReturnsValueOnlyPayload() async throws {
        let container = try makeContainer()
        let podcast = Podcast(feedURL: "https://example.com/feed", title: "Example Show")
        let episode = Episode(
            guid: "background-guid",
            title: "Background Episode",
            audioURL: "https://example.com/audio.mp3",
            durationSeconds: 600,
            positionSeconds: 42
        )
        episode.podcast = podcast
        container.mainContext.insert(podcast)
        container.mainContext.insert(episode)
        try container.mainContext.save()

        let loader = await ListeningPlacesSnapshotLoader.makeBackground(
            modelContainer: container
        )
        let executesOnMain = await loader.isExecutingOnMainThreadForTesting()
        XCTAssertFalse(executesOnMain)

        let prepared = try await loader.prepare(
            pendingZeroSnapshots: [],
            includeLabels: true,
            previousRecords: [],
            previousSignatures: [:],
            previousUpdatedAtByID: [:],
            deviceID: "1234abcd",
            appVersion: "earshot/test",
            now: Date(timeIntervalSince1970: 1_000)
        )

        XCTAssertEqual(prepared.inspectedCount, 1)
        XCTAssertEqual(prepared.records.count, 1)
        XCTAssertEqual(prepared.records.first?.positionMilliseconds, 42_000)
        XCTAssertEqual(prepared.records.first?.label, "Example Show: Background Episode")
        XCTAssertNotNil(prepared.data)
    }

    func testChoosingFolderWritesMeaningfulStateWithoutPrivateLabels() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "listening-places-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try makeContainer()
        let podcast = Podcast(feedURL: "https://private.example/feed", title: "Private Show")
        let episode = Episode(
            guid: "episode-guid",
            title: "Private Episode",
            audioURL: "https://private.example/audio.mp3",
            durationSeconds: 1_800,
            positionSeconds: 90
        )
        episode.podcast = podcast
        container.mainContext.insert(podcast)
        container.mainContext.insert(episode)
        try container.mainContext.save()

        let service = ListeningPlacesService()
        service.configure(context: container.mainContext)
        await service.chooseFolder(directory)

        let devices = directory
            .appending(path: "Listening Places", directoryHint: .isDirectory)
            .appending(path: "devices", directoryHint: .isDirectory)
        let files = try FileManager.default.contentsOfDirectory(
            at: devices,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        let fileURL = try XCTUnwrap(files.first)
        let data = try Data(contentsOf: fileURL)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let records = try XCTUnwrap(json["records"] as? [[String: Any]])

        XCTAssertEqual(json["format"] as? String, ListeningPlacesFormat.identifier)
        XCTAssertEqual(records.count, 1)
        XCTAssertNil(records[0]["label"])
        XCTAssertNil(records[0]["feed"])
        XCTAssertEqual(records[0]["position_ms"] as? Int, 90_000)
        let readme = try String(
            contentsOf: directory.appending(path: "Listening Places/README.txt"), encoding: .utf8
        )
        XCTAssertTrue(readme.contains("Earshot does not import changes from other devices"))
        XCTAssertTrue(readme.contains("iCloud Sync separately syncs"))

        episode.positionSeconds = 0
        try container.mainContext.save()
        postEpisodeUserStateChanges([episode])
        await service.writeNow()
        let resetData = try Data(contentsOf: fileURL)
        let resetJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: resetData) as? [String: Any]
        )
        let resetRecords = try XCTUnwrap(resetJSON["records"] as? [[String: Any]])
        XCTAssertEqual(resetRecords.first?["position_ms"] as? Int, 0)
        XCTAssertEqual(resetRecords.first?["played"] as? Bool, false)

        await service.stopSharingAndRemoveDeviceFile()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertEqual(service.status, .notConfigured)
    }

    func testListeningPlacesConfigurationKeysStayDeviceLocal() {
        XCTAssertTrue(AppSettingScope.isLocal(SettingsKey.listeningPlacesEnabled))
        XCTAssertTrue(AppSettingScope.isLocal(SettingsKey.listeningPlacesBookmark))
        XCTAssertTrue(AppSettingScope.isLocal(SettingsKey.listeningPlacesFolderName))
        XCTAssertTrue(AppSettingScope.isLocal(SettingsKey.listeningPlacesDeviceID))
        XCTAssertTrue(AppSettingScope.isLocal(SettingsKey.listeningPlacesIncludeLabels))
    }

    func testTurningOffNamesWaitsForAndReplacesAnOlderWrite() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "listening-places-in-flight-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try makeContainer()
        let podcast = Podcast(feedURL: "https://example.com/feed", title: "Private Show")
        let episode = Episode(guid: "private-guid", title: "Private Episode",
                              audioURL: "https://example.com/audio.mp3", positionSeconds: 60)
        episode.podcast = podcast
        container.mainContext.insert(podcast)
        container.mainContext.insert(episode)
        try container.mainContext.save()
        let writer = SuspendedListeningPlacesWriter()
        let service = ListeningPlacesService(writeDeviceFile: { bookmark, deviceID, data in
            try await writer.write(bookmark: bookmark, deviceID: deviceID, data: data)
        })
        service.configure(context: container.mainContext)
        await service.chooseFolder(directory)
        let file = try deviceFile(in: directory)
        await writer.suspendNextWrite()
        let addingNames = Task { await service.setIncludeLabels(true) }
        await writer.waitUntilSuspended()
        let removingNames = Task { await service.setIncludeLabels(false) }
        for _ in 0..<100 where service.includeLabels { await Task.yield() }
        XCTAssertFalse(service.includeLabels)
        await writer.resumeWrite()
        await addingNames.value
        await removingNames.value

        let contents = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(contents.contains("Private Show"))
        XCTAssertFalse(contents.contains("Private Episode"))
    }

    func testStopSharingWaitsForAnOlderWriteBeforeRemovingFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "listening-places-stop-in-flight-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try makeContainer()
        let podcast = Podcast(feedURL: "https://example.com/feed", title: "Show")
        let episode = Episode(guid: "stop-guid", title: "Episode",
                              audioURL: "https://example.com/audio.mp3", positionSeconds: 60)
        episode.podcast = podcast
        container.mainContext.insert(podcast)
        container.mainContext.insert(episode)
        try container.mainContext.save()
        let writer = SuspendedListeningPlacesWriter()
        let service = ListeningPlacesService(writeDeviceFile: { bookmark, deviceID, data in
            try await writer.write(bookmark: bookmark, deviceID: deviceID, data: data)
        })
        service.configure(context: container.mainContext)
        await service.chooseFolder(directory)
        let file = try deviceFile(in: directory)
        await writer.suspendNextWrite()
        let addingNames = Task { await service.setIncludeLabels(true) }
        await writer.waitUntilSuspended()
        let stopping = Task { await service.stopSharingAndRemoveDeviceFile() }
        for _ in 0..<100 where !service.isRemovingDeviceFileForTesting { await Task.yield() }
        XCTAssertTrue(service.isRemovingDeviceFileForTesting)
        await writer.resumeWrite()
        await addingNames.value
        await stopping.value

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(service.status, .notConfigured)
    }

    func testConcurrentPrivacyChangesDoNotOverlapFileWrites() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "listening-places-multiple-waiters-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try makeContainer()
        let podcast = Podcast(feedURL: "https://example.com/feed", title: "Private Show")
        let episode = Episode(guid: "multiple-guid", title: "Private Episode",
                              audioURL: "https://example.com/audio.mp3", positionSeconds: 60)
        episode.podcast = podcast
        container.mainContext.insert(podcast)
        container.mainContext.insert(episode)
        try container.mainContext.save()
        let writer = SuspendedListeningPlacesWriter()
        let service = ListeningPlacesService(writeDeviceFile: { bookmark, deviceID, data in
            try await writer.write(bookmark: bookmark, deviceID: deviceID, data: data)
        })
        service.configure(context: container.mainContext)
        await service.chooseFolder(directory)
        let file = try deviceFile(in: directory)
        await writer.suspendNextWrite()
        let first = Task { await service.setIncludeLabels(true) }
        await writer.waitUntilSuspended()
        let second = Task { await service.setIncludeLabels(false) }
        for _ in 0..<100 where service.includeLabels { await Task.yield() }
        XCTAssertFalse(service.includeLabels)
        let third = Task { await service.setIncludeLabels(true) }
        for _ in 0..<100 where !service.includeLabels { await Task.yield() }
        XCTAssertTrue(service.includeLabels)
        let last = Task { await service.setIncludeLabels(false) }
        for _ in 0..<100 where service.includeLabels { await Task.yield() }
        XCTAssertFalse(service.includeLabels)
        await writer.resumeWrite()
        await first.value
        await second.value
        await third.value
        await last.value

        let peakWrites = await writer.maximumConcurrentWrites()
        XCTAssertEqual(peakWrites, 1)
        let contents = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(contents.contains("Private Show"))
        XCTAssertFalse(contents.contains("Private Episode"))
    }

    func testPrivacyChangeDuringRemovalRecreatesTheFileWithCurrentSettings() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "listening-places-removal-race-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try makeContainer()
        let podcast = Podcast(feedURL: "https://example.com/feed", title: "Private Show")
        let episode = Episode(guid: "removal-guid", title: "Private Episode",
                              audioURL: "https://example.com/audio.mp3", positionSeconds: 60)
        episode.podcast = podcast
        container.mainContext.insert(podcast)
        container.mainContext.insert(episode)
        try container.mainContext.save()
        let remover = SuspendedListeningPlacesRemover()
        let service = ListeningPlacesService(removeDeviceFile: { bookmark, deviceID in
            try await remover.remove(bookmark: bookmark, deviceID: deviceID)
        })
        service.configure(context: container.mainContext)
        await service.chooseFolder(directory)
        let file = try deviceFile(in: directory)
        let stopping = Task { await service.stopSharingAndRemoveDeviceFile() }
        await remover.waitUntilSuspended()
        await service.setIncludeLabels(true)
        await service.setIncludeLabels(false)
        await remover.resumeRemoval()
        await stopping.value

        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: file.path) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let contents = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(contents.contains("Private Show"))
        XCTAssertFalse(contents.contains("Private Episode"))
        XCTAssertTrue(service.enabled)
    }

    func testEnablingSharingDuringRemovalPreservesFolderAndRecreatesFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "listening-places-enable-removal-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try makeContainer()
        let podcast = Podcast(feedURL: "https://example.com/feed", title: "Show")
        let episode = Episode(guid: "enable-removal-guid", title: "Episode",
                              audioURL: "https://example.com/audio.mp3", positionSeconds: 60)
        episode.podcast = podcast
        container.mainContext.insert(podcast)
        container.mainContext.insert(episode)
        try container.mainContext.save()
        let remover = SuspendedListeningPlacesRemover()
        let service = ListeningPlacesService(removeDeviceFile: { bookmark, deviceID in
            try await remover.remove(bookmark: bookmark, deviceID: deviceID)
        })
        service.configure(context: container.mainContext)
        await service.chooseFolder(directory)
        let file = try deviceFile(in: directory)
        await service.setEnabled(false)
        let stopping = Task { await service.stopSharingAndRemoveDeviceFile() }
        await remover.waitUntilSuspended()
        await service.setEnabled(true)
        await remover.resumeRemoval()
        await stopping.value

        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: file.path) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(service.enabled)
        XCTAssertEqual(service.folderName, directory.lastPathComponent)
        let contents = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(contents.contains("60000"))
    }

    func testTurningOffNamesRemovesThemFromRetainedResetInActualFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "listening-places-privacy-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try makeContainer()
        let podcast = Podcast(feedURL: "https://private.example/feed", title: "Private Show")
        let episode = Episode(guid: "privacy-guid", title: "Private Episode",
                              audioURL: "https://private.example/audio.mp3",
                              durationSeconds: 600, positionSeconds: 60)
        episode.podcast = podcast
        container.mainContext.insert(podcast)
        container.mainContext.insert(episode)
        try container.mainContext.save()
        let service = ListeningPlacesService()
        service.configure(context: container.mainContext)
        await service.chooseFolder(directory)
        await service.setIncludeLabels(true)
        let file = try deviceFile(in: directory)
        func firstRecord() throws -> [String: Any] {
            let data = try Data(contentsOf: file)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            return try XCTUnwrap((json["records"] as? [[String: Any]])?.first)
        }
        let activeTimestamp = try XCTUnwrap(try firstRecord()["updated_at"] as? String)
        await service.setIncludeLabels(false)
        XCTAssertEqual(try firstRecord()["updated_at"] as? String, activeTimestamp,
                       "Removing a label must not make old progress appear newer")
        await service.setIncludeLabels(true)
        XCTAssertEqual(try firstRecord()["updated_at"] as? String, activeTimestamp,
                       "Adding a label must not change the listening timestamp")
        episode.durationSeconds = 700
        try container.mainContext.save()
        await service.writeNow()
        XCTAssertEqual(try firstRecord()["duration_ms"] as? Int, 700_000)
        XCTAssertEqual(try firstRecord()["updated_at"] as? String, activeTimestamp,
                       "A metadata correction must not change the listening timestamp")
        episode.positionSeconds = 0
        try container.mainContext.save()
        postEpisodeUserStateChanges([episode])
        await service.writeNow()
        let before = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(before.contains("Private Show: Private Episode"))
        let resetTimestamp = try XCTUnwrap(try firstRecord()["updated_at"] as? String)

        await service.setIncludeLabels(false)

        let after = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(after.contains("Private Show"))
        XCTAssertFalse(after.contains("Private Episode"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(after.utf8)) as? [String: Any])
        let records = try XCTUnwrap(json["records"] as? [[String: Any]])
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0]["position_ms"] as? Int, 0)
        XCTAssertNil(records[0]["label"])
        XCTAssertEqual(records[0]["updated_at"] as? String, resetTimestamp,
                       "Removing a retained reset label must preserve its listening timestamp")
    }

    func testResetWhileSharingOffKeepsPreviouslyExportedPositionAndTimestamp() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "listening-places-reset-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try makeContainer()
        let podcast = Podcast(feedURL: "https://example.com/feed", title: "Show")
        let episode = Episode(guid: "reset-guid", title: "Episode",
                              audioURL: "https://example.com/audio.mp3",
                              durationSeconds: 600, positionSeconds: 60)
        episode.podcast = podcast
        container.mainContext.insert(podcast)
        container.mainContext.insert(episode)
        try container.mainContext.save()
        let service = ListeningPlacesService()
        service.configure(context: container.mainContext)
        await service.chooseFolder(directory)
        let original = try Data(contentsOf: deviceFile(in: directory))
        let originalJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        let originalRecord = try XCTUnwrap((originalJSON["records"] as? [[String: Any]])?.first)
        await service.setEnabled(false)
        episode.positionSeconds = 0
        try container.mainContext.save()
        postEpisodeUserStateChanges([episode])
        service.releasePersistence()
        let restarted = ListeningPlacesService()
        restarted.configure(context: container.mainContext)
        await restarted.setEnabled(true)

        let data = try Data(contentsOf: deviceFile(in: directory))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let records = try XCTUnwrap(json["records"] as? [[String: Any]])
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0]["position_ms"] as? Int, 60_000)
        XCTAssertEqual(records[0]["played"] as? Bool, false)
        XCTAssertEqual(records[0]["updated_at"] as? String, originalRecord["updated_at"] as? String)
    }

    func testRestoredResetRemovesFeedAddressEvenWithoutLabel() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "listening-places-feed-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try makeContainer()
        let podcast = Podcast(feedURL: "https://private.example/feed", title: "Private Show")
        let episode = Episode(guid: "feed-privacy-guid", title: "Episode",
                              audioURL: "https://private.example/audio.mp3",
                              durationSeconds: 600, positionSeconds: 60)
        episode.podcast = podcast
        container.mainContext.insert(podcast)
        container.mainContext.insert(episode)
        try container.mainContext.save()
        let service = ListeningPlacesService()
        service.configure(context: container.mainContext)
        await service.chooseFolder(directory)
        await service.setIncludeLabels(true)
        episode.positionSeconds = 0
        try container.mainContext.save()
        postEpisodeUserStateChanges([episode])
        await service.writeNow()
        service.releasePersistence()

        let file = try deviceFile(in: directory)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var records = try XCTUnwrap(json["records"] as? [[String: Any]])
        let originalTimestamp = try XCTUnwrap(records[0]["updated_at"] as? String)
        records[0].removeValue(forKey: "label")
        records[0]["feed"] = "https://private.example/feed"
        json["records"] = records
        try JSONSerialization.data(withJSONObject: json).write(to: file)

        let restarted = ListeningPlacesService()
        restarted.configure(context: container.mainContext)
        await restarted.writeNow()
        for _ in 0..<100 {
            let data = try Data(contentsOf: file)
            json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            records = try XCTUnwrap(json["records"] as? [[String: Any]])
            if records.first?["feed"] == nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(records.count, 1)
        XCTAssertNil(records[0]["feed"])
        XCTAssertNil(records[0]["label"])
        XCTAssertEqual(records[0]["updated_at"] as? String, originalTimestamp)
    }

    func testRestoredExportDoesNotInventTimestampForUnobservedReset() async throws {
        let container = try makeContainer()
        let podcast = Podcast(feedURL: "https://example.com/feed", title: "Show")
        let episode = Episode(guid: "restart-guid", title: "Episode",
                              audioURL: "https://example.com/audio.mp3",
                              durationSeconds: 600, positionSeconds: 0)
        episode.podcast = podcast
        container.mainContext.insert(podcast)
        container.mainContext.insert(episode)
        try container.mainContext.save()
        let oldRecord = ListeningPlaceRecord.episode(
            guid: episode.guid, enclosureURL: episode.audioURL,
            positionSeconds: 60, durationSeconds: 600, played: false,
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        let data = try ListeningPlacesFormat.encodedDeviceFile(
            deviceID: "1234abcd", appVersion: "earshot/test",
            writtenAt: Date(timeIntervalSince1970: 1_000), records: [oldRecord]
        )
        let loader = await ListeningPlacesSnapshotLoader.makeBackground(modelContainer: container)
        let restored = try await loader.restore(data: data)
        let prepared = try await loader.prepare(
            pendingZeroSnapshots: [], includeLabels: false, previousRecords: restored.records,
            previousSignatures: restored.signatures, previousUpdatedAtByID: restored.updatedAtByID,
            deviceID: "1234abcd", appVersion: "earshot/test",
            now: Date(timeIntervalSince1970: 2_000)
        )
        XCTAssertEqual(prepared.records.count, 1)
        XCTAssertEqual(prepared.records[0].positionMilliseconds, 60_000)
        XCTAssertEqual(prepared.records[0].played, false)
        XCTAssertEqual(prepared.records[0].updatedAt, oldRecord.updatedAt)
        XCTAssertNil(prepared.data)
    }

    func testWriteImmediatelyAfterRestartPreservesExistingFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "listening-places-restart-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try makeContainer()
        let podcast = Podcast(feedURL: "https://example.com/feed", title: "Show")
        let episode = Episode(guid: "restart-guid", title: "Episode",
                              audioURL: "https://example.com/audio.mp3",
                              durationSeconds: 600, positionSeconds: 60)
        let neverPlayed = Episode(guid: "never-guid", title: "Never played",
                                  audioURL: "https://example.com/never.mp3")
        episode.podcast = podcast
        neverPlayed.podcast = podcast
        container.mainContext.insert(podcast)
        container.mainContext.insert(episode)
        container.mainContext.insert(neverPlayed)
        try container.mainContext.save()
        let service = ListeningPlacesService()
        service.configure(context: container.mainContext)
        await service.chooseFolder(directory)
        service.releasePersistence()
        episode.positionSeconds = 0
        try container.mainContext.save()

        let restarted = ListeningPlacesService()
        restarted.configure(context: container.mainContext)
        await restarted.writeNow()

        let file = try deviceFile(in: directory)
        let data = try Data(contentsOf: file)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let records = try XCTUnwrap(json["records"] as? [[String: Any]])
        XCTAssertEqual(records.count, 1, "Unrelated never-played episodes must not be exported")
        XCTAssertEqual(records[0]["position_ms"] as? Int, 60_000)
        XCTAssertEqual(records[0]["played"] as? Bool, false)
    }

    private func deviceFile(in directory: URL) throws -> URL {
        let devices = directory.appending(path: "Listening Places/devices", directoryHint: .isDirectory)
        return try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: devices, includingPropertiesForKeys: nil
        ).first { $0.pathExtension == "json" })
    }

    func testUnwritableReplacementDoesNotDisplaceWorkingFolder() async throws {
        let workingDirectory = FileManager.default.temporaryDirectory
            .appending(path: "listening-places-working-\(UUID().uuidString)", directoryHint: .isDirectory)
        let brokenDirectory = FileManager.default.temporaryDirectory
            .appending(path: "listening-places-broken-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: brokenDirectory, withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(
            to: brokenDirectory.appending(path: "Listening Places")
        )
        defer {
            try? FileManager.default.removeItem(at: workingDirectory)
            try? FileManager.default.removeItem(at: brokenDirectory)
        }

        let container = try makeContainer()
        let service = ListeningPlacesService()
        service.configure(context: container.mainContext)
        await service.chooseFolder(workingDirectory)
        let workingName = service.folderName

        await service.chooseFolder(brokenDirectory)

        XCTAssertEqual(service.folderName, workingName)
        guard case .failed = service.status else {
            return XCTFail("The failed replacement should report its error")
        }

        await service.writeNow()
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: workingDirectory.appending(path: "Listening Places/devices").path
        ))
    }

    func testWritingIntoExistingListeningPlacesFolderCreatesDevicesFolder() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "listening-places-existing-\(UUID().uuidString)", directoryHint: .isDirectory)
        let places = directory
            .appending(path: "Listening Places", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: places, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let transport = ListeningPlacesFileTransport()
        let bookmark = try directory.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        try await transport.writeDeviceFile(
            bookmarkData: bookmark,
            deviceID: "1234abcd",
            data: Data("{}".utf8)
        )

        let deviceFile = places
            .appending(path: "devices", directoryHint: .isDirectory)
            .appending(path: "1234abcd.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: deviceFile.path))
    }

    func testReadmeUpdatesOnlyUnmodifiedLegacyText() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "listening-places-readme-\(UUID().uuidString)", directoryHint: .isDirectory)
        let places = directory.appending(path: "Listening Places", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: places, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let readme = places.appending(path: "README.txt")
        let legacy = """
            Listening Places
            ================

            This folder is how your audio apps remember where you got to, across your devices, without an account and without anybody's server.

            Each device writes exactly one file in "devices" and reads the others. Nothing here is audio -- these are only positions, a few hundred kilobytes at most. The ids are hashed, so this folder does not list what you listen to in readable form.

            You can delete this folder at any time. Nothing breaks: every app still knows your place on the device you are using. It just stops being shared.

            Format: listening-places/1
            """
        let bookmark = try directory.bookmarkData(
            options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil
        )
        let transport = ListeningPlacesFileTransport()
        try Data(legacy.utf8).write(to: readme)
        try await transport.prepareFolder(bookmarkData: bookmark)
        let updated = try String(contentsOf: readme, encoding: .utf8)
        XCTAssertTrue(updated.contains("Earshot does not import changes from other devices"))
        XCTAssertTrue(updated.contains("iCloud Sync separately syncs"))
        XCTAssertTrue(updated.contains("unless you enable them"))

        let edited = legacy + "\nMy own notes."
        try Data(edited.utf8).write(to: readme)
        try await transport.prepareFolder(bookmarkData: bookmark)
        XCTAssertEqual(try String(contentsOf: readme, encoding: .utf8), edited)
    }

    private func makeContainer() throws -> ModelContainer {
        let full = Schema(versionedSchema: EarshotSchemaV12.self)
        return try ModelContainer(
            for: full,
            configurations:
                ModelConfiguration(
                    "FutureMirrored",
                    schema: Schema(EarshotSchemaV12.mirroredModels),
                    isStoredInMemoryOnly: true,
                    cloudKitDatabase: .none
                ),
                ModelConfiguration(
                    "DeviceLocal",
                    schema: Schema(EarshotSchemaV12.localModels),
                    isStoredInMemoryOnly: true,
                    cloudKitDatabase: .none
                )
        )
    }
}

private actor SuspendedListeningPlacesWriter {
    private let transport = ListeningPlacesFileTransport()
    private var shouldSuspend = false
    private var suspended = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var resumeContinuation: CheckedContinuation<Void, Never>?
    private var activeWrites = 0
    private var peakWrites = 0

    func suspendNextWrite() { shouldSuspend = true }

    func waitUntilSuspended() async {
        if suspended { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func resumeWrite() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }

    func maximumConcurrentWrites() -> Int { peakWrites }

    func write(bookmark: Data, deviceID: String, data: Data) async throws {
        activeWrites += 1
        peakWrites = max(peakWrites, activeWrites)
        defer { activeWrites -= 1 }
        if shouldSuspend {
            shouldSuspend = false
            suspended = true
            await withCheckedContinuation { continuation in
                resumeContinuation = continuation
                for waiter in waiters { waiter.resume() }
                waiters.removeAll()
            }
        }
        try await transport.writeDeviceFile(bookmarkData: bookmark, deviceID: deviceID, data: data)
    }
}

private actor SuspendedListeningPlacesRemover {
    private let transport = ListeningPlacesFileTransport()
    private var suspended = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    func waitUntilSuspended() async {
        if suspended { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func resumeRemoval() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }

    func remove(bookmark: Data, deviceID: String) async throws {
        suspended = true
        await withCheckedContinuation { continuation in
            resumeContinuation = continuation
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }
        try await transport.removeDeviceFile(bookmarkData: bookmark, deviceID: deviceID)
    }
}

private actor LegacyFailureWriter {
    private let transport = ListeningPlacesFileTransport()
    private var failing = true
    private var hold = false
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?

    func setFailing(_ value: Bool) { failing = value }
    func holdNextWrite() { hold = true }
    func waitUntilHeld() async {
        if isHeld { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func resumeWrite() { continuation?.resume(); continuation = nil }
    func write(bookmark: Data, deviceID: String, data: Data) async throws {
        if hold {
            hold = false
            isHeld = true
            await withCheckedContinuation { value in
                continuation = value
                for waiter in waiters { waiter.resume() }
                waiters.removeAll()
            }
        }
        if failing { throw CocoaError(.fileWriteNoPermission) }
        try await transport.writeDeviceFile(bookmarkData: bookmark, deviceID: deviceID, data: data)
    }
}
