import Foundation

/// Pure parser for ID3v2 chapter metadata (`CHAP` / `CTOC` frames) embedded in
/// MP3 files. AVFoundation's `loadChapterMetadataGroups` only reads MP4/M4A
/// chapter atoms, so the dominant chaptered-podcast format (MP3 produced by
/// Auphonic — e.g. NosillaCast) yielded nothing. This fills that gap.
///
/// Handles ID3v2.3 (plain 32-bit frame sizes) and ID3v2.4 (synchsafe frame
/// sizes), the tag-level unsynchronisation flag, the v2.4 per-frame
/// unsynchronisation and data-length-indicator flags, and `TIT2` titles in
/// ISO-8859-1, UTF-16 (with BOM), UTF-16BE, and UTF-8.
///
/// Defensive by construction: every bounds check bails to whatever was parsed
/// so far (or an empty list). Malformed or truncated input never traps.
///
/// Kept free of I/O so it can be unit-tested against crafted byte fixtures.
enum ID3ChapterParser {

    // MARK: Public

    /// Parses an ID3v2 tag (10-byte header + frame body) into chapters.
    /// Returns an empty list when the bytes aren't an ID3 tag, the version is
    /// unsupported, or no usable `CHAP` frames are found.
    static func parse(_ tag: Data) -> [Chapter] {
        let bytes = [UInt8](tag)
        guard bytes.count >= 10,
              bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 else { return [] } // "ID3"
        let major = bytes[3]
        guard major == 3 || major == 4 else { return [] }

        let headerFlags = bytes[5]
        let unsynchronised = (headerFlags & 0x80) != 0
        let hasExtendedHeader = (headerFlags & 0x40) != 0
        guard let declaredSize = synchsafe(bytes, 6) else { return [] }

        let bodyStart = 10
        let bodyEnd = min(bodyStart + declaredSize, bytes.count)
        guard bodyEnd > bodyStart else { return [] }

        var body = Array(bytes[bodyStart..<bodyEnd])
        // v2.3 applies unsynchronisation to the whole body as a unit. (v2.4
        // prefers per-frame unsync, handled in parseFrames, but honour the tag
        // flag here too if it is set.)
        if unsynchronised { body = deUnsynchronise(body) }

        var cursor = 0
        if hasExtendedHeader {
            cursor = skipExtendedHeader(body, major: major)
            guard cursor <= body.count else { return [] }
        }

        let frames = parseFrames(body, from: cursor, major: major)
        return chapters(from: frames, major: major)
    }

    /// Validates an ID3v2 header and returns the TOTAL tag length in bytes
    /// (10-byte header + frame body + optional footer). Used by the tag fetcher
    /// to size a ranged read. Returns nil when the bytes aren't an ID3 header.
    static func totalTagSize(header: Data) -> Int? {
        let b = [UInt8](header)
        guard b.count >= 10,
              b[0] == 0x49, b[1] == 0x44, b[2] == 0x33 else { return nil }
        let major = b[3]
        guard major == 3 || major == 4 else { return nil }
        guard let size = synchsafe(b, 6) else { return nil }
        let footer = (b[5] & 0x10) != 0 ? 10 : 0
        return 10 + size + footer
    }

    // MARK: Frame walking

    private struct Frame {
        let id: String
        let data: [UInt8]
    }

    /// Walks consecutive frames starting at `start`. Stops at padding (a null
    /// frame ID), an invalid frame ID, or a size that runs past the buffer —
    /// returning whatever was collected so far.
    private static func parseFrames(_ body: [UInt8], from start: Int, major: UInt8) -> [Frame] {
        var frames: [Frame] = []
        var i = start
        while i + 10 <= body.count {
            // Padding after the last frame is zero bytes.
            if body[i] == 0 { break }
            let idBytes = Array(body[i..<i + 4])
            guard isValidFrameID(idBytes), let id = String(bytes: idBytes, encoding: .isoLatin1) else { break }

            let size: Int
            if major == 4 {
                guard let s = synchsafe(body, i + 4) else { break }
                size = s
            } else {
                size = Int(body[i + 4]) << 24 | Int(body[i + 5]) << 16
                     | Int(body[i + 6]) << 8 | Int(body[i + 7])
            }
            let formatFlags = body[i + 9]
            let dataStart = i + 10
            guard size >= 0, dataStart + size <= body.count else { break }

            var frameData = Array(body[dataStart..<dataStart + size])
            // v2.4 per-frame unsynchronisation (format flag 0x02), applied
            // before stripping the optional data-length indicator (0x01).
            if major == 4 {
                if formatFlags & 0x02 != 0 { frameData = deUnsynchronise(frameData) }
                if formatFlags & 0x01 != 0, frameData.count >= 4 { frameData = Array(frameData[4...]) }
            }
            frames.append(Frame(id: id, data: frameData))
            i = dataStart + size
        }
        return frames
    }

    // MARK: Chapter assembly

    private struct ParsedChapter {
        let elementID: String
        let startMillis: UInt32
        let title: String?
    }

    private static func chapters(from frames: [Frame], major: UInt8) -> [Chapter] {
        var parsed: [ParsedChapter] = []
        for frame in frames where frame.id == "CHAP" {
            if let chap = parseCHAP(frame.data, major: major) { parsed.append(chap) }
        }
        guard !parsed.isEmpty else { return [] }

        // Order by the table-of-contents child list when present (the author's
        // intended order), else by start time. Pick the CTOC with the most
        // children — the top-level one in nested tables of contents.
        let tocOrder = frames
            .filter { $0.id == "CTOC" }
            .compactMap { parseCTOC($0.data) }
            .max(by: { $0.count < $1.count })

        let ordered: [ParsedChapter]
        if let tocOrder, !tocOrder.isEmpty {
            var position: [String: Int] = [:]
            for (idx, child) in tocOrder.enumerated() where position[child] == nil {
                position[child] = idx
            }
            ordered = parsed.sorted { a, b in
                let pa = position[a.elementID] ?? Int.max
                let pb = position[b.elementID] ?? Int.max
                if pa != pb { return pa < pb }
                return a.startMillis < b.startMillis
            }
        } else {
            ordered = parsed.sorted { $0.startMillis < $1.startMillis }
        }

        return ordered.enumerated().map { i, chap in
            let title = chap.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Chapter \(i + 1)"
            return Chapter(index: i, startTime: Double(chap.startMillis) / 1000.0, title: title)
        }
    }

    /// CHAP frame body: element-ID (null-terminated) + start/end ms + start/end
    /// byte offsets (4 × 32-bit) + embedded sub-frames (e.g. `TIT2`).
    private static func parseCHAP(_ data: [UInt8], major: UInt8) -> ParsedChapter? {
        guard let (elementID, afterID) = readLatin1Terminated(data, from: 0) else { return nil }
        guard afterID + 16 <= data.count else { return nil }
        let startMillis = bigEndian32(data, afterID)
        let subStart = afterID + 16
        let subFrames = subStart < data.count
            ? parseFrames(Array(data[subStart...]), from: 0, major: major)
            : []
        let title = subFrames.first { $0.id == "TIT2" }.map { decodeText($0.data) }
        return ParsedChapter(elementID: elementID, startMillis: startMillis, title: title)
    }

    /// CTOC frame body: element-ID (null-terminated) + flags + entry count +
    /// that many null-terminated child element IDs. Returns the child IDs in
    /// order; ignores any trailing sub-frames.
    private static func parseCTOC(_ data: [UInt8]) -> [String]? {
        guard let (_, afterID) = readLatin1Terminated(data, from: 0) else { return nil }
        guard afterID + 2 <= data.count else { return nil }
        let entryCount = Int(data[afterID + 1])
        var cursor = afterID + 2
        var children: [String] = []
        for _ in 0..<entryCount {
            guard let (child, next) = readLatin1Terminated(data, from: cursor) else { break }
            children.append(child)
            cursor = next
        }
        return children
    }

    // MARK: Byte helpers

    /// Reads a 4-byte synchsafe integer (7 bits per byte) at `offset`.
    private static func synchsafe(_ b: [UInt8], _ offset: Int) -> Int? {
        guard offset >= 0, offset + 4 <= b.count else { return nil }
        return Int(b[offset] & 0x7F) << 21
             | Int(b[offset + 1] & 0x7F) << 14
             | Int(b[offset + 2] & 0x7F) << 7
             | Int(b[offset + 3] & 0x7F)
    }

    private static func bigEndian32(_ b: [UInt8], _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= b.count else { return 0 }
        return UInt32(b[offset]) << 24 | UInt32(b[offset + 1]) << 16
             | UInt32(b[offset + 2]) << 8 | UInt32(b[offset + 3])
    }

    private static func isValidFrameID(_ id: [UInt8]) -> Bool {
        guard id.count == 4 else { return false }
        return id.allSatisfy { (0x41...0x5A).contains($0) || (0x30...0x39).contains($0) }
    }

    /// Reverses unsynchronisation: every `0xFF 0x00` pair becomes a single
    /// `0xFF` (the inserted null is stripped).
    private static func deUnsynchronise(_ b: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(b.count)
        var i = 0
        while i < b.count {
            out.append(b[i])
            if b[i] == 0xFF, i + 1 < b.count, b[i + 1] == 0x00 {
                i += 2
            } else {
                i += 1
            }
        }
        return out
    }

    /// Reads a null-terminated ISO-8859-1 string from `data` starting at
    /// `from`. Returns the string and the index just past the terminator.
    private static func readLatin1Terminated(_ data: [UInt8], from start: Int) -> (String, Int)? {
        guard start >= 0, start <= data.count else { return nil }
        var i = start
        while i < data.count, data[i] != 0 { i += 1 }
        let value = String(bytes: data[start..<i], encoding: .isoLatin1) ?? ""
        let next = i < data.count ? i + 1 : i // skip the terminator when present
        return (value, next)
    }

    /// Decodes an ID3 text frame body: a 1-byte encoding marker followed by the
    /// text. Trailing null terminators are trimmed.
    private static func decodeText(_ data: [UInt8]) -> String {
        guard let encoding = data.first else { return "" }
        let payload = Array(data.dropFirst())
        let decoded: String
        switch encoding {
        case 0:
            decoded = String(bytes: payload, encoding: .isoLatin1) ?? ""
        case 1:
            decoded = String(bytes: payload, encoding: .utf16) ?? ""
        case 2:
            decoded = String(bytes: payload, encoding: .utf16BigEndian) ?? ""
        case 3:
            decoded = String(bytes: payload, encoding: .utf8) ?? ""
        default:
            decoded = String(bytes: payload, encoding: .utf8)
                ?? String(bytes: payload, encoding: .isoLatin1) ?? ""
        }
        return decoded.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
    }

    /// Skips the optional extended header, returning the offset of the first
    /// real frame. Sizing differs between v2.3 and v2.4; bails to a safe offset
    /// on any inconsistency.
    private static func skipExtendedHeader(_ body: [UInt8], major: UInt8) -> Int {
        if major == 4 {
            // v2.4: the size is synchsafe and INCLUDES the 4 size bytes.
            guard let size = synchsafe(body, 0), size >= 4 else { return body.count }
            return size
        } else {
            // v2.3: a plain 32-bit size of the bytes AFTER the size field.
            guard body.count >= 4 else { return body.count }
            let size = Int(body[0]) << 24 | Int(body[1]) << 16 | Int(body[2]) << 8 | Int(body[3])
            return 4 + size
        }
    }
}
