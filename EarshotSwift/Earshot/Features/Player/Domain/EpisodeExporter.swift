import Foundation

/// Prepares an episode's audio for the system share sheet: downloads it if it
/// isn't already local, then copies the local file to a temp file named
/// "Podcast name - Episode title.ext" and returns that URL (#371, #689).
///
/// Deliberately free of `AVPlayer`/`PlayerService` state — it operates on any
/// `Episode` plus the shared `DownloadManager`, so every episode row can export,
/// not just the currently-playing episode. `PlayerService.exportCurrentEpisodeAudio`
/// now delegates here.
///
/// The share always targets the LOCAL downloaded file, never the remote enclosure
/// (the #401 concern), and copies rather than moves so the original download stays
/// intact for playback.
enum EpisodeExporter {
    @MainActor
    static func export(episode: Episode, using downloads: DownloadManager) async -> URL? {
        // Ensure the file is local first. downloadAndWait() is an immediate true
        // when already downloaded, an immediate false when the download can't
        // start (Wi-Fi gate, bad URL), and false after its internal timeout.
        let alreadyLocal = episode.localAudioURL.map {
            FileManager.default.fileExists(atPath: $0.path)
        } ?? false
        if !alreadyLocal {
            let downloaded = await downloads.downloadAndWait(episode)
            guard downloaded else {
                AppLog.player.error("Export failed: download did not complete for \(episode.title, privacy: .public)")
                return nil
            }
        }

        guard let localURL = episode.localAudioURL,
              FileManager.default.fileExists(atPath: localURL.path) else {
            AppLog.player.error("Export failed: no local file for \(episode.title, privacy: .public)")
            return nil
        }

        let fileName = EpisodeExportLogic.exportFileName(
            podcastTitle: episode.podcast?.title,
            episodeTitle: episode.title,
            sourceURL: URL(string: episode.audioURL)
        )
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(fileName)

        do {
            // Copy (not move) so the original download stays intact for playback.
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: localURL, to: destination)
            return destination
        } catch {
            AppLog.player.error("Export copy failed for \(episode.title, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
