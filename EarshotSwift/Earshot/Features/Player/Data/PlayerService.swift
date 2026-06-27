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
    /// Episode ids the user explicitly chose to "Play next". Their group-boundary
    /// stop is bypassed for that one advance, so an explicit Play next always
    /// plays next even when "continue after group ends" is off (#487). In-memory:
    /// the override only matters for the immediate next advance while the app is
    /// alive; a relaunch reverts to the saved boundary setting.
    @ObservationIgnored private var playNextOverrides: Set<PersistentIdentifier> = []
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var didFinishObserver: NSObjectProtocol?
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?
    @ObservationIgnored private var routeChangeObserver: NSObjectProtocol?
    @ObservationIgnored private var remoteCommandsConfigured = false
    /// True when playback was paused by a system interruption that may resume.
    @ObservationIgnored private var pausedByInterruption = false

    /// Generation token for the sleep-timer volume fade (review P1-4). Each fade
    /// captures the current value; every queued fade step bails if it no longer
    /// matches, so a new play/resume during the ~0.6s fade can cancel the
    /// trailing `pause()` and the intermediate volume writes.
    @ObservationIgnored private var fadeGeneration = 0

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

    // Now-playing elapsed-time throttle (#412). The periodic time observer fires
    // every second, but reading and rewriting the whole cross-process
    // `MPNowPlayingInfoCenter.nowPlayingInfo` dictionary every second is a
    // sustained energy cost. The system extrapolates elapsed time from the rate
    // we set, so a periodic re-sync (see `PlaybackLogic.shouldSyncNowPlayingElapsed`)
    // is enough to correct clock drift. Every discontinuity (play / pause / seek /
    // resume / rate change) still updates now-playing eagerly and exactly, and
    // resets this to `nil` so the next tick re-anchors. `nil` forces a sync.
    @ObservationIgnored private var lastNowPlayingSyncSecond: Int?

    // Gapless preload: the next queue item is built (and starts buffering) ahead
    // of time so auto-advance is near-seamless. Invalidated whenever the queue
    // changes (via `.earshotQueueDidChange`).
    @ObservationIgnored private var preloadedItem: AVPlayerItem?
    @ObservationIgnored private var preloadedEpisode: Episode?
    @ObservationIgnored private var queueChangeObserver: NSObjectProtocol?

    // Artwork: track the last URL we fetched so we don't re-download when the
    // same episode (or a different episode with the same artwork) is loaded.
    @ObservationIgnored private var lastArtworkURL: URL?

    // Hold-to-fast-forward (4× scan, #373). While held, playback runs at 4× and
    // the prior effective rate is stashed so release restores it exactly —
    // including a per-podcast override. `nil` means not currently scanning.
    @ObservationIgnored private var rateBeforeFastForward: Double?

    /// True while a hold-to-fast-forward scan is active. Drives the UI's pressed
    /// state and the rotor action's start/stop label.
    var isFastForwarding = false

    /// One-off "stop after this episode" flag (#371). When set, the current
    /// episode plays to its natural end and then playback STOPS instead of
    /// auto-advancing to the next queue item — after which the flag clears.
    /// IN-MEMORY ONLY: it resets on app restart and after it fires, mirroring
    /// Flutter's `stopAfterCurrentEpisode` and the end-of-episode sleep timer's
    /// lifetime. Also cleared when the user plays something else.
    var stopAfterCurrentEpisode = false

    // Chapter auto-skip (#373). The set of chapter indices the user marked
    // "skip" per episode, keyed by the durable episode guid. IN-MEMORY ONLY —
    // it resets on app restart, matching Flutter's `SkippedChaptersNotifier`
    // (no SwiftData model). `currentChapters` is the chapter list the player
    // screen loaded for the current episode, supplied via `setChapters`.
    @ObservationIgnored private var skippedChapterIndices: [String: Set<Int>] = [:]
    @ObservationIgnored private var currentChapters: [Chapter] = []
    /// Resolves chapters for the loaded episode. Held so the engine can populate
    /// `currentChapters` itself on every episode load (review P1-1) rather than
    /// relying on the player-controls sheet being opened.
    @ObservationIgnored private let chapterService = ChapterService()
    /// Guards against a stale async chapter load applying to the wrong episode:
    /// the guid the most recent chapter load was started for.
    @ObservationIgnored private var chapterLoadEpisodeGUID: String?
    /// Loop guard: the chapter index we last auto-skipped *from*. We don't fire
    /// again until the active chapter moves away from it, so the seek's own
    /// position update can't restart an endless skip loop.
    @ObservationIgnored private var lastAutoSkipFromChapterIndex: Int?

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
        // A generation token lets a play/resume started during the fade cancel
        // the trailing pause (and the intermediate volume writes) — see P1-4.
        fadeGeneration &+= 1
        let generation = fadeGeneration
        let steps = 8
        let startVolume = player.volume
        for step in 0..<steps {
            let delay = Double(step) * 0.08
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.fadeGeneration == generation else { return }
                self.player.volume = startVolume * Float(steps - step - 1) / Float(steps)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(steps) * 0.08) { [weak self] in
            guard let self, self.fadeGeneration == generation else { return }
            self.pause()
            self.player.volume = startVolume
        }
    }

    /// Cancels any in-flight sleep-timer fade and restores full volume, so a new
    /// play/resume during the fade is neither paused by the trailing closure nor
    /// left quiet by a mid-fade volume write (review P1-4). Volume is otherwise
    /// only ever touched by the fade, so 1.0 is the correct baseline.
    private func cancelFadeIfNeeded() {
        fadeGeneration &+= 1
        if player.volume != 1.0 { player.volume = 1.0 }
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

        // A new episode supersedes any in-flight sleep-timer fade (P1-4).
        cancelFadeIfNeeded()

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

        // A new episode invalidates the loaded chapter list, the auto-skip loop
        // guard, and any in-progress fast-forward scan. The skipped-chapter map
        // is keyed by guid so it survives the switch (and still resets on app
        // restart, which is the intended lifetime).
        currentChapters = []
        lastAutoSkipFromChapterIndex = nil
        isFastForwarding = false
        rateBeforeFastForward = nil
        // Playing something else clears the one-off stop-after flag (mirrors the
        // sleep timer behaviour above). Announce only if it was actually set so
        // we don't fire a spurious announcement on every episode start.
        if stopAfterCurrentEpisode {
            stopAfterCurrentEpisode = false
            Announcer.announce("Stop after this episode cancelled")
        }

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
        loadChaptersForCurrentEpisode()
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
        // Like the play() path, switching the loaded episode invalidates the
        // chapter list, the auto-skip loop guard, and any fast-forward scan.
        currentChapters = []
        lastAutoSkipFromChapterIndex = nil
        isFastForwarding = false
        rateBeforeFastForward = nil

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
        loadChaptersForCurrentEpisode()
    }

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    func resume() {
        guard currentEpisode != nil else { return }
        // Resuming during a sleep-timer fade supersedes it (P1-4).
        cancelFadeIfNeeded()
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
        // While a fast-forward scan is active, the scan rate wins; the prior rate
        // is restored by `endFastForward`.
        let rate = isFastForwarding ? ChapterSkipLogic.fastForwardRate : currentEffectiveRate
        // Setting `rate` also starts playback; only apply when we intend to play.
        if isPlaying || player.timeControlStatus == .playing {
            player.rate = Float(rate)
            // A rate change is a discontinuity for the lock screen's elapsed-time
            // extrapolation: push the new rate (and exact elapsed) immediately so
            // the now-playing throttle (#412) doesn't leave it stale for up to a
            // full sync interval.
            updateNowPlayingElapsed()
            lastNowPlayingSyncSecond = nil
        } else {
            player.rate = 0
            // Stash the desired rate so the next play() uses it via defaultRate.
            player.defaultRate = Float(rate)
        }
    }

    // MARK: Public — hold-to-fast-forward (4× scan, #373)

    /// True when the VoiceOver rotor "Start/Stop Fast Forward" action should be
    /// offered. The sighted press-and-hold gesture on the artwork is always
    /// available; the rotor action is gated on the Direct Touch setting because
    /// that's where Flutter exposes it (a direct-touch playback affordance).
    var fastForwardRotorAvailable: Bool {
        settings?.bool(SettingsKey.directTouchEnabled, default: false) ?? false
    }

    /// Raises playback to the 4× scan rate, stashing the exact prior effective
    /// rate (including any per-podcast override) so release restores it. No-op
    /// when nothing is loaded or a scan is already running. Announces the start.
    func beginFastForward() {
        guard currentEpisode != nil, !isFastForwarding else { return }
        rateBeforeFastForward = currentEffectiveRate
        isFastForwarding = true
        // Ensure audio is actually moving so the scan is audible / progresses.
        if !isPlaying {
            resume()
        }
        applyRate()
        Announcer.announce("Fast forward at 4 times speed")
    }

    /// Restores the exact rate from before the scan and stops fast-forwarding.
    /// No-op when no scan is active. Announces the stop.
    func endFastForward() {
        guard isFastForwarding else { return }
        isFastForwarding = false
        rateBeforeFastForward = nil
        applyRate()
        Announcer.announce("Fast forward stopped")
    }

    // MARK: Public — episode actions (#371)

    /// Toggles the one-off "stop after this episode" flag and announces the new
    /// state. Returns the resulting state. The flag is honoured at the natural
    /// end of the current episode in ``handlePlaybackEnded`` and clears after it
    /// fires, on app restart, or when the user plays something else.
    @discardableResult
    func toggleStopAfterEpisode() -> Bool {
        stopAfterCurrentEpisode.toggle()
        Announcer.announce(stopAfterCurrentEpisode
            ? "Will stop after this episode"
            : "Stop after this episode cancelled")
        return stopAfterCurrentEpisode
    }

    /// Records that the user explicitly chose to "Play next" `episode`, so the
    /// group-end boundary won't stop auto-advance from reaching it (#487). Prunes
    /// ids that have since left the queue so the set can't grow unbounded.
    func registerPlayNext(_ episode: Episode) {
        playNextOverrides.insert(episode.persistentModelID)
        if let context {
            let live = Set(QueueRepository(context: context).queue().map(\.persistentModelID))
            playNextOverrides.formIntersection(live)
        }
    }

    /// The next episode to auto-advance to after `finished`, honoring the
    /// boundary settings — except an episode the user explicitly "Play next"-ed
    /// bypasses the group-end stop (#487). Returns nil to STOP.
    private func nextAdvanceID(after finished: Episode, in queued: [Episode]) -> PersistentIdentifier? {
        let continueEpisode = settings?.bool(
            SettingsKey.continueAfterEpisode, default: SettingsDefault.continueAfterEpisode
        ) ?? SettingsDefault.continueAfterEpisode
        let groupSetting = settings?.bool(
            SettingsKey.continueAfterGroupEnds, default: SettingsDefault.continueAfterGroupEnds
        ) ?? SettingsDefault.continueAfterGroupEnds
        let candidate = PlaybackLogic.nextUpID(
            queue: queued.map(\.persistentModelID), after: finished.persistentModelID
        )
        return PlaybackLogic.nextUpHonoringBoundaries(
            queue: queued.map { (id: $0.persistentModelID, groupKey: $0.podcast?.persistentModelID) },
            after: finished.persistentModelID,
            currentGroupKey: finished.podcast?.persistentModelID,
            continueAfterEpisode: continueEpisode,
            continueAfterGroupEnds: PlaybackLogic.continueAfterGroupEnds(
                setting: groupSetting, nextCandidate: candidate, playNextOverrides: playNextOverrides
            )
        )
    }

    /// Manual "mark as played" for the loaded episode: marks it played, removes
    /// it from the queue, and advances to the next queue item WITHOUT playing the
    /// current one to the end. Distinct from the automatic 95% mark in
    /// ``handleTick``. No-op when nothing is loaded. Announces the result.
    func markCurrentPlayedAndAdvance() {
        guard let finished = currentEpisode, let context else { return }

        flushListeningSession()
        let repo = QueueRepository(context: context)

        let queued = repo.queue()
        let nextID = nextAdvanceID(after: finished, in: queued)
        let nextEpisode = queued.first { $0.persistentModelID == nextID }

        repo.markPlayedAndRemove(finished)
        finished.positionSeconds = 0
        saveContext()
        Announcer.announce("Marked as played")

        guard let nextEpisode else {
            // Nothing queued after this one: stop cleanly with the bar cleared.
            pause()
            isPlaying = false
            currentEpisode = nil
            updateNowPlayingInfo()
            return
        }

        let prepared = preloadedEpisode?.persistentModelID == nextEpisode.persistentModelID
            ? preloadedItem : nil
        preloadedItem = nil
        preloadedEpisode = nil
        play(nextEpisode, preparedItem: prepared)
        Announcer.announce("Now playing \(nextEpisode.title)")
    }

    /// True when the loaded episode's audio is available as a local file (already
    /// downloaded). Drives whether "Export audio file" shares immediately or has
    /// to download first.
    var currentEpisodeIsDownloaded: Bool {
        guard let path = currentEpisode?.downloadPath, !path.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    /// Exports the loaded episode's LOCAL audio file for sharing (#371, #401).
    ///
    /// Downloads the episode first when it isn't already local, then copies the
    /// local file to a temporary file named "Podcast name - Episode title" so the
    /// share sheet presents a human-readable filename. Returns the temporary file
    /// URL to hand to the OS share sheet, or `nil` on failure (logged via
    /// `AppLog`). NEVER returns the remote enclosure URL — the share is always
    /// the on-disk audio.
    func exportCurrentEpisodeAudio(using downloads: DownloadManager) async -> URL? {
        guard let episode = currentEpisode else { return nil }

        // Ensure the file is local first. download() is a no-op when already
        // downloaded; otherwise it writes downloadPath / downloadStatus.
        if !currentEpisodeIsDownloaded {
            await downloads.download(episode)
        }

        guard let path = episode.downloadPath, !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else {
            AppLog.player.error("Export failed: no local file for \(episode.title, privacy: .public)")
            return nil
        }

        let localURL = URL(fileURLWithPath: path)
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

    // MARK: Public — chapter auto-skip (#373)

    /// Supplies the current episode's chapter list to the engine so auto-skip can
    /// evaluate the active chapter on each tick. Called by the player screen once
    /// chapters are loaded. Clears the loop guard so a fresh list starts clean.
    func setChapters(_ chapters: [Chapter]) {
        currentChapters = chapters
        lastAutoSkipFromChapterIndex = nil
    }

    /// Resolves and installs the loaded episode's chapters in the engine so
    /// auto-skip works on every episode, not only after the player-controls
    /// sheet has been opened (review P1-1). Only Sendable strings cross the
    /// async boundary — the `@Model` stays on the main actor — and the result is
    /// discarded if the user switched episodes while it loaded. The
    /// controls-sheet `setChapters` path still applies (idempotent; same list).
    private func loadChaptersForCurrentEpisode() {
        guard let episode = currentEpisode else { return }
        let guid = episode.guid
        let chapterURL = episode.chapterURL
        let audioURL = episode.audioURL
        let descriptionHTML = episode.episodeDescription
        chapterLoadEpisodeGUID = guid
        Task { @MainActor [weak self] in
            guard let self else { return }
            let found = await self.chapterService.chapters(
                chapterURL: chapterURL,
                audioURL: audioURL,
                descriptionHTML: descriptionHTML
            )
            // Drop a stale load: only apply if this is still the loaded episode
            // and no newer load has superseded us.
            guard self.chapterLoadEpisodeGUID == guid,
                  self.currentEpisode?.guid == guid else { return }
            self.currentChapters = found
            self.lastAutoSkipFromChapterIndex = nil
        }
    }

    /// Whether `chapter` is currently marked skipped for the loaded episode.
    func isChapterSkipped(_ chapter: Chapter) -> Bool {
        guard let key = currentEpisode?.guid else { return false }
        return skippedChapterIndices[key]?.contains(chapter.index) ?? false
    }

    /// Toggles the skipped state of `chapter` for the loaded episode (in-memory,
    /// resets on restart). Returns the new state. Announces the change so the
    /// VoiceOver user hears the result of activating the control.
    @discardableResult
    func toggleChapterSkipped(_ chapter: Chapter) -> Bool {
        guard let key = currentEpisode?.guid else { return false }
        var set = skippedChapterIndices[key] ?? []
        let nowSkipped: Bool
        if set.contains(chapter.index) {
            set.remove(chapter.index)
            nowSkipped = false
        } else {
            set.insert(chapter.index)
            nowSkipped = true
        }
        skippedChapterIndices[key] = set
        Announcer.announce(nowSkipped
            ? "Will skip chapter: \(chapter.title)"
            : "Will play chapter: \(chapter.title)")
        return nowSkipped
    }

    /// Evaluates the active chapter against the skipped set and, when the active
    /// chapter is skipped, seeks to the start of the next non-skipped chapter (or
    /// ends the episode if none remain). The loop guard ensures the seek's own
    /// position update doesn't re-trigger the same boundary.
    private func evaluateChapterAutoSkip() {
        guard let key = currentEpisode?.guid,
              let skipped = skippedChapterIndices[key], !skipped.isEmpty,
              !currentChapters.isEmpty else { return }

        let activeIndex = currentChapters.activeChapterIndex(at: currentPositionSeconds)

        // Reset the guard once we've moved into a chapter we won't skip, so a
        // later return to a skipped chapter can fire again.
        if let activeIndex, !skipped.contains(activeIndex) {
            lastAutoSkipFromChapterIndex = nil
        }

        guard ChapterSkipLogic.shouldAutoSkip(
            activeIndex: activeIndex,
            skipped: skipped,
            lastAutoSkipFromIndex: lastAutoSkipFromChapterIndex
        ) else { return }

        lastAutoSkipFromChapterIndex = activeIndex

        switch ChapterSkipLogic.decision(
            chapters: currentChapters,
            skipped: skipped,
            activeIndex: activeIndex
        ) {
        case .none:
            break
        case let .seek(_, startTime, targetTitle):
            seek(to: startTime)
            Announcer.announce("Skipping chapter: \(targetTitle)")
        case .endOfEpisode:
            handlePlaybackEnded()
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
        updateNowPlayingElapsedThrottled(currentSecond: Int(currentSeconds))
        evaluateChapterAutoSkip()

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

        // Stop-after-this-episode (#371): the natural end of the current episode
        // marks it played and removes it from the queue, then STOPS instead of
        // auto-advancing. The one-off flag clears so the next episode (started
        // manually) advances normally again.
        if EpisodeExportLogic.shouldStopAfterCurrent(stopAfterCurrentEpisode: stopAfterCurrentEpisode) {
            stopAfterCurrentEpisode = false
            repo.markPlayedAndRemove(finished)
            finished.positionSeconds = 0
            saveContext()
            isPlaying = false
            currentEpisode = nil
            updateNowPlayingInfo()
            Announcer.announce("Stopped after this episode")
            return
        }

        let queued = repo.queue()
        let nextID = nextAdvanceID(after: finished, in: queued)
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
        // We're advancing to it now, so its Play-next override is spent.
        playNextOverrides.remove(nextEpisode.persistentModelID)

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
        let nextID = nextAdvanceID(after: current, in: queued)
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

        // This is a discontinuity write (play / pause / seek / resume): the elapsed
        // time and rate are now exact, so re-anchor the per-tick throttle (#412) and
        // let the next tick re-sync `nowPlayingElapsedSyncInterval` seconds later.
        lastNowPlayingSyncSecond = nil

        // Kick off an async artwork fetch for the newly loaded episode. No-ops
        // immediately when the URL matches the last successfully-fetched artwork.
        let artworkURL = currentEpisode.flatMap {
            ($0.artworkURL ?? $0.podcast?.artworkURL).flatMap(URL.init)
        }
        Task { [weak self] in await self?.updateNowPlayingArtwork(from: artworkURL) }
    }

    /// Fetches artwork for the lock screen and Control Center through the shared
    /// disk-backed ``ArtworkCache`` — the same cache that ``PodcastArtwork`` uses
    /// in the UI (#378/#385), so artwork already loaded for a screen is a cache
    /// hit here (and survives relaunch). Writes the result into nowPlayingInfo
    /// without disturbing other fields.
    ///
    /// Thread-safe: ``ArtworkCache`` is `Sendable`; the final write happens on
    /// the main actor (this method is `@MainActor`-isolated). The `lastArtworkURL`
    /// guard prevents redundant fetches when the same episode is toggled
    /// play/pause repeatedly.
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

        // ArtworkCache serves from its disk cache when present and fetches
        // (then caches) otherwise; it returns nil instead of throwing on failure.
        guard let image = await ArtworkCache.shared.image(
            for: url,
            maxPixelSize: ArtworkCache.nowPlayingMaxPixelSize
        ) else { return }
        lastArtworkURL = url
        setArtwork(image)
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

    /// Per-tick entry point for the lock-screen elapsed time, throttled to
    /// ``PlaybackLogic/nowPlayingElapsedSyncInterval`` (#412). Reading and
    /// rewriting the cross-process `nowPlayingInfo` dictionary every second is a
    /// sustained energy cost; the system extrapolates elapsed time from the rate
    /// we set, so a coarser re-sync only corrects clock drift. Discontinuities
    /// reset the throttle via ``updateNowPlayingInfo`` so they update immediately.
    private func updateNowPlayingElapsedThrottled(currentSecond: Int) {
        guard PlaybackLogic.shouldSyncNowPlayingElapsed(
            currentSecond: currentSecond,
            lastSyncedSecond: lastNowPlayingSyncSecond
        ) else { return }
        lastNowPlayingSyncSecond = currentSecond
        updateNowPlayingElapsed()
    }

    /// Writes just the moving fields (elapsed time, rate, duration) into
    /// `nowPlayingInfo` without disturbing the title/artist/artwork.
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

        updateRemoteSkipIntervals()
        center.skipForwardCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.skipForward()
            return .success
        }
        center.skipBackwardCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.skipBack()
            return .success
        }

        // Earbuds (AirPods double/triple-press, wired EarPods, BT/AVRCP) send
        // next-/previous-track, NOT the interval skip command — so without these
        // handlers an earbud skip does nothing (#474). Map them to the same
        // interval skip as everything else so an earbud press jumps within the
        // episode by the user's configured amount, matching the in-app and
        // lock-screen skip buttons. The skipForward/Backward commands above stay
        // registered so the lock-screen skip arrows keep working.
        center.nextTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.skipForward()
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
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

    /// Pushes the current skip-interval settings to the lock-screen / Control
    /// Center skip buttons. Called once at launch and again whenever the skip
    /// interval changes in Settings, so the remote buttons seek by the same
    /// amount as in-app skips (review P1-5).
    func updateRemoteSkipIntervals() {
        let center = MPRemoteCommandCenter.shared()
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: skipForwardSeconds)]
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: skipBackSeconds)]
    }
}
