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
}
