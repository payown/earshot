import Foundation

/// Reads just the ID3v2 tag bytes from an audio file so ``ID3ChapterParser`` can
/// extract embedded chapters without downloading the whole episode.
///
/// The ID3v2 tag sits at the very start of an MP3, so a streaming/range-limited
/// read of the file prefix is enough. Two sources are supported:
///
/// - **Local file** (downloaded episode): read the header from disk, size the
///   tag, then read exactly the tag region.
/// - **Remote URL** (streaming — the common case): issue an HTTP `Range` request
///   for the first 10 bytes, validate the `ID3` magic and synchsafe size, then
///   range-request exactly the tag. Redirects (blubrry → libsyn) are followed by
///   URLSession automatically. If the server ignores `Range` and returns `200`,
///   the streaming reader stops once the cap is reached, so the whole file is
///   never pulled.
///
/// Time-boxing comes from the shared ``EarshotURLSession`` request/resource
/// timeouts. The reader caps every prefix at ``maxPrefixBytes`` so a server that
/// reports an absurd tag size (or ignores `Range`) can't trigger a large read.
///
/// Concurrency: holds only an immutable `URLSession` (thread-safe), so it is
/// `Sendable` and safe to call from a detached task off the main actor.
struct ID3TagFetcher: Sendable {
    private let session: URLSession

    /// Hard ceiling on how many prefix bytes are ever read, whether or not the
    /// server honours `Range`. ID3 tags are at the file start and rarely exceed
    /// a few hundred KB, so 2 MB is generous headroom.
    static let maxPrefixBytes = 2_000_000

    init(session: URLSession = EarshotURLSession.shared) {
        self.session = session
    }

    // MARK: Local

    /// Reads the ID3 tag bytes from a local audio file. Returns nil when the
    /// file can't be opened or doesn't start with an ID3v2 tag (e.g. an M4A,
    /// which is handled by the AVAsset path instead).
    func tagData(localPath: String) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: localPath) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 10), header.count == 10,
              let total = ID3ChapterParser.totalTagSize(header: header) else { return nil }
        let capped = min(total, Self.maxPrefixBytes)
        try? handle.seek(toOffset: 0)
        return try? handle.read(upToCount: capped)
    }

    // MARK: Remote

    /// Fetches the ID3 tag bytes from a remote audio URL via ranged reads.
    /// Returns nil when the URL is invalid, the file has no ID3 tag, or the
    /// network read fails.
    func tagData(remote urlString: String) async -> Data? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.hasPrefix("http") == true else { return nil }

        // Step 1: read the 10-byte header to validate it and size the tag.
        guard let header = try? await prefix(of: url, upTo: 10), header.count == 10,
              let total = ID3ChapterParser.totalTagSize(header: header) else { return nil }

        // Step 2: read the whole tag region (capped).
        let capped = min(total, Self.maxPrefixBytes)
        guard let tag = try? await prefix(of: url, upTo: capped), !tag.isEmpty else { return nil }
        return tag
    }

    /// Reads up to `cap` bytes from the start of `url`. Sends a `Range` request
    /// for `bytes=0-(cap-1)`; whether the server answers `206` (ranged) or `200`
    /// (range ignored, full body streamed), the read stops once `cap` bytes have
    /// arrived. Runs the byte-stream loop wherever the caller's executor is — the
    /// service calls this from a detached task so it stays off the main actor.
    private func prefix(of url: URL, upTo cap: Int) async throws -> Data {
        guard cap > 0 else { return Data() }
        var request = URLRequest(url: url)
        request.setValue("bytes=0-\(cap - 1)", forHTTPHeaderField: "Range")

        let (bytes, _) = try await session.bytes(for: request)
        var out = Data()
        out.reserveCapacity(min(cap, 65_536))
        for try await byte in bytes {
            out.append(byte)
            if out.count >= cap { break }
        }
        return out
    }
}
