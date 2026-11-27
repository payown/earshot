import Foundation
import XCTest
@testable import Earshot

@MainActor
final class ListeningPlacesFileTransportTests: XCTestCase {
    func testOtherDeviceReadIsNonCreatingBoundedAndIndependentPerFile() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bookmark = try folder.bookmarkData(options: .minimalBookmark,
                                               includingResourceValuesForKeys: nil, relativeTo: nil)
        let transport = ListeningPlacesFileTransport()

        let absent = try await transport.readOtherDeviceFiles(bookmarkData: bookmark,
                                                              excludingDeviceID: "phone123")
        XCTAssertTrue(absent.files.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appending(path: "Listening Places").path),
                       "A read must not create the writer's layout or README")

        let devices = folder.appending(path: "Listening Places/devices")
        try FileManager.default.createDirectory(at: devices, withIntermediateDirectories: true)
        let own = devices.appending(path: "phone123.json")
        let desktop = devices.appending(path: "studio-pc.json")
        let laptop = devices.appending(path: "laptop_2.json")
        let oversized = devices.appending(path: "oversized.json")
        let invalid = devices.appending(path: "bad name.json")
        let directory = devices.appending(path: "directory.json")
        let symlink = devices.appending(path: "link.json")
        let ownBytes = Data("own".utf8)
        let desktopBytes = Data("desktop".utf8)
        let laptopBytes = Data("laptop".utf8)
        try ownBytes.write(to: own)
        try desktopBytes.write(to: desktop)
        try laptopBytes.write(to: laptop)
        try Data(repeating: 0x78, count: 2 * 1_024 * 1_024 + 1).write(to: oversized)
        try Data("invalid".utf8).write(to: invalid)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: desktop)

        let result = try await transport.readOtherDeviceFiles(bookmarkData: bookmark,
                                                              excludingDeviceID: "phone123")
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: result.files.map { ($0.fileName, $0.data) }),
                       ["studio-pc.json": desktopBytes, "laptop_2.json": laptopBytes])
        XCTAssertTrue(result.skipped.contains { $0.fileName == "oversized.json" && $0.reason == .tooLarge })
        XCTAssertTrue(result.skipped.contains { $0.fileName == "directory.json" && $0.reason == .notRegularFile })
        XCTAssertTrue(result.skipped.contains { $0.fileName == "link.json" && $0.reason == .notRegularFile })
        XCTAssertTrue(result.skipped.contains { $0.fileName == nil && $0.reason == .invalidName })
        XCTAssertFalse(result.files.contains { $0.fileName == "phone123.json" })
        XCTAssertEqual(try Data(contentsOf: own), ownBytes)
        XCTAssertEqual(try Data(contentsOf: desktop), desktopBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appending(path: "Listening Places/README.txt").path))
    }

    func testOtherDeviceReadCapsAggregateBytesAndFileCount() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let devices = folder.appending(path: "Listening Places/devices")
        try FileManager.default.createDirectory(at: devices, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bookmark = try folder.bookmarkData(options: .minimalBookmark,
                                               includingResourceValuesForKeys: nil, relativeTo: nil)
        let payload = Data(repeating: 0x41, count: 2 * 1_024 * 1_024)
        for index in 0 ..< 9 {
            try payload.write(to: devices.appending(path: String(format: "device%03d.json", index)))
        }
        let transport = ListeningPlacesFileTransport()
        let bytes = try await transport.readOtherDeviceFiles(bookmarkData: bookmark,
                                                             excludingDeviceID: "phone123")
        XCTAssertEqual(bytes.files.count, 8)
        XCTAssertEqual(bytes.files.reduce(0) { $0 + $1.data.count }, 16 * 1_024 * 1_024)
        XCTAssertTrue(bytes.skipped.contains { $0.fileName == "device008.json" && $0.reason == .totalBudget })

        for index in 0 ..< 65 {
            try Data([0x42]).write(to: devices.appending(path: String(format: "tiny%03d.json", index)))
        }
        let many = try await transport.readOtherDeviceFiles(bookmarkData: bookmark,
                                                            excludingDeviceID: "phone123")
        XCTAssertEqual(many.files.count, 8,
                       "The aggregate byte cap still bounds retained bytes before the file cap")
        XCTAssertTrue(many.skipped.contains { $0.reason == .fileLimit })
    }

    func testOtherDeviceReadDoesNotFollowAReplacedSharedDirectorySymlink() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let outside = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside.appending(path: "devices"),
                                                withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try Data("outside".utf8).write(to: outside.appending(path: "devices/peer.json"))
        try FileManager.default.createSymbolicLink(at: root.appending(path: "Listening Places"),
                                                  withDestinationURL: outside)
        let bookmark = try root.bookmarkData(options: .minimalBookmark,
                                             includingResourceValuesForKeys: nil, relativeTo: nil)
        let transport = ListeningPlacesFileTransport()
        do {
            _ = try await transport.readOtherDeviceFiles(bookmarkData: bookmark,
                                                         excludingDeviceID: "phone123")
            XCTFail("A replaced shared-folder symlink must not be followed")
        } catch ListeningPlacesFileError.expectedDirectory(_) {
            XCTAssertEqual(try Data(contentsOf: outside.appending(path: "devices/peer.json")),
                           Data("outside".utf8))
        }
    }
}
