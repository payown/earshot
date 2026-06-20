import Foundation
import AVFoundation
import Observation

/// Minimal AVFoundation playback for the slice: play an episode's audio,
/// toggle play/pause, expose what's playing for the Now Playing bar.
@Observable
final class PlayerService {
    private let player = AVPlayer()

    var currentTitle: String?
    var isPlaying = false

    func play(_ episode: Episode) {
        guard let url = URL(string: episode.audioURL) else {
            AppLog.player.error("Cannot play episode, invalid audio URL: \(episode.audioURL, privacy: .public)")
            return
        }
        configureSession()
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        player.play()
        currentTitle = episode.title
        isPlaying = true
    }

    func togglePlayPause() {
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
    }

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback)
            try session.setActive(true)
        } catch {
            AppLog.player.error("Failed to configure audio session: \(error.localizedDescription, privacy: .public)")
        }
    }
}
