import Foundation
import AVFoundation
import MediaPlayer
import Observation
import SwiftData

/// AVPlayer-based playback engine for Earshot.
///
/// Owns the single `AVPlayer`, drives the Now Playing bar, persists listening
/// position / played state to SwiftData, keeps the lock screen
/// (`MPNowPlayingInfoCenter`) and remote commands (`MPRemoteCommandCenter`) in
/// sync, and reacts to audio-session interruptions and route changes.
///
/// Pure rules (source resolution, speed, completion threshold) live in
/// ``PlaybackLogic`` so they can be tested without real audio.
@MainActor
@Observable
final class PlayerService {
    // MARK: Observed state (drives the UI)

    /// Title of the loaded episode, or `nil` when nothing is loaded.
    var currentTitle: String?
    /// Podcast / author name for the loaded episode, if known.
    var currentArtist: String?
    /// Whether audio is currently playing.
    var isPlaying = false
    /// Current playback position in seconds (kept fresh by the time observer).
    var currentPositionSeconds: Double = 0
    /// Loaded episode duration in seconds, if known.
    var durationSeconds: Double = 0

    // MARK: Private engine state

    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private var context: ModelContext?
    @ObservationIgnored private var settings: AppSettingsStore?
    @ObservationIgnored private var currentEpisode: Episode?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var didFinishObserver: NSObjectProtocol?
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?
    @ObservationIgnored private var routeChangeObserver: NSObjectProtocol?
    @ObservationIgnored private var remoteCommandsConfigured = false
    /// True when playback was paused by a system interruption that may resume.
    @ObservationIgnored private var pausedByInterruption = false

    // Listening-session recording (feeds Stats). We accumulate plausible per-tick
    // position advances and flush a `ListeningSession` every `sessionFlushSeconds`
    // (and on pause / stop / episode switch). Forward skips and seeks are filtered
    // out by `StatsLogic.isListeningStep`.
    @ObservationIgnored private var lastTickPosition: Double?
    @ObservationIgnored private var accumulatedListenSeconds: Double = 0
    @ObservationIgnored private let sessionFlushSeconds: Double = 30

    // Gapless preload: the next queue item is built (and starts buffering) ahead
    // of time so auto-advance is near-seamless. Invalidated whenever the queue
    // changes (via `.earshotQueueDidChange`).
    @ObservationIgnored private var preloadedItem: AVPlayerItem?
    @ObservationIgnored private var preloadedEpisode: Episode?
    @ObservationIgnored private var queueChangeObserver: NSObjectProtocol?

    // MARK: Lifecycle

    /// Wires the service to a persistence context. Call once at app startup with
    /// the shared container's `mainContext`. Must not be called from a view body.
    func configure(context: ModelContext) {
        self.context = context
        self.settings = AppSettingsStore(context: context)
        configureRemoteCommands()
        observeNotifications()
        observePeriodicTime()
        observeItemDidPlayToEnd()
        observeQueueChanges()
    }

    // MARK: Public playback API

    /// Loads and starts playing an episode. Resumes from the saved position when
    /// the episode is below the played threshold, otherwise starts from the top.
    func play(_ episode: Episode) {
        play(episode, preparedItem: nil)
    }

    /// The currently loaded episode, if any. Exposed read-only for features that
    /// act on the current item — e.g. bookmarking the current position.
    var nowPlayingEpisode: Episode? { currentEpisode }

    /// Plays `episode` and jumps to an explicit start position. Backs
    /// jump-to-bookmark, where the saved position must be overridden.
    func play(_ episode: Episode, at startSeconds: Double) {
        play(episode, preparedItem: nil)
        seek(to: startSeconds)
    }

    /// Shared play path. `preparedItem`, when supplied, is a pre-buffered
    /// `AVPlayerItem` from the gapless preload, used for near-seamless advance.
    private func play(_ episode: Episode, preparedItem: AVPlayerItem?) {
        let item: AVPlayerItem
        if let preparedItem {
            item = preparedItem
        } else {
            guard let url = PlaybackLogic.resolvePlaybackURL(
                downloadPath: episode.downloadPath,
                audioURL: episode.audioURL
            ) else {
                AppLog.player.error("Cannot play episode, no usable source: \(episode.audioURL, privacy: .public)")
                return
            }
            item = AVPlayerItem(url: url)
        }

        // Persist + record the session of whatever was playing before we swap.
        persistCurrentPosition()
        flushListeningSession()

        configureSession()

        currentEpisode = episode
        currentTitle = episode.title
        currentArtist = episode.podcast?.title ?? episode.podcast?.author
        durationSeconds = episode.durationSeconds.map(Double.init) ?? 0

        player.replaceCurrentItem(with: item)

        // Resume position: honor saved progress unless past the threshold.
        let decision = PlaybackLogic.completionDecision(
            position: episode.positionSeconds,
            duration: episode.durationSeconds
        )
        if decision.resumePosition > 0 {
            player.seek(to: CMTime(seconds: Double(decision.resumePosition), preferredTimescale: 1))
            currentPositionSeconds = Double(decision.resumePosition)
        } else {
            currentPositionSeconds = 0
        }
        resetListeningTracking()

        applyRate()
        player.play()
        isPlaying = true
        pausedByInterruption = false

        persistLastPlayingEpisode(episode)
        updateNowPlayingInfo()
        refreshPreload()
    }

    /// Loads an episode paused, restoring its saved position. Used on launch to
    /// repopulate the Now Playing bar without starting audio.
    func load(_ episode: Episode, autoplay: Bool = false) {
        if autoplay {
            play(episode)
            return
        }
        guard let url = PlaybackLogic.resolvePlaybackURL(
            downloadPath: episode.downloadPath,
            audioURL: episode.audioURL
        ) else {
            AppLog.player.error("Cannot load episode, no usable source: \(episode.audioURL, privacy: .public)")
            return
        }
        currentEpisode = episode
        currentTitle = episode.title
        currentArtist = episode.podcast?.title ?? episode.podcast?.author
        durationSeconds = episode.durationSeconds.map(Double.init) ?? 0

        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)

        let decision = PlaybackLogic.completionDecision(
            position: episode.positionSeconds,
            duration: episode.durationSeconds
        )
        let resume = decision.resumePosition
        if resume > 0 {
            player.seek(to: CMTime(seconds: Double(resume), preferredTimescale: 1))
        }
        currentPositionSeconds = Double(resume)
        isPlaying = false
        updateNowPlayingInfo()
    }

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    func resume() {
        guard currentEpisode != nil else { return }
        configureSession()
        applyRate()
        player.play()
        isPlaying = true
        pausedByInterruption = false
        updateNowPlayingInfo()
    }

    func pause() {
        player.pause()
        isPlaying = false
        persistCurrentPosition()
        flushListeningSession()
        updateNowPlayingInfo()
    }

    /// Skips forward by the user-configured interval (default 30s).
    func skipForward() {
        seek(by: Double(skipForwardSeconds))
    }

    /// Skips back by the user-configured interval (default 15s).
    func skipBack() {
        seek(by: -Double(skipBackSeconds))
    }

    /// Seeks to an absolute position in seconds, clamped to the item duration.
    func seek(to seconds: Double) {
        let clamped = max(0, min(seconds, durationSeconds > 0 ? durationSeconds : seconds))
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 1))
        currentPositionSeconds = clamped
        persistCurrentPosition()
        updateNowPlayingInfo()
    }

    // MARK: Settings-backed values

    var skipForwardSeconds: Int {
        settings?.int(SettingsKey.skipForwardSeconds, default: SettingsDefault.skipForwardSeconds)
            ?? SettingsDefault.skipForwardSeconds
    }

    var skipBackSeconds: Int {
        settings?.int(SettingsKey.skipBackSeconds, default: SettingsDefault.skipBackSeconds)
            ?? SettingsDefault.skipBackSeconds
    }

    // MARK: Private — seek helper

    private func seek(by delta: Double) {
        let target = currentPositionSeconds + delta
        seek(to: target)
    }

    // MARK: Private — rate

    /// The playback rate that applies to the loaded episode (per-podcast override
    /// or the global speed). Also the speed recorded on listening sessions.
    private var currentEffectiveRate: Double {
        let global = settings?.double(SettingsKey.globalSpeed, default: SettingsDefault.globalSpeed)
            ?? SettingsDefault.globalSpeed
        return PlaybackLogic.effectivePlaybackRate(
            podcastSpeedOverride: currentEpisode?.podcast?.speedOverride,
            globalSpeed: global
        )
    }

    private func applyRate() {
        let rate = currentEffectiveRate
        // Setting `rate` also starts playback; only apply when we intend to play.
        if isPlaying || player.timeControlStatus == .playing {
            player.rate = Float(rate)
        } else {
            player.rate = 0
            // Stash the desired rate so the next play() uses it via defaultRate.
            player.defaultRate = Float(rate)
        }
    }

    // MARK: Private — audio session

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
        } catch {
            AppLog.player.error("Failed to configure audio session: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Private — periodic time / persistence

    private func observePeriodicTime() {
        let interval = CMTime(seconds: 1, preferredTimescale: 1)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            Task { @MainActor in
                self.handleTick(currentSeconds: time.seconds)
            }
        }
    }

    private func handleTick(currentSeconds: Double) {
        guard currentSeconds.isFinite else { return }
        currentPositionSeconds = currentSeconds

        // Keep duration fresh once the item reports it.
        if durationSeconds <= 0,
           let itemDuration = player.currentItem?.duration.seconds,
           itemDuration.isFinite, itemDuration > 0 {
            durationSeconds = itemDuration
            currentEpisode?.durationSeconds = Int(itemDuration)
        }

        persistCurrentPosition()
        recordListeningTick()
        updateNowPlayingElapsed()

        // Mark played once we cross the threshold.
        let duration = currentEpisode?.durationSeconds ?? (durationSeconds > 0 ? Int(durationSeconds) : nil)
        let decision = PlaybackLogic.completionDecision(position: Int(currentSeconds), duration: duration)
        if decision.shouldMarkPlayed, let episode = currentEpisode, !episode.isPlayed {
            markCurrentEpisodePlayed()
        }
    }

    private func persistCurrentPosition() {
        guard let episode = currentEpisode, currentPositionSeconds.isFinite else { return }
        episode.positionSeconds = Int(max(0, currentPositionSeconds))
        saveContext()
    }

    // MARK: Private — listening-session recording

    /// Accumulates the position advance since the last tick (dropping seeks/skips)
    /// and flushes a session once enough real listening has built up.
    private func recordListeningTick() {
        guard isPlaying, currentPositionSeconds.isFinite else { return }
        defer { lastTickPosition = currentPositionSeconds }
        guard let last = lastTickPosition else { return }
        let step = currentPositionSeconds - last
        if StatsLogic.isListeningStep(step) {
            accumulatedListenSeconds += step
        }
        if accumulatedListenSeconds >= sessionFlushSeconds {
            flushListeningSession()
        }
    }

    /// Writes the accumulated listening time as a ``ListeningSession`` and resets
    /// the accumulator. Called on the flush threshold and on pause / stop /
    /// episode switch. `minSeconds` drops trivial spans.
    private func flushListeningSession(minSeconds: Int = 2) {
        guard let episode = currentEpisode, let context else {
            accumulatedListenSeconds = 0
            return
        }
        let seconds = Int(accumulatedListenSeconds)
        accumulatedListenSeconds = 0
        guard seconds >= minSeconds else { return }
        let session = ListeningSession(
            episode: episode,
            podcast: episode.podcast,
            durationSeconds: seconds,
            speed: currentEffectiveRate,
            date: .now
        )
        context.insert(session)
        saveContext()
    }

    /// Resets per-episode tick tracking when a new episode loads.
    private func resetListeningTracking() {
        lastTickPosition = currentPositionSeconds
        accumulatedListenSeconds = 0
    }

    private func markCurrentEpisodePlayed() {
        guard let episode = currentEpisode else { return }
        episode.isPlayed = true
        episode.positionSeconds = 0
        saveContext()
        AppLog.player.info("Marked episode played: \(episode.title, privacy: .public)")
    }

    private func persistLastPlayingEpisode(_ episode: Episode) {
        // Use the stable feed-level guid as the durable identifier.
        settings?.setRawValue(episode.guid, for: SettingsKey.lastPlayingEpisodeID)
    }

    private func saveContext() {
        guard let context, context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            AppLog.player.error("Failed to persist playback state: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Private — item completion

    private func observeItemDidPlayToEnd() {
        didFinishObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handlePlaybackEnded() }
        }
    }

    private func handlePlaybackEnded() {
        guard let finished = currentEpisode, let context else {
            isPlaying = false
            markCurrentEpisodePlayed()
            updateNowPlayingInfo()
            return
        }

        // Record the just-finished listening before advancing.
        flushListeningSession()

        let repo = QueueRepository(context: context)
        let queued = repo.queue()
        let nextID = PlaybackLogic.nextUpID(
            queue: queued.map(\.persistentModelID),
            after: finished.persistentModelID
        )
        let nextEpisode = queued.first { $0.persistentModelID == nextID }

        // The finished episode: mark played and remove it from the queue. Reset
        // its position since it played to the end.
        repo.markPlayedAndRemove(finished)
        finished.positionSeconds = 0
        saveContext()

        guard let nextEpisode else {
            isPlaying = false
            currentEpisode = nil
            updateNowPlayingInfo()
            return
        }

        // Use the pre-buffered item when it's still the right one.
        let prepared = preloadedEpisode?.persistentModelID == nextEpisode.persistentModelID
            ? preloadedItem : nil
        preloadedItem = nil
        preloadedEpisode = nil
        play(nextEpisode, preparedItem: prepared)
        Announcer.announce("Now playing \(nextEpisode.title)")
    }

    // MARK: Private — gapless preload

    private func observeQueueChanges() {
        queueChangeObserver = NotificationCenter.default.addObserver(
            forName: .earshotQueueDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshPreload() }
        }
    }

    /// Builds (and starts buffering) the next queue item ahead of time, or clears
    /// a stale preload when the up-next episode changed or the queue emptied.
    private func refreshPreload() {
        guard let context, let current = currentEpisode else {
            clearPreload()
            return
        }
        let queued = QueueRepository(context: context).queue()
        let nextID = PlaybackLogic.nextUpID(
            queue: queued.map(\.persistentModelID),
            after: current.persistentModelID
        )
        guard let next = queued.first(where: { $0.persistentModelID == nextID }) else {
            clearPreload()
            return
        }
        // Already buffering the right episode — nothing to do.
        if preloadedEpisode?.persistentModelID == next.persistentModelID { return }
        guard let url = PlaybackLogic.resolvePlaybackURL(
            downloadPath: next.downloadPath,
            audioURL: next.audioURL
        ) else {
            clearPreload()
            return
        }
        preloadedItem = AVPlayerItem(url: url)
        preloadedEpisode = next
    }

    private func clearPreload() {
        preloadedItem = nil
        preloadedEpisode = nil
    }

    // MARK: Private — interruptions & route changes (PRD 5.5)

    private func observeNotifications() {
        let session = AVAudioSession.sharedInstance()
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in self?.handleInterruption(note) }
        }
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in self?.handleRouteChange(note) }
        }
    }

    private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            if isPlaying {
                pause()
                pausedByInterruption = true
            }
        case .ended:
            guard let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume), pausedByInterruption {
                resume()
            }
            pausedByInterruption = false
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ note: Notification) {
        guard let info = note.userInfo,
              let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }
        // Headphones / Bluetooth unplugged: pause so audio doesn't blast aloud.
        if reason == .oldDeviceUnavailable, isPlaying {
            pause()
        }
    }

    // MARK: Private — Now Playing info

    private func updateNowPlayingInfo() {
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = currentTitle ?? ""
        if let artist = currentArtist {
            info[MPMediaItemPropertyArtist] = artist
        }
        if durationSeconds > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = durationSeconds
        }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentPositionSeconds
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? player.rate : 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Lightweight update of just the moving fields, called on every tick.
    private func updateNowPlayingElapsed() {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentPositionSeconds
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? player.rate : 0
        if durationSeconds > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = durationSeconds
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: Private — remote commands

    private func configureRemoteCommands() {
        guard !remoteCommandsConfigured else { return }
        remoteCommandsConfigured = true
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.resume()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.pause()
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.togglePlayPause()
            return .success
        }

        center.skipForwardCommand.preferredIntervals = [NSNumber(value: skipForwardSeconds)]
        center.skipForwardCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.skipForward()
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: skipBackSeconds)]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.skipBack()
            return .success
        }

        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self,
                  let positionEvent = event as? MPChangePlaybackPositionCommandEvent
            else { return .commandFailed }
            self.seek(to: positionEvent.positionTime)
            return .success
        }
    }
}
