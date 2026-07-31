import Foundation
import AVFoundation

/// Resolves an episode's chapters, trying sources in order of fidelity:
/// 1. A Podcasting 2.0 chapters file (`Episode.chapterURL`).
/// 2. Chapter metadata embedded in the audio file:
///    - **ID3v2 `CHAP` frames** (MP3 — the Auphonic/NosillaCast case), read from
///      the local file when downloaded, else via a ranged read of the streaming
///      URL. AVFoundation does not extract these, so ``ID3ChapterParser`` does.
///    - **MP4/M4A chapter atoms**, read via `AVURLAsset`.
/// 3. Timestamps parsed from the show-notes description.
///
/// Pure parsing lives in ``ChapterParser`` / ``ID3ChapterParser``; this layer
/// does the I/O. The embedded-chapter work runs on a detached task so the byte
/// fetch and parse stay off the main actor — only the `Sendable` `[Chapter]`
/// result crosses back.
struct ChapterService {
    private let http: HTTPClient
    private let id3Fetcher: ID3TagFetcher

    init(http: HTTPClient = HTTPClient(), id3Fetcher: ID3TagFetcher = ID3TagFetcher()) {
        self.http = http
        self.id3Fetcher = id3Fetcher
    }

    /// Fetches chapters for an episode, returning the first non-empty source.
    ///
    /// - Parameter downloadPath: The RESOLVED local audio file path when the
    ///   episode is downloaded (pass `episode.localAudioURL?.path`, never the
    ///   stored `downloadPath`, #575). When the file exists, embedded chapters
    ///   are read from disk (faster and more reliable than the redirect-tracked
    ///   remote URL).
    func chapters(
        chapterURL: String?,
        audioURL: String,
        downloadPath: String? = nil,
        descriptionHTML: String?
    ) async -> [Chapter] {
        if let chapterURL, !chapterURL.isEmpty,
           let data = try? await http.data(from: chapterURL) {
            let parsed = ChapterParser.parsePodcastIndexJSON(data)
            if !parsed.isEmpty { return parsed }
        }

        let localURL = localFileURL(downloadPath)

        // Embedded ID3 (MP3) — the common chaptered-podcast format.
        if let id3 = await id3Chapters(audioURL: audioURL, localURL: localURL), !id3.isEmpty {
            return id3
        }

        // Embedded MP4/M4A chapter atoms, preferring the local file.
        let assetURL = localURL ?? URL(string: audioURL)
        if let assetURL, let embedded = await avAssetChapters(url: assetURL), !embedded.isEmpty {
            return embedded
        }

        return ChapterParser.parseDescriptionChapters(descriptionHTML)
    }

    /// The local file URL for a downloaded episode, or nil when there's no
    /// downloaded file on disk.
    private func localFileURL(_ downloadPath: String?) -> URL? {
        guard let downloadPath, !downloadPath.isEmpty,
              FileManager.default.fileExists(atPath: downloadPath) else { return nil }
        return URL(fileURLWithPath: downloadPath)
    }

    /// Reads ID3v2 `CHAP` chapters, from the local file when present, else via a
    /// ranged read of the streaming URL. The fetch and parse run off the main
    /// actor; only the `Sendable` result crosses back. Returns nil when the
    /// audio isn't an ID3-tagged MP3 or carries no chapters.
    private func id3Chapters(audioURL: String, localURL: URL?) async -> [Chapter]? {
        let fetcher = id3Fetcher
        return await Task.detached(priority: .utility) { () -> [Chapter]? in
            let tagData: Data?
            if let localURL {
                tagData = fetcher.tagData(localPath: localURL.path)
            } else {
                tagData = await fetcher.tagData(remote: audioURL)
            }
            guard let tagData else { return nil }
            let chapters = ID3ChapterParser.parse(tagData)
            return chapters.isEmpty ? nil : chapters
        }.value
    }

    /// Reads embedded chapter metadata (MP4 / M4A timed metadata) from the audio
    /// asset. Returns nil when the asset has no chapters or can't be loaded.
    private func avAssetChapters(url: URL) async -> [Chapter]? {
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
            AppLog.player.info("No embedded chapters for \(url.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
