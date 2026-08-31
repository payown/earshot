import SwiftData
import XCTest
@testable import Earshot

@MainActor
final class ListeningPlacesServiceTests: XCTestCase {
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
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appending(path: "Listening Places/README.txt").path
        ))

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
