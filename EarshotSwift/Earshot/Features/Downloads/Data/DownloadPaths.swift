import Foundation

/// Pure filesystem-path logic for downloaded episode audio. Kept separate from
/// ``DownloadManager`` so the destination naming is unit-testable and so the
/// off-main ``DownloadSessionDelegate`` can compute the same destination the
/// manager would (both key off the episode guid + source extension).
enum DownloadPaths {
    /// The `Documents/Downloads` directory, created if missing.
    static func downloadsDirectory() throws -> URL {
        let dir = try FileManager.default
            .url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The stable on-disk destination for an episode's audio inside `directory`,
    /// derived from its `guid` and the source URL's extension. Pure given
    /// `directory`, so it can be exercised in tests without touching Documents.
    static func destination(inDirectory directory: URL, guid: String, sourceURL: URL) -> URL {
        let ext = sourceURL.pathExtension.isEmpty ? "mp3" : sourceURL.pathExtension
        let safeName = guid.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? UUID().uuidString
        return directory.appendingPathComponent(safeName).appendingPathExtension(ext)
    }

    // MARK: Stored-value resolution (#575)

    /// The bare file name for a stored `Episode.downloadPath` value.
    ///
    /// New writes store only the file name, but rows written before #575 hold an
    /// ABSOLUTE container path — and iOS relocates the app container on every
    /// app update, so those absolute paths all go stale. Because the name itself
    /// is deterministic (guid-derived, see ``destination(inDirectory:guid:sourceURL:)``),
    /// the last path component of a legacy value is still the right file name.
    /// Pure, so it's unit-testable. Returns `nil` for nil/empty values.
    static func storedFileName(_ storedValue: String?) -> String? {
        guard let storedValue, !storedValue.isEmpty else { return nil }
        let name = storedValue.contains("/")
            ? (storedValue as NSString).lastPathComponent
            : storedValue
        return name.isEmpty ? nil : name
    }

    /// Resolves a stored `Episode.downloadPath` value against the CURRENT
    /// Downloads directory, tolerating legacy absolute paths. Returns `nil`
    /// when nothing is stored or the directory can't be resolved. Does not
    /// check that the file exists — callers that need that check it on the
    /// returned URL.
    static func resolveLocalURL(storedValue: String?) -> URL? {
        guard let name = storedFileName(storedValue),
              let directory = try? downloadsDirectory() else { return nil }
        return directory.appendingPathComponent(name)
    }
}

extension Episode {
    /// The on-disk URL for this episode's downloaded audio, or `nil` when
    /// nothing was downloaded. Always resolved against the CURRENT container
    /// (the stored value is just a file name; iOS moves the container on every
    /// app update, #575), so this — never `downloadPath` directly — is the one
    /// way to reach the local file. Existence is NOT checked here.
    var localAudioURL: URL? {
        DownloadPaths.resolveLocalURL(storedValue: downloadPath)
    }
}
