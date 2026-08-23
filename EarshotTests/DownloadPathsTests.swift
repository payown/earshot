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

    func testPrepareDownloadsDirectoryExcludesRedownloadableAudioFromBackup() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let downloads = parent.appendingPathComponent("Downloads", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        try DownloadPaths.prepareDownloadsDirectory(at: downloads)
        let first = try downloads.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(first.isExcludedFromBackup, true)

        // Existing directories from earlier builds are repaired idempotently.
        try DownloadPaths.prepareDownloadsDirectory(at: downloads)
        let second = try downloads.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(second.isExcludedFromBackup, true)
    }

    // MARK: storedFileName (#575)

    // Acceptance criterion: stored values are bare file names, legacy absolute
    // paths degrade to their last path component.

    func test_storedFileName_nil_returnsNil() {
        XCTAssertNil(DownloadPaths.storedFileName(nil))
    }

    func test_storedFileName_empty_returnsNil() {
        XCTAssertNil(DownloadPaths.storedFileName(""))
    }

    func test_storedFileName_bareName_passesThrough() {
        XCTAssertEqual(DownloadPaths.storedFileName("abc123.mp3"), "abc123.mp3")
    }

    func test_storedFileName_legacyAbsolutePath_returnsLastPathComponent() {
        let legacy = "/var/mobile/Containers/Data/Application/OLD-UUID/Documents/Downloads/guid42.mp3"
        XCTAssertEqual(DownloadPaths.storedFileName(legacy), "guid42.mp3")
    }

    func test_storedFileName_weirdValues_doNotCrash() {
        // "/" — NSString.lastPathComponent of "/" is "/" itself; the contract
        // here is only "no crash, no empty-string escape".
        _ = DownloadPaths.storedFileName("/")
        // Trailing slash: lastPathComponent strips it.
        XCTAssertEqual(DownloadPaths.storedFileName("/a/b/name.mp3/"), "name.mp3")
        // Whatever comes back is never the empty string.
        for weird in ["/", "//", "///", " ", "."] {
            if let name = DownloadPaths.storedFileName(weird) {
                XCTAssertFalse(name.isEmpty, "storedFileName(\(weird)) returned an empty name")
            }
        }
    }

    // MARK: resolveLocalURL (#575)

    // Acceptance criterion: reads always resolve against the CURRENT container's
    // Downloads directory, never the directory embedded in a legacy value.

    func test_resolveLocalURL_nil_returnsNil() {
        XCTAssertNil(DownloadPaths.resolveLocalURL(storedValue: nil))
        XCTAssertNil(DownloadPaths.resolveLocalURL(storedValue: ""))
    }

    func test_resolveLocalURL_bareName_resolvesInsideDownloadsDirectory() throws {
        let downloads = try DownloadPaths.downloadsDirectory()
        let resolved = try XCTUnwrap(DownloadPaths.resolveLocalURL(storedValue: "guid7.mp3"))
        XCTAssertEqual(resolved.lastPathComponent, "guid7.mp3")
        XCTAssertEqual(resolved.deletingLastPathComponent().standardizedFileURL.path,
                       downloads.standardizedFileURL.path)
    }

    func test_resolveLocalURL_legacyAbsolutePath_resolvesToCurrentDownloadsDirectoryNotStoredDir() throws {
        let downloads = try DownloadPaths.downloadsDirectory()
        let legacy = "/var/mobile/Containers/Data/Application/DEAD-UUID/Documents/Downloads/guid9.m4a"
        let resolved = try XCTUnwrap(DownloadPaths.resolveLocalURL(storedValue: legacy))
        XCTAssertEqual(resolved.lastPathComponent, "guid9.m4a")
        XCTAssertEqual(resolved.deletingLastPathComponent().standardizedFileURL.path,
                       downloads.standardizedFileURL.path)
        XCTAssertFalse(resolved.path.contains("DEAD-UUID"),
                       "Resolution must ignore the stale container path embedded in the legacy value")
    }
}
