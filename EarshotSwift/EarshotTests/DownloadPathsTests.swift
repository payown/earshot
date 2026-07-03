import XCTest
@testable import Earshot

/// Verifies the pure download-destination naming (#544). Both `DownloadManager`
/// and the off-main `DownloadSessionDelegate` compute the destination this way,
/// so it must be stable for a given (guid, source) pair.
final class DownloadPathsTests: XCTestCase {
    private let dir = URL(fileURLWithPath: "/tmp/downloads", isDirectory: true)

    func testDestinationUsesSourceExtension() throws {
        let url = DownloadPaths.destination(
            inDirectory: dir, guid: "abc", sourceURL: try XCTUnwrap(URL(string: "https://h/x.m4a")))
        XCTAssertEqual(url.pathExtension, "m4a")
        XCTAssertEqual(url.deletingPathExtension().lastPathComponent, "abc")
    }

    func testDestinationDefaultsToMP3WhenSourceHasNoExtension() throws {
        let url = DownloadPaths.destination(
            inDirectory: dir, guid: "abc", sourceURL: try XCTUnwrap(URL(string: "https://h/stream")))
        XCTAssertEqual(url.pathExtension, "mp3")
    }

    func testGUIDIsPercentEncodedForFilesystemSafety() throws {
        let url = DownloadPaths.destination(
            inDirectory: dir, guid: "http://ex.com/ep?id=1",
            sourceURL: try XCTUnwrap(URL(string: "https://h/x.mp3")))
        let name = url.deletingPathExtension().lastPathComponent
        XCTAssertFalse(name.contains("/"), "No path separators survive into the filename")
        XCTAssertFalse(name.contains(":"))
        XCTAssertFalse(name.contains("?"))
    }

    func testSameGUIDAndSourceProduceAStableDestination() throws {
        let src = try XCTUnwrap(URL(string: "https://h/x.mp3"))
        let a = DownloadPaths.destination(inDirectory: dir, guid: "g", sourceURL: src)
        let b = DownloadPaths.destination(inDirectory: dir, guid: "g", sourceURL: src)
        XCTAssertEqual(a, b)
    }
}
