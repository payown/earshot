import XCTest
@testable import Earshot

/// Tests the ID3 tag prefix reader (#522). The remote path exercises the chunked
/// `[UInt8]` accumulation in `prefix(of:upTo:)` end to end through
/// ``MockURLProtocol`` (no real network), and the cap test proves a server that
/// returns more than the declared tag size is stopped at the cap rather than
/// pulling the whole episode. The local path covers the on-disk reader.
final class ID3TagFetcherTests: XCTestCase {

    private var session: URLSession!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        session = MockURLProtocol.makeSession()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        session = nil
        super.tearDown()
    }

    // MARK: Fixture

    /// A 4-byte synchsafe integer (7 bits per byte), the ID3v2 size encoding.
    private func synchsafe(_ value: Int) -> [UInt8] {
        [
            UInt8((value >> 21) & 0x7F),
            UInt8((value >> 14) & 0x7F),
            UInt8((value >> 7) & 0x7F),
            UInt8(value & 0x7F)
        ]
    }

    private func plain32(_ value: Int) -> [UInt8] {
        [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ]
    }

    private func be32(_ value: UInt32) -> [UInt8] {
        [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ]
    }

    /// A minimal ID3v2.3 tag with one CHAP frame carrying a TIT2 title, so the
    /// returned bytes can be round-tripped through ``ID3ChapterParser``.
    private func makeTag(title: String = "Intro") -> Data {
        // TIT2 sub-frame (ISO-8859-1 encoding byte 0x00).
        var tit2Payload: [UInt8] = [0x00]
        tit2Payload += Array(title.utf8) // ASCII => identical bytes
        var tit2: [UInt8] = Array("TIT2".utf8)
        tit2 += plain32(tit2Payload.count)
        tit2 += [0, 0]
        tit2 += tit2Payload

        // CHAP frame data.
        var chapData: [UInt8] = Array("chp0".utf8)
        chapData.append(0)               // element ID terminator
        chapData += be32(0)              // start ms
        chapData += be32(1000)           // end ms
        chapData += [0xFF, 0xFF, 0xFF, 0xFF] // start offset unused
        chapData += [0xFF, 0xFF, 0xFF, 0xFF] // end offset unused
        chapData += tit2

        var chap: [UInt8] = Array("CHAP".utf8)
        chap += plain32(chapData.count)
        chap += [0, 0]
        chap += chapData

        var out: [UInt8] = [0x49, 0x44, 0x33, 3, 0, 0] // "ID3", v2.3, flags 0
        out += synchsafe(chap.count)
        out += chap
        return Data(out)
    }

    // MARK: Remote

    // Happy path: a valid ID3 tag is fetched via the two ranged reads and the
    // chunked accumulation returns the exact tag bytes, which parse to a chapter.
    func testRemoteValidTagReturnsBytesAndParses() async throws {
        let tag = makeTag(title: "Intro")
        // One outcome per ranged request (header read, then full-tag read).
        MockURLProtocol.setOutcomes([
            .response(statusCode: 206, data: tag),
            .response(statusCode: 206, data: tag)
        ])

        let fetcher = ID3TagFetcher(session: session)
        let result = await fetcher.tagData(remote: "https://example.com/episode.mp3")

        XCTAssertEqual(result, tag)
        let chapters = ID3ChapterParser.parse(try XCTUnwrap(result))
        XCTAssertEqual(chapters.first?.title, "Intro")
    }

    // The core of the chunked change: a server that ignores Range and returns the
    // whole body (tag + trailing "audio") must be stopped at the declared tag
    // size, not read to the end.
    func testRemoteBodyLargerThanTagIsCappedAtTagSize() async {
        let tag = makeTag()
        var oversized = [UInt8](tag)
        oversized += [UInt8](repeating: 0x55, count: 50_000) // fake audio frames
        let body = Data(oversized)

        MockURLProtocol.setOutcomes([
            .response(statusCode: 200, data: body),
            .response(statusCode: 200, data: body)
        ])

        let fetcher = ID3TagFetcher(session: session)
        let result = await fetcher.tagData(remote: "https://example.com/episode.mp3")

        // Exactly the tag — the trailing 50 KB of "audio" was never returned.
        XCTAssertEqual(result?.count, tag.count)
        XCTAssertEqual(result, tag)
    }

    // A prefix that is not an ID3 header yields nil (header validation fails on
    // the first read, so no second read is needed).
    func testRemoteNonID3PrefixReturnsNil() async {
        let junk = Data(repeating: 0x00, count: 64)
        MockURLProtocol.setOutcomes([.response(statusCode: 200, data: junk)])

        let fetcher = ID3TagFetcher(session: session)
        let result = await fetcher.tagData(remote: "https://example.com/notmp3")

        XCTAssertNil(result)
    }

    // A non-HTTP URL is rejected before any network call.
    func testRemoteInvalidURLReturnsNil() async {
        let fetcher = ID3TagFetcher(session: session)
        let result = await fetcher.tagData(remote: "not a url")
        XCTAssertNil(result)
        XCTAssertTrue(MockURLProtocol.requestedURLs.isEmpty)
    }

    // A truncated body (fewer than 10 header bytes) cannot be validated -> nil.
    func testRemoteShortBodyReturnsNil() async {
        MockURLProtocol.setOutcomes([.response(statusCode: 200, data: Data([0x49, 0x44, 0x33]))])
        let fetcher = ID3TagFetcher(session: session)
        let result = await fetcher.tagData(remote: "https://example.com/short.mp3")
        XCTAssertNil(result)
    }

    // MARK: Local

    // The on-disk reader returns exactly the tag region from a file that has the
    // tag followed by trailing audio bytes.
    func testLocalValidTagFileReturnsTagRegion() throws {
        let tag = makeTag(title: "Local")
        var fileBytes = [UInt8](tag)
        fileBytes += [UInt8](repeating: 0x55, count: 20_000)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("id3fetcher-\(UUID().uuidString).mp3")
        try Data(fileBytes).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let fetcher = ID3TagFetcher(session: session)
        let result = fetcher.tagData(localPath: url.path)

        XCTAssertEqual(result?.count, tag.count)
        XCTAssertEqual(result, tag)
    }

    // A missing file returns nil rather than trapping.
    func testLocalMissingFileReturnsNil() {
        let fetcher = ID3TagFetcher(session: session)
        let result = fetcher.tagData(localPath: "/nonexistent/path/missing.mp3")
        XCTAssertNil(result)
    }

    // A file that doesn't start with an ID3 tag (e.g. an M4A) returns nil so the
    // AVAsset path can handle it instead.
    func testLocalNonID3FileReturnsNil() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonid3-\(UUID().uuidString).m4a")
        try Data(repeating: 0x00, count: 256).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let fetcher = ID3TagFetcher(session: session)
        XCTAssertNil(fetcher.tagData(localPath: url.path))
    }
}
