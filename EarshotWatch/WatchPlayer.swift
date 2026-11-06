import AVFoundation
import Accessibility
import Foundation
import Observation
import MediaPlayer
import WidgetKit

enum WatchPlaybackSource {
    static func choose(local: URL?, remoteAddress: String) -> URL? {
        if let local, FileManager.default.fileExists(atPath: local.path) { return local }
        guard let remote = URL(string: remoteAddress),
              ["https", "http"].contains(remote.scheme?.lowercased() ?? "") else { return nil }
        return remote
    }
}

@MainActor
@Observable
final class WatchPlayer {
    private let player = AVPlayer()
    private var observer: Any?
    private var lastSavedSecond = -1
    private var sleepTask: Task<Void, Never>?
    private var sleepDeadline: Date?
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
    private(set) var routeDescription = "Route unavailable"
    private(set) var chapters: [Chapter] = []

    var currentChapterIndex: Int? { chapters.activeChapterIndex(at: positionSeconds) }

    init(library: WatchLibrary) {
        self.library = library
        if let resumable = library.episodes
            .filter({ !$0.isPlayed && $0.positionSeconds > 0 })
            .max(by: { $0.updatedAt < $1.updatedAt }) {
            episode = resumable
            positionSeconds = resumable.positionSeconds
            durationSeconds = Double(resumable.durationSeconds ?? 0)
            status = "Ready to continue on Apple Watch"
            WatchWidgetSnapshot.save(title: resumable.title, playing: false)
        } else {
            WatchWidgetSnapshot.save(title: nil, playing: false)
        }
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
        updateRoute()
        if let deadline = UserDefaults.standard.object(forKey: "watchSleepDeadline") as? Date,
           deadline > .now {
            installSleepTimer(until: deadline)
        } else {
            UserDefaults.standard.removeObject(forKey: "watchSleepDeadline")
        }
    }

    func play(_ item: WatchEpisode, at requestedPosition: Double? = nil) async {
        let local = item.downloadFilename.map { WatchDownloadManager.destination(for: $0) }
        guard let url = WatchPlaybackSource.choose(local: local, remoteAddress: item.audioURL) else {
            status = "This episode has no playable audio address"
            AccessibilityNotification.Announcement(status).post()
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
            try await session.activate()
            updateRoute()
            let changedEpisode = player.currentItem == nil || episode?.identity != item.identity
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
            positionSeconds = resume
            savePosition()
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

    func pause(announce: Bool = true) {
        player.pause()
        isPlaying = false
        status = "Paused on Apple Watch"
        if announce { AccessibilityNotification.Announcement(status).post() }
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
        AccessibilityNotification.Announcement("Speed set to \(rate.formatted()) times").post()
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
        guard let minutes else {
            sleepDeadline = nil
            UserDefaults.standard.removeObject(forKey: "watchSleepDeadline")
            sleepDescription = "Sleep timer off"
            AccessibilityNotification.Announcement(sleepDescription).post()
            return
        }
        let deadline = Date.now.addingTimeInterval(Double(minutes * 60))
        UserDefaults.standard.set(deadline, forKey: "watchSleepDeadline")
        installSleepTimer(until: deadline)
        AccessibilityNotification.Announcement("Sleep timer set for \(minutes) minutes").post()
    }

    private func installSleepTimer(until deadline: Date) {
        sleepDeadline = deadline
        sleepTask?.cancel()
        sleepDescription = "Sleep timer on, \(max(1, Int(ceil(deadline.timeIntervalSinceNow / 60)))) minutes remaining"
        sleepTask = Task { @MainActor [weak self] in
            var lastAnnounced = Int(ceil(deadline.timeIntervalSinceNow / 60))
            while !Task.isCancelled {
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 {
                    self?.pause(announce: false)
                    self?.sleepDescription = "Sleep timer finished"
                    self?.sleepDeadline = nil
                    UserDefaults.standard.removeObject(forKey: "watchSleepDeadline")
                    AccessibilityNotification.Announcement("Sleep timer finished").post()
                    return
                }
                let minutes = max(1, Int(ceil(remaining / 60)))
                self?.sleepDescription = "Sleep timer on, \(minutes) minutes remaining"
                if minutes % 5 == 0, minutes != lastAnnounced {
                    AccessibilityNotification.Announcement("Sleep timer: \(minutes) minutes remaining").post()
                    lastAnnounced = minutes
                }
                try? await Task.sleep(for: .seconds(min(60, remaining)))
            }
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
            episode?.playedUpdatedAt = .now
            episode?.inboxDismissedUpdatedAt = .now
            if let episode { library.stageListeningPosition(episode) }
            savePosition()
            status = "Episode finished"
            WatchWidgetSnapshot.save(title: episode?.title, playing: false)
            if let episode {
                let next = library.queue.first { $0.identity != episode.identity }
                if episode.queuePosition != nil { library.removeFromQueue(episode, announce: false) }
                if let next { Task { @MainActor [weak self] in await self?.play(next) } }
            }
        }
    }

    private func savePosition() {
        episode?.positionSeconds = positionSeconds
        episode?.updatedAt = .now
        if let episode { library.stageListeningPosition(episode) }
        library.persist()
    }

    func saveForLifecycle() { if episode != nil { savePosition() } }

    private func handleInterruption(_ raw: UInt?) {
        guard let raw,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .began {
            pause(announce: false)
            status = "Playback interrupted"
            AccessibilityNotification.Announcement(status).post()
        }
        else { status = "Interruption ended. Resume playback when ready." }
    }

    private func handleRouteChange(_ raw: UInt?) {
        updateRoute()
        guard let raw,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        if reason == .oldDeviceUnavailable {
            pause(announce: false)
            status = "Headphones disconnected. Playback paused."
            AccessibilityNotification.Announcement(status).post()
        }
    }

    private func updateRoute() {
        let names = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portName)
        routeDescription = names.isEmpty ? "No audio output selected" : names.joined(separator: ", ")
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
