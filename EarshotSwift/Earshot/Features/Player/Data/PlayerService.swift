import Foundation
import AVFoundation
import MediaPlayer
import Observation
import SwiftData
import UIKit

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

    /// The sleep timer. Observed so the UI shows the live countdown; the player
    /// pauses when it fires.
    let sleepTimer = SleepTimerController()

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

    // Position-persistence throttle (#362). The periodic time observer fires
    // every second, but a synchronous main-actor `context.save()` every second
    // starves the run loop enough to block TabView selection while playing.
    // We instead persist position on a coarse cadence (see
    // `PlaybackLogic.shouldPersistTick`); the existing pause / seek / episode-
    // switch / session-flush paths still save eagerly so durability is intact.
    // `nil` forces the next tick to write.
    @ObservationIgnored private var lastPersistedSecond: Int?

    // Gapless preload: the next queue item is built (and starts buffering) ahead
    // of time so auto-advance is near-seamless. Invalidated whenever the queue
    // changes (via `.earshotQueueDidChange`).
    @ObservationIgnored private var preloadedItem: AVPlayerItem?
    @ObservationIgnored private var preloadedEpisode: Episode?
    @ObservationIgnored private var queueChangeObserver: NSObjectProtocol?

    // Artwork: track the last URL we fetched so we don't re-download when the
    // same episode (or a different episode with the same artwork) is loaded.
    @ObservationIgnored private var lastArtworkURL: URL?

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
        sleepTimer.onExpired = { [weak self] in self?.handleSleepTimerExpired() }
    }

    /// Pauses when a countdown sleep timer fires, with a short fade so it isn't
    /// an abrupt cut.
    private func handleSleepTimerExpired() {
        fadeOutThenPause()
        Announcer.announce("Sleep timer ended. Paused.")
    }

    private func fadeOutThenPause() {
        // A brief linear volume fade, then pause and restore volume for next time.
        let steps = 8
        let startVolume = player.volume
        for step in 0..<steps {
            let delay = Double(step) * 0.08
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.player.volume = startVolume * Float(steps - step - 1) / Float(steps)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(steps) * 0.08) { [weak self] in
            guard let self else { return }
            self.pause()
            self.player.volume = startVolume
        }
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

    /// True once a finite, positive duration is known for the loaded item. The
    /// scrubber binds its range and enabled state to this so it never receives a
    /// degenerate `0...0` range before the item reports its duration (#367).
    var hasKnownDuration: Bool { durationSeconds > 0 }

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

        // Cancel any running sleep timer when the user manually starts a new
        // episode. PRD 5.5: "timer clears when the user plays something else."
        // Both countdown and end-of-episode modes are cancelled. The cancellation
        // is announced via VoiceOver only if the timer was actually running so we
        // don't fire a spurious announcement on every episode start.
        if sleepTimer.isActive {
            sleepTimer.cancel()
            Announcer.announce("Sleep timer cancelled")
        }

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
        // Force the first tick after play to persist this episode's position.
        lastPersistedSecond = nil
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

    /// Current effective playback rate (per-podcast override or global). Readable
    /// by the UI to display e.g. "1.5×".
    var effectiveRate: Double { currentEffectiveRate }

    /// Re-applies the effective rate to the player. Call when the global speed —
    /// or the current podcast's override — changes mid-playback.
    func reapplyRate() { applyRate() }

    /// Sets the per-podcast speed override on the current episode's podcast and
    /// immediately re-applies the rate. No-op when nothing is loaded.
    /// Announces the change to VoiceOver.
    func setPodcastSpeedOverride(_ speed: Double) {
        guard let podcast = currentEpisode?.podcast else { return }
        let clamped = PlaybackLogic.clampedSpeed(speed)
        podcast.speedOverride = clamped
        saveContext()
        applyRate()
        Announcer.announce("Speed set to \(PlaybackLogic.spokenRate(clamped)) for this podcast")
    }

    /// Clears the per-podcast speed override on the current episode's podcast so
    /// global speed takes effect. No-op when nothing is loaded.
    func clearPodcastSpeedOverride() {
        guard let podcast = currentEpisode?.podcast else { return }
        podcast.speedOverride = nil
        saveContext()
        applyRate()
        let global = settings?.double(SettingsKey.globalSpeed, default: SettingsDefault.globalSpeed)
            ?? SettingsDefault.globalSpeed
        Announcer.announce("Speed reset to global \(PlaybackLogic.spokenRate(global))")
    }

    /// Sets the global playback speed in persistent settings, clears any
    /// per-podcast override on the current podcast, and immediately re-applies.
    /// Announces the change to VoiceOver.
    func setGlobalSpeed(_ speed: Double) {
        let clamped = PlaybackLogic.clampedSpeed(speed)
        settings?.setDouble(clamped, for: SettingsKey.globalSpeed)
        currentEpisode?.podcast?.speedOverride = nil
        saveContext()
        applyRate()
        Announcer.announce("Speed set to \(PlaybackLogic.spokenRate(clamped)) globally")
    }

    /// True when the currently loaded episode's podcast has a speed override set.
    var hasPodcastSpeedOverride: Bool {
        currentEpisode?.podcast?.speedOverride != nil
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

    private var voiceEnhanceEnabled: Bool {
        settings?.bool(SettingsKey.voiceEnhanceEnabled, default: false) ?? false
    }

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        let enhance = voiceEnhanceEnabled
        do {
            try session.setCategory(
                .playback,
                mode: AudioEnhancementLogic.mode(voiceEnhanceEnabled: enhance),
                options: [.allowAirPlay, .allowBluetoothHFP, .allowBluetoothA2DP]
            )
            try session.setActive(true)
            try session.setPreferredOutputNumberOfChannels(
                AudioEnhancementLogic.outputChannels(voiceEnhanceEnabled: enhance)
            )
        } catch {
            AppLog.player.error("Failed to configure audio session: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Applies the voice-enhance setting (spoken-audio mode + mono) or restores
    /// the stereo default. Call on episode load and whenever the toggle changes
    /// mid-playback (a route change can also reset the channel count). Channel
    /// count is a hint some Bluetooth routes ignore — expected, not a bug.
    func applyAudioEnhancement() {
        let session = AVAudioSession.sharedInstance()
        let enhance = voiceEnhanceEnabled
        do {
            try session.setCategory(
                .playback,
                mode: AudioEnhancementLogic.mode(voiceEnhanceEnabled: enhance),
                options: [.allowAirPlay, .allowBluetoothHFP, .allowBluetoothA2DP]
            )
            try session.setPreferredOutputNumberOfChannels(
                AudioEnhancementLogic.outputChannels(voiceEnhanceEnabled: enhance)
            )
        } catch {
            AppLog.player.error("Failed to apply audio enhancement: \(error.localizedDescription, privacy: .public)")
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

        persistPositionThrottled(currentSecond: Int(currentSeconds))
        recordListeningTick()
        updateNowPlayingElapsed()

        // Mark played once we cross the threshold.
        let duration = currentEpisode?.durationSeconds ?? (durationSeconds > 0 ? Int(durationSeconds) : nil)
        let decision = PlaybackLogic.completionDecision(position: Int(currentSeconds), duration: duration)
        if decision.shouldMarkPlayed, let episode = currentEpisode, !episode.isPlayed {
            markCurrentEpisodePlayed()
        }
    }

    /// Eagerly writes the current position to disk (used by pause, seek, episode
    /// switch — the durability anchors). Resets the per-tick throttle so the next
    /// tick doesn't redundantly re-save the same second.
    private func persistCurrentPosition() {
        guard let episode = currentEpisode, currentPositionSeconds.isFinite else { return }
        let second = Int(max(0, currentPositionSeconds))
        episode.positionSeconds = second
        lastPersistedSecond = second
        saveContext()
    }

    /// Per-tick position write, throttled to ``PlaybackLogic/positionPersistInterval``
    /// so the synchronous `context.save()` doesn't run every second and stall the
    /// main run loop (issue #362). The observed `currentPositionSeconds` and the
    /// lock-screen elapsed time still update every tick — only the SwiftData
    /// write is coarsened.
    private func persistPositionThrottled(currentSecond: Int) {
        guard let episode = currentEpisode else { return }
        guard PlaybackLogic.shouldPersistTick(
            currentSecond: currentSecond,
            lastPersistedSecond: lastPersistedSecond
        ) else { return }
        episode.positionSeconds = max(0, currentSecond)
        lastPersistedSecond = currentSecond
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
        // Force the next tick to persist this episode's first position.
        lastPersistedSecond = nil
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

        // End-of-episode sleep timer: mark this one done but stop instead of
        // auto-advancing to the next queue item.
        if sleepTimer.endOfEpisode {
            sleepTimer.episodeEnded()
            repo.markPlayedAndRemove(finished)
            finished.positionSeconds = 0
            saveContext()
            isPlaying = false
            currentEpisode = nil
            updateNowPlayingInfo()
            Announcer.announce("Sleep timer ended. Playback stopped.")
            return
        }

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
        // Preserve artwork that was already set by a prior fetch so it isn't
        // cleared by this synchronous update. The async artwork path will
        // overwrite it (or set it for the first time) when the image arrives.
        if let existing = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] {
            info[MPMediaItemPropertyArtwork] = existing
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        // Kick off an async artwork fetch for the newly loaded episode. No-ops
        // immediately when the URL matches the last successfully-fetched artwork.
        let artworkURL = currentEpisode.flatMap {
            ($0.artworkURL ?? $0.podcast?.artworkURL).flatMap(URL.init)
        }
        Task { [weak self] in await self?.updateNowPlayingArtwork(from: artworkURL) }
    }

    /// Fetches artwork for the lock screen and Control Center. Tries the system
    /// URLCache first (free if SwiftUI's AsyncImage already loaded it), then
    /// falls back to a network request. Writes the result into nowPlayingInfo
    /// without disturbing other fields.
    ///
    /// Thread-safe: the final write is dispatched back to the main actor. The
    /// `lastArtworkURL` guard prevents redundant fetches when the same episode
    /// is toggled play/pause repeatedly.
    private func updateNowPlayingArtwork(from url: URL?) async {
        guard let url else {
            // No artwork URL — clear any stale artwork from a previous episode.
            lastArtworkURL = nil
            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            info.removeValue(forKey: MPMediaItemPropertyArtwork)
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            return
        }

        // Skip the fetch when we already have artwork for this URL loaded.
        guard url != lastArtworkURL else { return }

        // Check the system URLCache. SwiftUI's AsyncImage caches responses here,
        // so artwork already visible in the UI is typically a synchronous hit.
        let request = URLRequest(url: url)
        if let cached = URLCache.shared.cachedResponse(for: request),
           let image = UIImage(data: cached.data) {
            lastArtworkURL = url
            setArtwork(image)
            return
        }

        // Cache miss: fetch from the network.
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let image = UIImage(data: data) else {
                AppLog.player.error("Artwork data from \(url, privacy: .public) could not be decoded as UIImage")
                return
            }
            lastArtworkURL = url
            setArtwork(image)
        } catch {
            AppLog.player.error("Artwork fetch failed for \(url, privacy: .public): \(error)")
        }
    }

    /// Writes `image` into `MPNowPlayingInfoCenter` without touching any other
    /// field. Safe to call after `updateNowPlayingInfo` has already run — only
    /// the artwork key is mutated.
    func setArtwork(_ image: UIImage) {
        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyArtwork] = artwork
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
