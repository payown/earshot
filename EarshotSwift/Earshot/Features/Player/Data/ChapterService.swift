import Foundation
import AVFoundation

/// Resolves an episode's chapters, trying sources in order of fidelity:
/// 1. A Podcasting 2.0 chapters file (`Episode.chapterURL`).
/// 2. Chapter metadata embedded in the audio file (ID3 / MP4), read via AVAsset.
/// 3. Timestamps parsed from the show-notes description.
/// Pure parsing lives in ``ChapterParser``; this layer does the I/O.
struct ChapterService {
    private let http: HTTPClient

    init(http: HTTPClient = HTTPClient()) {
        self.http = http
    }

    /// Fetches chapters for an episode, returning the first non-empty source.
    func chapters(
        chapterURL: String?,
        audioURL: String,
        descriptionHTML: String?
    ) async -> [Chapter] {
        if let chapterURL, !chapterURL.isEmpty,
           let data = try? await http.data(from: chapterURL) {
            let parsed = ChapterParser.parsePodcastIndexJSON(data)
            if !parsed.isEmpty { return parsed }
        }

        if let embedded = await embeddedChapters(audioURL: audioURL), !embedded.isEmpty {
            return embedded
        }

        return ChapterParser.parseDescriptionChapters(descriptionHTML)
    }

    /// Reads embedded chapter metadata (ID3 / MP4 timed metadata) from the audio
    /// asset. Returns nil when the asset has no chapters or can't be loaded.
    private func embeddedChapters(audioURL: String) async -> [Chapter]? {
        guard let url = URL(string: audioURL) else { return nil }
        let asset = AVURLAsset(url: url)
        do {
            let languages = Locale.preferredLanguages
            let groups = try await asset.loadChapterMetadataGroups(
                bestMatchingPreferredLanguages: languages
            )
            guard !groups.isEmpty else { return nil }

            var chapters: [Chapter] = []
            for (i, group) in groups.enumerated() {
                let start = group.timeRange.start.seconds
                guard start.isFinite else { continue }
                let titleItem = group.items.first { $0.commonKey == .commonKeyTitle }
                let title = (try? await titleItem?.load(.stringValue)) ?? nil
                chapters.append(
                    Chapter(index: chapters.count, startTime: start, title: title ?? "Chapter \(i + 1)")
                )
            }
            return chapters
        } catch {
            AppLog.player.info("No embedded chapters for \(audioURL, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
