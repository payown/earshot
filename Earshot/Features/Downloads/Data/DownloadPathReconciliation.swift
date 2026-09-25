import Foundation
import SwiftData

/// Reads device-local scalars and checks files away from the UI executor. No
/// SwiftData models cross back, and healthy downloads require no main-store fetch.
enum DownloadPathReconciliation {
    struct Correction: Sendable {
        let key: EpisodeLocalKey
        let originalPath: String
        let originalStatus: String
        let replacementName: String?
        let checkedURL: URL?
    }

    @concurrent
    static func scan(container: ModelContainer) async throws -> [Correction] {
        try Task.checkCancellation()
        let context = ModelContext(container)
        let rows = try context.fetch(FetchDescriptor<LocalEpisodeState>(
            predicate: #Predicate { $0.downloadPath != nil }
        ))
        // Directory creation and backup exclusion only need doing once per scan.
        let directory = try? DownloadPaths.downloadsDirectory()
        var corrections: [Correction] = []
        for row in rows {
            try Task.checkCancellation()
            guard let path = row.downloadPath else { continue }
            let name = DownloadPaths.storedFileName(path)
            let url: URL?
            let replacement: String?
            if let name {
                guard let directory else { continue }
                let candidate = directory.appendingPathComponent(name)
                url = candidate
                if FileManager.default.fileExists(atPath: candidate.path) {
                    guard path != name else { continue }
                    replacement = name
                } else {
                    replacement = nil
                }
            } else {
                url = nil
                replacement = nil
            }
            corrections.append(Correction(
                key: EpisodeLocalKey(feedURL: row.podcastFeedURL, guid: row.episodeGUID),
                originalPath: path,
                originalStatus: row.downloadStatusRaw,
                replacementName: replacement,
                checkedURL: url
            ))
        }
        return corrections
    }
}
