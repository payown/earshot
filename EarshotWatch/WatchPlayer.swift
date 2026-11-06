import AVFoundation
import Accessibility
import Foundation
import Observation
import MediaPlayer
import WidgetKit

@MainActor
@Observable
final class WatchPlayer {
    private let player = AVPlayer()
    private var observer: Any?
    private var lastSavedSecond = -1
    private var sleepTask: Task<Void, Never>?
    private var notificationTokens: [NSObjectProtocol] = []
    private let library: WatchLibrary

    private(set) var episode: WatchEpisode?
    private(set) var isPlaying = false
    private(set) var isBuffering = false
    private(set) var positionSeconds: Double = 0
    private(set) var durationSeconds: Double = 0
    private(set) var rate: Float = 1
    private(set) var status = "Not playing"
    private(set) var sleepDescription = "Sleep timer off"
    private(set) var chapters: [Chapter] = []

    var currentChapterIndex: Int? { chapters.activeChapterIndex(at: positionSeconds) }

    init(library: WatchLibrary) {
        self.library = library
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 1), queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in self?.timeDidChange(time.seconds) }
        }
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor [weak self] in self?.handleInterruption(raw) }
        })
        notificationTokens.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor [weak self] in self?.handleRouteChange(raw) }
        })
        configureRemoteCommands()
    }

    func play(_ item: WatchEpisode, at requestedPosition: Double? = nil) async {
        guard let remote = URL(string: item.audioURL), ["https", "http"].contains(remote.scheme?.lowercased() ?? "") else {
            status = "This episode has no playable audio address"
            AccessibilityNotification.Announcement(status).post()
            return
        }
        let local = item.downloadFilename.map { WatchDownloadManager.destination(for: $0) }
        let url = local.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? remote
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
            try await session.activate()
            let changedEpisode = episode?.identity != item.identity
            if changedEpisode {
                player.replaceCurrentItem(with: AVPlayerItem(url: url))
                episode = item
                positionSeconds = 0
                durationSeconds = 0
                lastSavedSecond = -1
                chapters = ChapterParser.parseDescriptionChapters(item.summary)
                Task { @MainActor [weak self] in await self?.loadChapters(for: item) }
            }
            let resume = max(0, requestedPosition ?? item.positionSeconds)
            if changedEpisode || abs(positionSeconds - resume) > 2 {
                await player.seek(to: CMTime(seconds: resume, preferredTimescale: 600))
            }
            player.defaultRate = rate
            player.play()
            player.rate = rate
            isBuffering = true
            status = "Starting playback on Apple Watch"
            for _ in 0..<20 where player.timeControlStatus != .playing {
                try await Task.sleep(for: .milliseconds(500))
            }
            guard player.timeControlStatus == .playing else {
                player.pause()
                isPlaying = false
                isBuffering = false
                status = "Apple Watch could not start audio. Check the playback route or network."
                AccessibilityNotification.Announcement(status).post()
                return
            }
            isPlaying = true
            isBuffering = false
            status = "Playing on Apple Watch"
            AccessibilityNotification.Announcement(status).post()
            publishNowPlaying()
            WatchWidgetSnapshot.save(title: item.title, playing: true)
        } catch {
            isPlaying = false
            status = "Could not start watch playback: \(error.localizedDescription)"
            AccessibilityNotification.Announcement(status).post()
            AppLog.player.error("Watch playback failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func pause() {
        player.pause()
        isPlaying = false
        status = "Paused on Apple Watch"
        AccessibilityNotification.Announcement(status).post()
        savePosition()
        publishNowPlaying()
        WatchWidgetSnapshot.save(title: episode?.title, playing: false)
    }

    func toggle() async {
        if isPlaying { pause() }
        else if let episode { await play(episode, at: positionSeconds) }
    }

    func seek(to seconds: Double) async {
        let upper = durationSeconds > 0 ? durationSeconds : Double.greatestFiniteMagnitude
        let target = min(max(0, seconds), upper)
        await player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        positionSeconds = target
        savePosition()
        publishNowPlaying()
    }

    func skipBackward() async { await seek(to: positionSeconds - Double(library.skipBackward)) }
    func skipForward() async { await seek(to: positionSeconds + Double(library.skipForward)) }

    func setRate(_ newRate: Float) {
        rate = min(3, max(0.5, newRate))
        if isPlaying { player.rate = rate }
        publishNowPlaying()
    }

    func nextChapter() async {
        let next = (currentChapterIndex ?? -1) + 1
        if chapters.indices.contains(next) { await seek(to: chapters[next].startTime) }
    }

    func previousChapter() async {
        guard !chapters.isEmpty else { return }
        let current = currentChapterIndex ?? 0
        let within = positionSeconds - chapters[current].startTime
        if let index = ChapterNavLogic.previousIndex(currentIndex: current, count: chapters.count, positionWithinChapter: within) {
            await seek(to: chapters[index].startTime)
        }
    }

    private func loadChapters(for item: WatchEpisode) async {
        guard let address = item.chapterURL, let url = URL(string: address), url.scheme == "https" else { return }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard data.count <= 2_000_000, (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            let parsed = ChapterParser.parsePodcastIndexJSON(data)
            if episode?.identity == item.identity, !parsed.isEmpty { chapters = parsed }
        } catch { AppLog.player.info("Watch chapter metadata unavailable") }
    }

    func setSleepTimer(minutes: Int?) {
        sleepTask?.cancel()
        guard let minutes else { sleepDescription = "Sleep timer off"; return }
        sleepDescription = "Sleep timer set for \(minutes) minutes"
        sleepTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(minutes * 60))
            guard !Task.isCancelled else { return }
            self?.pause()
            self?.sleepDescription = "Sleep timer finished"
        }
    }

    private func timeDidChange(_ seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        positionSeconds = seconds
        let duration = player.currentItem?.duration.seconds ?? 0
        if duration.isFinite, duration > 0 { durationSeconds = duration }
        isBuffering = isPlaying && player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        let currentSecond = Int(seconds)
        if currentSecond / 15 != lastSavedSecond / 15, currentSecond > 0 {
            lastSavedSecond = currentSecond
            savePosition()
        }
        if durationSeconds > 0, seconds >= durationSeconds - 1, isPlaying {
            isPlaying = false
            episode?.isPlayed = true
            episode?.inboxDismissed = true
            savePosition()
            status = "Episode finished"
        }
    }

    private func savePosition() {
        episode?.positionSeconds = positionSeconds
        episode?.updatedAt = .now
        library.persist()
    }

    private func handleInterruption(_ raw: UInt?) {
        guard let raw,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .began { pause(); status = "Playback interrupted" }
        else { status = "Interruption ended. Resume playback when ready." }
    }

    private func handleRouteChange(_ raw: UInt?) {
        guard let raw,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        if reason == .oldDeviceUnavailable { pause(); status = "Headphones disconnected. Playback paused." }
    }

    private func publishNowPlaying() {
        guard let episode else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: episode.title,
            MPMediaItemPropertyArtist: episode.podcastTitle,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: positionSeconds,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? rate : 0
        ]
        if durationSeconds > 0 { info[MPMediaItemPropertyPlaybackDuration] = durationSeconds }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor [weak self] in
                guard let self, let episode = self.episode else { return }
                await self.play(episode, at: self.positionSeconds)
            }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.pause() }
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: library.skipForward)]
        center.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in await self?.skipForward() }
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: library.skipBackward)]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in await self?.skipBackward() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor [weak self] in await self?.seek(to: position) }
            return .success
        }
    }
}
