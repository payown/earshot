import XCTest
@testable import Earshot

/// Byte-level tests for ``ID3ChapterParser`` against crafted ID3v2.3 and v2.4
/// fixtures. All fixtures are built in-process — no network — so the parser is
/// exercised deterministically and offline.
final class ID3ChapterParserTests: XCTestCase {

    // MARK: ID3v2.3

    func testParsesMultipleV23ChaptersWithTitles() {
        let frames = [
            ID3Fixture.chap(id: "chp0", startMs: 0, title: "Intro", major: 3),
            ID3Fixture.chap(id: "chp1", startMs: 60_000, title: "Main Topic", major: 3),
            ID3Fixture.chap(id: "chp2", startMs: 125_500, title: "Wrap Up", major: 3)
        ]
        let tag = ID3Fixture.tag(major: 3, frames: frames)

        let chapters = ID3ChapterParser.parse(tag)

        XCTAssertEqual(chapters.map(\.title), ["Intro", "Main Topic", "Wrap Up"])
        XCTAssertEqual(chapters.map(\.startTime), [0, 60, 125.5])
        XCTAssertEqual(chapters.map(\.index), [0, 1, 2])
    }

    // MARK: ID3v2.4 (synchsafe frame sizes)

    func testParsesV24ChaptersWithSynchsafeFrameSizes() {
        // A title long enough that its frame size exceeds 127 bytes, so v2.4's
        // synchsafe encoding genuinely differs from a plain byte. Parsing it as
        // a plain size would land on the wrong offset and fail.
        let longTitle = String(repeating: "A", count: 200)
        let frames = [
            ID3Fixture.chap(id: "c0", startMs: 0, title: longTitle, major: 4),
            ID3Fixture.chap(id: "c1", startMs: 30_000, title: "Second", major: 4)
        ]
        let tag = ID3Fixture.tag(major: 4, frames: frames)

        let chapters = ID3ChapterParser.parse(tag)

        XCTAssertEqual(chapters.count, 2)
        XCTAssertEqual(chapters[0].title, longTitle)
        XCTAssertEqual(chapters[1].title, "Second")
        XCTAssertEqual(chapters[1].startTime, 30)
    }

    // MARK: CTOC ordering

    func testCTOCChildOrderOverridesStartTimeOrder() {
        // File order and CTOC order both say a, b, c — but their start times are
        // out of order (30s, 10s, 20s). Start-time sorting would give b, c, a;
        // the CTOC list must win.
        let frames: [[UInt8]] = [
            ID3Fixture.chap(id: "a", startMs: 30_000, title: "Alpha", major: 3),
            ID3Fixture.chap(id: "b", startMs: 10_000, title: "Bravo", major: 3),
            ID3Fixture.chap(id: "c", startMs: 20_000, title: "Charlie", major: 3),
            ID3Fixture.ctoc(id: "toc", children: ["a", "b", "c"], major: 3)
        ]
        let tag = ID3Fixture.tag(major: 3, frames: frames)

        let chapters = ID3ChapterParser.parse(tag)

        XCTAssertEqual(chapters.map(\.title), ["Alpha", "Bravo", "Charlie"])
    }

    func testFallsBackToStartTimeOrderWithoutCTOC() {
        let frames = [
            ID3Fixture.chap(id: "a", startMs: 30_000, title: "Alpha", major: 3),
            ID3Fixture.chap(id: "b", startMs: 10_000, title: "Bravo", major: 3),
            ID3Fixture.chap(id: "c", startMs: 20_000, title: "Charlie", major: 3)
        ]
        let tag = ID3Fixture.tag(major: 3, frames: frames)

        let chapters = ID3ChapterParser.parse(tag)

        XCTAssertEqual(chapters.map(\.title), ["Bravo", "Charlie", "Alpha"])
        XCTAssertEqual(chapters.map(\.startTime), [10, 20, 30])
    }

    // MARK: Text encodings

    func testDecodesTitleEncodings() {
        let cases: [(UInt8, String)] = [
            (0, "Latin1 Cafe"),   // ISO-8859-1
            (1, "UTF16 Café"),    // UTF-16 with BOM
            (3, "UTF8 Café ☕")    // UTF-8
        ]
        for (encoding, title) in cases {
            let frame = ID3Fixture.chap(id: "c", startMs: 0, title: title, encoding: encoding, major: 3)
            let tag = ID3Fixture.tag(major: 3, frames: [frame])
            let chapters = ID3ChapterParser.parse(tag)
            XCTAssertEqual(chapters.first?.title, title, "encoding \(encoding)")
        }
    }

    // MARK: Defaults

    func testChapterWithoutTitleGetsDefault() {
        let frame = ID3Fixture.chap(id: "c0", startMs: 5_000, title: nil, major: 3)
        let tag = ID3Fixture.tag(major: 3, frames: [frame])

        let chapters = ID3ChapterParser.parse(tag)

        XCTAssertEqual(chapters.first?.title, "Chapter 1")
        XCTAssertEqual(chapters.first?.startTime, 5)
    }

    // MARK: Unsynchronisation

    func testParsesTagLevelUnsynchronisedBody() {
        // CHAP end-offset fields are 0xFFFFFFFF, so unsynchronising the whole
        // body inserts 0x00 after every 0xFF. The parser must reverse this
        // before reading frames.
        let frames = [
            ID3Fixture.chap(id: "c0", startMs: 0, title: "One", major: 3),
            ID3Fixture.chap(id: "c1", startMs: 12_000, title: "Two", major: 3)
        ]
        let tag = ID3Fixture.tag(major: 3, frames: frames, unsynchronised: true)

        let chapters = ID3ChapterParser.parse(tag)

        XCTAssertEqual(chapters.map(\.title), ["One", "Two"])
        XCTAssertEqual(chapters.map(\.startTime), [0, 12])
    }

    // MARK: Malformed / truncated input

    func testNonID3DataReturnsEmpty() {
        XCTAssertTrue(ID3ChapterParser.parse(Data([0x00, 0x01, 0x02, 0x03])).isEmpty)
        XCTAssertTrue(ID3ChapterParser.parse(Data("not a tag at all".utf8)).isEmpty)
        XCTAssertTrue(ID3ChapterParser.parse(Data()).isEmpty)
    }

    func testUnsupportedVersionReturnsEmpty() {
        // ID3v2.2 (major 2) uses 3-char frame IDs and isn't supported.
        var bytes: [UInt8] = [0x49, 0x44, 0x33, 2, 0, 0]
        bytes += ID3Fixture.synchsafe(10)
        XCTAssertTrue(ID3ChapterParser.parse(Data(bytes)).isEmpty)
    }

    func testTruncatedTagDoesNotCrashAndReturnsParsablePrefix() {
        let frames = [
            ID3Fixture.chap(id: "c0", startMs: 0, title: "Intro", major: 3),
            ID3Fixture.chap(id: "c1", startMs: 60_000, title: "Topic", major: 3)
        ]
        let full = ID3Fixture.tag(major: 3, frames: frames)
        // Lop off the back half mid-frame. Must not crash; returns at most what
        // parsed cleanly before the cut.
        let truncated = full.prefix(full.count / 2)

        let chapters = ID3ChapterParser.parse(Data(truncated))

        XCTAssertLessThanOrEqual(chapters.count, 2)
        if let first = chapters.first { XCTAssertEqual(first.title, "Intro") }
    }

    func testGarbageFrameSizesBailToEmpty() {
        // Valid header but a frame whose size points past the buffer.
        var body: [UInt8] = Array("CHAP".utf8)
        body += [0x7F, 0xFF, 0xFF, 0xFF] // absurd size
        body += [0, 0]                   // frame flags
        body += [0x00]                   // partial data
        var tag: [UInt8] = [0x49, 0x44, 0x33, 3, 0, 0]
        tag += ID3Fixture.synchsafe(body.count)
        tag += body

        XCTAssertTrue(ID3ChapterParser.parse(Data(tag)).isEmpty)
    }

    // MARK: totalTagSize

    func testTotalTagSizeReadsSynchsafeHeader() {
        var header: [UInt8] = [0x49, 0x44, 0x33, 4, 0, 0]
        header += ID3Fixture.synchsafe(1234)
        XCTAssertEqual(ID3ChapterParser.totalTagSize(header: Data(header)), 10 + 1234)
    }

    func testTotalTagSizeAddsFooterLength() {
        var header: [UInt8] = [0x49, 0x44, 0x33, 4, 0, 0x10] // footer-present flag
        header += ID3Fixture.synchsafe(500)
        XCTAssertEqual(ID3ChapterParser.totalTagSize(header: Data(header)), 10 + 500 + 10)
    }

    func testTotalTagSizeRejectsNonID3() {
        XCTAssertNil(ID3ChapterParser.totalTagSize(header: Data(repeating: 0, count: 10)))
    }
}

// MARK: - Fixture builder

/// Builds ID3v2 byte fixtures for tests. Mirrors the real tag layout so the
/// parser is exercised exactly as it would be against a downloaded MP3.
private enum ID3Fixture {

    /// A 4-byte synchsafe integer (7 bits per byte).
    static func synchsafe(_ value: Int) -> [UInt8] {
        [
            UInt8((value >> 21) & 0x7F),
            UInt8((value >> 14) & 0x7F),
            UInt8((value >> 7) & 0x7F),
            UInt8(value & 0x7F)
        ]
    }

    private static func plain32(_ value: Int) -> [UInt8] {
        [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ]
    }

    private static func bigEndian32(_ value: UInt32) -> [UInt8] {
        [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ]
    }

    /// One frame: 4-char ID, size (synchsafe for v2.4, plain for v2.3), 2 flag
    /// bytes, then data.
    static func frame(id: String, data: [UInt8], major: UInt8) -> [UInt8] {
        var out = Array(id.utf8)
        out += major == 4 ? synchsafe(data.count) : plain32(data.count)
        out += [0, 0] // flags
        out += data
        return out
    }

    /// A `TIT2` text frame: encoding byte + encoded text.
    private static func tit2(_ text: String, encoding: UInt8, major: UInt8) -> [UInt8] {
        var payload: [UInt8] = [encoding]
        switch encoding {
        case 0: // ISO-8859-1
            payload += text.unicodeScalars.map { UInt8($0.value & 0xFF) }
        case 1: // UTF-16 with little-endian BOM
            payload += [0xFF, 0xFE]
            for unit in text.utf16 {
                payload += [UInt8(unit & 0xFF), UInt8(unit >> 8)]
            }
        default: // UTF-8
            payload += Array(text.utf8)
        }
        return frame(id: "TIT2", data: payload, major: major)
    }

    /// A `CHAP` frame: element ID + start/end ms + start/end byte offsets
    /// (0xFFFFFFFF = unused) + optional embedded `TIT2` title.
    static func chap(id: String, startMs: UInt32, title: String?, encoding: UInt8 = 3, major: UInt8) -> [UInt8] {
        var data = Array(id.utf8)
        data.append(0) // element ID terminator
        data += bigEndian32(startMs)
        data += bigEndian32(startMs + 1)        // end time (arbitrary)
        data += [0xFF, 0xFF, 0xFF, 0xFF]        // start offset (unused)
        data += [0xFF, 0xFF, 0xFF, 0xFF]        // end offset (unused)
        if let title { data += tit2(title, encoding: encoding, major: major) }
        return frame(id: "CHAP", data: data, major: major)
    }

    /// A `CTOC` frame: element ID + flags + child count + child element IDs.
    static func ctoc(id: String, children: [String], major: UInt8) -> [UInt8] {
        var data = Array(id.utf8)
        data.append(0) // element ID terminator
        data.append(0x03) // flags: top-level + ordered
        data.append(UInt8(children.count))
        for child in children {
            data += Array(child.utf8)
            data.append(0)
        }
        return frame(id: "CTOC", data: data, major: major)
    }

    /// Assembles a full tag: "ID3" header + flags + synchsafe body size + body.
    /// When `unsynchronised` is set, the body is unsynchronised (0xFF -> 0xFF 0x00)
    /// and the header flag is set, matching how an encoder would emit it.
    static func tag(major: UInt8, frames: [[UInt8]], unsynchronised: Bool = false) -> Data {
        var body: [UInt8] = frames.flatMap { $0 }
        var flags: UInt8 = 0
        if unsynchronised {
            body = unsynchronise(body)
            flags |= 0x80
        }
        var out: [UInt8] = [0x49, 0x44, 0x33, major, 0, flags]
        out += synchsafe(body.count)
        out += body
        return Data(out)
    }

    /// Inserts a 0x00 after every 0xFF (the encoder side of unsynchronisation).
    private static func unsynchronise(_ b: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        for byte in b {
            out.append(byte)
            if byte == 0xFF { out.append(0x00) }
        }
        return out
    }
}
