import Foundation
import AVFoundation
import MediaPlayer
import Observation
import SwiftData
import UIKit

extension Notification.Name {
    /// Posted immediately BEFORE persisted episodes are deleted out from under
    /// the player (#574). Posters include:
    /// `SubscriptionRepository.unsubscribe` includes the doomed podcast's
    /// `PersistentIdentifier` under ``PlayerService/willDeletePodcastIDKey``;
    /// the Settings factory reset posts with no userInfo, meaning "everything";
    /// identity repair includes the exact duplicate episode identifiers. The
    /// player observes on the main queue, and NotificationCenter waits for that
    /// handler before the caller's `context.delete` executes.
    static let earshotWillDeleteEpisodes = Notification.Name("earshotWillDeleteEpisodes")
}

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
    @ObservationIgnored private var startupRestorationCompleted = false

    /// Startup maintenance may finish after a remote command or manual play.
    /// Claim restoration once so that late startup cannot pause or resurrect it.
    func beginStartupRestoration() -> Bool {
        guard !startupRestorationCompleted else { return false }
        startupRestorationCompleted = true
        return currentEpisode == nil
    }

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
    /// Persistent, non-modal playback failure surfaced by Now Playing. It stays
    /// available after the one automatic recovery attempt so VoiceOver users do
    /// not have to catch a transient announcement.
    private(set) var playbackFailureMessage: String?

    /// Title of the active chapter for the loaded episode (#508). `nil` when the
    /// episode has no chapters or playback is before the first chapter starts.
    /// Updated from the per-tick handler, but only when the active chapter index
    /// actually changes (so it doesn't thrash `@Observable` every tick). The
    /// chapter ENGINE still reads the private `currentChapters`; this is the
    /// observable surface the UI binds to.
    var currentChapterTitle: String?
    /// Index of the active chapter, paired with ``currentChapterTitle``. `nil`
    /// under the same conditions. Manual previous/next navigate relative to this.
    var currentChapterIndex: Int?
    /// Number of chapters loaded for the current episode (0 when none). Observable
    /// so the UI can decide whether to show the chapter line and prev/next
    /// controls without reaching into the private `currentChapters`.
    var chapterCount: Int = 0

    /// `nil` means this episode follows the device-wide default. Kept observed
    /// so the player sheet updates immediately after a VoiceOver adjustment.
    private(set) var currentVolumeBoostOverride: VolumeBoostLevel?

    var effectiveVolumeBoost: VolumeBoostLevel {
        currentVolumeBoostOverride ?? settings?.volumeBoost() ?? SettingsDefault.volumeBoost
    }

    var effectiveSilenceTrimming: Bool {
        currentEpisode?.podcast?.trimSilenceOverride
            ?? settings?.bool(SettingsKey.skipSilenceEnabled, default: SettingsDefault.skipSilenceEnabled)
            ?? SettingsDefault.skipSilenceEnabled
    }

    /// Set true when a user-initiated "Play now" should also open the full player
    /// screen (#562), gated on the `openPlayerOnPlay` setting. RootView — the
    /// single instance above all five inset mini bars — binds a sheet to this and
    /// clears it on dismiss. Only the row "Play now" path sets it; queue
    /// auto-advance and resume use `play(_:)` directly and never raise the player.
    var pendingFullPlayerPresentation = false

    /// Changes only when a natural item completion leaves nothing to play next.
    /// RootView observes this one-shot event to optionally dismiss the full
    /// player. Pause, seek, interruption, buffering, sleep-timer stops,
    /// stop-after-current, and successful queue auto-advance never write it.
    private(set) var completedPlaybackStopID: UUID?

    /// Session-local source context for the current playback run (folders phase
    /// 4). Identity-only and never persisted: Now Playing resolves the live
    /// folder name/path, while every source/advance/stop transition runs through
    /// ``PlaybackLogic/playbackOrigin(after:current:)`` so stale context cannot
    /// follow an unrelated episode.
    private(set) var playbackOrigin: PlaybackOrigin?
    let folderRuns = FolderRunController()

    /// Identity of the loaded episode, mirrored from ``currentEpisode`` at every
    /// assignment via ``setCurrentEpisode(_:)``. Unlike ``currentEpisode`` (which
    /// is `@ObservationIgnored`, so views never re-render off it), this is an
    /// observed surface: list rows read it to show a "Now Playing" badge and
    /// re-render when the loaded episode changes. `nil` when nothing is loaded.
    private(set) var nowPlayingEpisodeID: PersistentIdentifier?

    /// The sleep timer. Observed so the UI shows the live countdown; the player
    /// pauses when it fires.
    let sleepTimer = SleepTimerController()

    // MARK: Private engine state

    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private let playbackHandoff: any PlaybackHandoffClient
    /// A direct handoff fetch is bounded and cancellable. A new transport action
    /// supersedes the old request so a late response can never seek the wrong
    /// episode or start audio after the user has paused again.
    @ObservationIgnored private var playbackHandoffTask: Task<Void, Never>?
    @ObservationIgnored private var playbackHandoffGeneration = 0
    /// Generation-protected user seek. AVPlayer seeks asynchronously, so the
    /// periodic clock must not publish the pre-seek time while the request is in
    /// flight. Repeated skips replace the pending request while continuing to
    /// accumulate from the optimistic target shown to the listener.
    @ObservationIgnored private var userSeekGeneration = 0
    @ObservationIgnored private var pendingUserSeekTarget: Double?
    /// Session-only exact rate received with a handoff. It takes precedence for
    /// the loaded episode without rewriting the user's global/per-show settings;
    /// any deliberate local speed change clears it.
    @ObservationIgnored private var handoffRateOverride: Double?
    @ObservationIgnored private var context: ModelContext?
    @ObservationIgnored private var settings: AppSettingsStore?
    @ObservationIgnored private var currentEpisode: Episode?
    /// True when ``currentEpisode`` is a transient, NON-inserted ``Episode`` built
    /// for a stream-only Search directory preview (#517). While set, every
    /// persistence sink (position, played, listening sessions, last-playing) is a
    /// no-op so a preview stream never pollutes the store. Cleared the moment a
    /// real episode is played or loaded, restoring full persistence.
    @ObservationIgnored private var currentEpisodeIsTransient = false
    /// Episode ids the user explicitly chose to "Play next". Their group-boundary
    /// stop is bypassed for that one advance, so an explicit Play next always
    /// plays next even when "continue after group ends" is off (#487). In-memory:
    /// the override only matters for the immediate next advance while the app is
    /// alive; a relaunch reverts to the saved boundary setting.
    @ObservationIgnored private var playNextOverrides: Set<PersistentIdentifier> = []
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var timeObserverMediaInterval: Double?
    @ObservationIgnored private var didFinishObserver: NSObjectProtocol?
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?
    @ObservationIgnored private var routeChangeObserver: NSObjectProtocol?
    /// Observer for `.earshotWillDeleteEpisodes` (#574): the pre-delete hook
    /// that lets the player release a doomed episode before it is deleted.
    @ObservationIgnored private var deletionObserver: NSObjectProtocol?
    /// Clears a folder playback origin when its backing folder (or containing
    /// deleted subtree) is removed through FolderRepository.
    @ObservationIgnored private var folderDeletionObserver: NSObjectProtocol?
    /// Refreshes the in-memory playback position and per-podcast rate after
    /// CloudKit applies newer projections through another SwiftData context.
    @ObservationIgnored private var cloudProjectionObserver: NSObjectProtocol?
    @ObservationIgnored private var volumeBoostSettingObserver: NSObjectProtocol?
    @ObservationIgnored private var skipSilenceSettingObserver: NSObjectProtocol?
    @ObservationIgnored private var audioProcessingGeneration = 0
    @ObservationIgnored private var currentAudioProcessingMetrics: AudioProcessingMetrics?
    @ObservationIgnored private var silenceTrimmedSecondsThisSession = 0.0
    /// One-shot flag for the deleted-instance guard log (#574) so a tick storm
    /// against a deleted episode doesn't spam the log. Reset on episode load.
    @ObservationIgnored private var didLogDeletedEpisodeGuard = false
    @ObservationIgnored private var remoteCommandsConfigured = false
    /// True when playback was paused by a system interruption that may resume.
    @ObservationIgnored private var pausedByInterruption = false

    /// The user's playback intent (#522), independent of whether audio is
    /// momentarily moving. `true` after play/resume, `false` after a deliberate
    /// or interruption pause. The stall-recovery observers only auto-resume when
    /// this is `true`, so a deliberate pause is never overridden. Distinct from
    /// `isPlaying`, which a silent buffer stall leaves untouched — that's exactly
    /// the window where we want to recover.
    @ObservationIgnored private var intendsToPlay = false

    // Streaming stall resilience (#522). With no buffer/stall observers a
    // streamed item whose buffer empties leaves AVPlayer paused with nothing to
    // re-issue play(), so the user has to manually resume and the radio thrashes
    // through repeated rebuffering (the reported overheating). We watch the
    // player's `timeControlStatus`, the item's buffer KVO, and the stall
    // notification, and re-issue play() via `StallRecoveryLogic` once the buffer
    // recovers AND the user still intends playback. KVO tokens auto-invalidate on
    // dealloc; the per-item tokens are invalidated whenever the item is replaced.
    @ObservationIgnored private var timeControlObservation: NSKeyValueObservation?
    @ObservationIgnored private var bufferEmptyObservation: NSKeyValueObservation?
    @ObservationIgnored private var likelyToKeepUpObservation: NSKeyValueObservation?
    @ObservationIgnored private var itemStatusObservation: NSKeyValueObservation?
    @ObservationIgnored private var stallObserver: NSObjectProtocol?
    @ObservationIgnored private var failedToEndObserver: NSObjectProtocol?

    @ObservationIgnored private let audioSession: any PlayerAudioSession
    @ObservationIgnored private let mediaHTTPSProbe: any MediaHTTPSProbing
    @ObservationIgnored private let mediaRecoveryFeed: any FeedFetching
    @ObservationIgnored private var mediaRecoveryAttemptedEpisodeID: PersistentIdentifier?
    @ObservationIgnored private var mediaRecoveryInProgressEpisodeID: PersistentIdentifier?
    @ObservationIgnored private var mediaRecoveryGeneration = 0
    @ObservationIgnored private var mediaResolutionGeneration = 0
    @ObservationIgnored private var pendingCleartextPlaybackAction: (() -> Void)?
    @ObservationIgnored private var pendingCleartextApprovalKey: String?
    @ObservationIgnored private var currentPlaybackURL: URL?
    @ObservationIgnored private var currentMediaResolutionComplete = true

    /// Non-nil only after the HTTPS probe proved that the selected episode must
    /// use cleartext HTTP and this device has not approved that podcast (#709).
    private(set) var pendingCleartextPlaybackWarning: CleartextPlaybackWarning?

    init(
        playbackHandoff: any PlaybackHandoffClient = PlaybackHandoffClientFactory.make(),
        audioSession: any PlayerAudioSession = AVAudioSession.sharedInstance(),
        mediaHTTPSProbe: any MediaHTTPSProbing = MediaHTTPSProbe(),
        mediaRecoveryFeed: any FeedFetching = FeedService()
    ) {
        self.playbackHandoff = playbackHandoff
        self.audioSession = audioSession
        self.mediaHTTPSProbe = mediaHTTPSProbe
        self.mediaRecoveryFeed = mediaRecoveryFeed
    }

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
    // Flush every 5 minutes (was 30s) so a long continuous listen isn't doing a
    // `context.save()` — and the resulting large-library `@Query` invalidation —
    // twice a minute while playing (#736). Pause / stop / episode switch /
    // background still flush, so at most ~5 min of stats is at risk on a crash.
    @ObservationIgnored private let sessionFlushSeconds: Double = 300

    // Position-persistence throttle (#362). The periodic time observer fires
    // every second, but a synchronous main-actor `context.save()` every second
    // starves the run loop enough to block TabView selection while playing.
    // We instead persist position on a coarse cadence (see
    // `PlaybackLogic.shouldPersistTick`); the existing pause / seek / episode-
    // switch / session-flush paths still save eagerly so durability is intact.
    // `nil` forces the next tick to write.
    @ObservationIgnored private var lastPersistedSecond: Int?

    // The application store deliberately stays untouched during uninterrupted
    // playback (#736). Publish one relationship-free projection row on a bounded
    // wall-clock cadence so another device can receive progress even before the
    // next pause/background anchor, without re-materializing the local library.
    @ObservationIgnored private var lastProjectedSecond: Int = 0

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
        recordPlaybackDiagnostic("configure")
        self.context = context
        self.settings = AppSettingsStore(context: context)
        configureRemoteCommands()
        observeNotifications()
        observePeriodicTime()
        observeItemDidPlayToEnd()
        observeQueueChanges()
        observeStallRecovery()
        observeVolumeBoostSetting()
        observeSkipSilenceSetting()
        sleepTimer.onExpired = { [weak self] in self?.handleSleepTimerExpired() }
    }

    /// Drops the old model context after the synchronous reset notification has
    /// unloaded playback and before the store files are moved.
    func releasePersistence() {
        startupRestorationCompleted = false
        cancelHandoffOperation()
        context = nil
        settings = nil
    }

    func playFolderRunEpisode(_ episode: Episode, origin: PlaybackOrigin?, autoplay: Bool) {
        clearPreload()
        if autoplay, nowPlayingEpisodeID == episode.persistentModelID,
           player.currentItem != nil, player.currentItem?.status != .failed, playbackFailureMessage == nil {
            playbackOrigin = origin
            // Resuming the same item retains one-off stop flags and transport
            // state. A failed item must instead be rebuilt by the retry below.
            resume(providesStartHaptic: true)
        } else if autoplay {
            beginUserMediaAttempt()
            play(episode, preparedItem: nil, originEvent: .started(origin))
        } else {
            load(episode, autoplay: false)
            playbackOrigin = origin
        }
    }

    func finishFolderEpisode(_ episode: Episode) -> Bool {
        guard let context else { return false }
        pause(providesPauseHaptic: false, folderRunInternal: true)
        guard QueueRepository(context: context).markPlayedAndRemove(episode) else { return false }
        episode.positionSeconds = 0
        return saveContext()
    }

    func clearFolderRunPresentation() { clearNowPlayingPresentation() }

    func resumeOrdinaryQueueAfterFolderRun() {
        guard let context else { return }
        let queued = QueueRepository(context: context).queue().filter { !$0.isPlayed }
        guard settings?.bool(SettingsKey.continueAfterEpisode, default: SettingsDefault.continueAfterEpisode) != false,
              let id = displayedQueuePairs(queued).first?.id,
              let next = queued.first(where: { $0.persistentModelID == id }) else {
            clearNowPlayingPresentation()
            return
        }
        play(next, preparedItem: nil, originEvent: .started(nil), automaticallyAdvancing: true)
    }

    /// Pauses when a countdown sleep timer fires, with a short fade so it isn't
    /// an abrupt cut.
    private var automaticPlaybackStoppedByTimer = false

    private func handleSleepTimerExpired() {
        automaticPlaybackStoppedByTimer = true
        beginMediaResolution()
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
            self.pause(providesPauseHaptic: false)
            self.player.volume = startVolume
        }
    }

    /// Cancels any in-flight sleep-timer fade and restores full volume, so a new
    /// play/resume during the fade is neither paused by the trailing closure nor
    /// left quiet by a mid-fade volume write (review P1-4). Volume is otherwise
    /// only ever touched by the fade, so 1.0 is the correct baseline.
    private func cancelFadeIfNeeded() {
        automaticPlaybackStoppedByTimer = false
        fadeGeneration &+= 1
        if player.volume != 1.0 { player.volume = 1.0 }
    }

    // MARK: Public playback API

    /// Loads and starts playing an episode. Resumes from its saved position;
    /// only actual playback completion or an explicit action marks it played.
    func play(_ episode: Episode) {
        beginUserMediaAttempt()
        cancelHandoffOperation()
        play(episode, preparedItem: nil, originEvent: .started(nil))
    }

    /// User-initiated start that does not alter queue membership or presentation.
    /// Notification actions use this path; automatic queue advance uses `play(_:)`
    /// so consecutive playback never waits on the network.
    func playWithHandoff(_ episode: Episode) {
        folderRuns.playbackWillStart(episode)
        beginUserMediaAttempt()
        playAfterFetchingHandoff(
            episode,
            originEvent: .started(nil),
            providesStartHaptic: true
        )
    }

    /// Plays `episode` from a user tap on an episode row (the "Play now" default
    /// Quick Action). Same as ``play(_:)`` but also raises the full player when the
    /// `openPlayerOnPlay` setting is on (#562), and queues the episode first if it
    /// isn't already (#612) -- an episode started this way from the Inbox or a
    /// podcast's episode list previously kept `status == .newEpisode` for its
    /// entire playback, so it stayed visibly "in the Inbox" (untriaged) the whole
    /// time despite already playing. `QueueRepository.add(_:)` is idempotent (a
    /// no-op when already queued, e.g. Library binge already queued every episode,
    /// or the episode was played from the Queue screen itself), so this is safe
    /// for every caller. Kept distinct from ``play(_:)`` so only this deliberate,
    /// user-initiated path queues and can present the player — queue auto-advance,
    /// resume, and jump-to-bookmark never do either.
    func playFromEpisodeList(_ episode: Episode, origin: PlaybackOrigin? = nil) {
        folderRuns.playbackWillStart(episode)
        beginUserMediaAttempt()
        if let context {
            QueueRepository(context: context).add(episode)
        }
        let delaysPresentationForHTTP = episode.localAudioURL == nil
            && URL(string: episode.audioURL)?.scheme?.lowercased() == "http"
        playAfterFetchingHandoff(
            episode,
            originEvent: .started(origin),
            presentsFullPlayerWhenStarted: delaysPresentationForHTTP,
            providesStartHaptic: true
        )
        if !delaysPresentationForHTTP,
           settings?.bool(SettingsKey.openPlayerOnPlay, default: SettingsDefault.openPlayerOnPlay)
            ?? SettingsDefault.openPlayerOnPlay {
            pendingFullPlayerPresentation = true
        }
    }

    /// The currently loaded episode, if any. Exposed read-only for features that
    /// act on the current item — e.g. bookmarking the current position.
    var nowPlayingEpisode: Episode? { currentEpisode }

    /// Internal verification surface for the transport selected after #709's
    /// HTTPS probe. The URL is never persisted or included in diagnostics.
    var currentMediaURLForTesting: URL? { currentPlaybackURL }

    /// Sole writer of ``currentEpisode``. Sets the (`@ObservationIgnored`) episode
    /// and mirrors its identity into the observed ``nowPlayingEpisodeID`` so the
    /// two can never drift. Every assignment — loads and every clear path,
    /// including the #574 pre-delete release — routes through here; a mirror left
    /// stale would show "Now Playing" on a cleared or deleted episode's row.
    private func setCurrentEpisode(_ episode: Episode?) {
        if currentEpisode !== episode {
            invalidatePendingUserSeek()
        }
        currentEpisode = episode
        nowPlayingEpisodeID = episode?.persistentModelID
        if let episode, let context, !currentEpisodeIsTransient {
            currentVolumeBoostOverride = LocalStateStore.volumeBoost(for: episode, in: context)
        } else {
            currentVolumeBoostOverride = nil
        }
    }

    func setCurrentVolumeBoostOverride(_ level: VolumeBoostLevel?) {
        guard let episode = currentEpisode, let context, !currentEpisodeIsTransient else { return }
        LocalStateStore.setVolumeBoost(level, on: episode, in: context)
        currentVolumeBoostOverride = level
        if let item = player.currentItem { applyAudioProcessing(to: item) }
    }

    /// True once a finite, positive duration is known for the loaded item. The
    /// scrubber binds its range and enabled state to this so it never receives a
    /// degenerate `0...0` range before the item reports its duration (#367).
    var hasKnownDuration: Bool { durationSeconds > 0 }

    /// Plays `episode` and jumps to an explicit start position. Backs
    /// jump-to-bookmark, where the saved position must be overridden.
    func play(_ episode: Episode, at startSeconds: Double) {
        beginUserMediaAttempt()
        cancelHandoffOperation()
        play(
            episode,
            preparedItem: nil,
            originEvent: .started(nil),
            startSecondsOverride: startSeconds,
            providesStartHaptic: true
        )
    }

    func approvePendingCleartextPlayback() {
        guard let action = pendingCleartextPlaybackAction else {
            clearPendingCleartextPlayback()
            return
        }
        if let key = pendingCleartextApprovalKey {
            settings?.setBool(true, for: key)
        }
        clearPendingCleartextPlayback(invalidateResolution: false)
        action()
    }

    func cancelPendingCleartextPlayback() {
        clearPendingCleartextPlayback()
    }

    /// Streams a one-off episode straight from a Search directory preview (#517)
    /// WITHOUT subscribing, downloading, or persisting anything. Builds a detached
    /// ``Episode`` — created via `init`, NEVER inserted into any `ModelContext` —
    /// so the whole engine (rate, audio session, scrubber, Now Playing bar, lock
    /// screen, chapters) works unchanged, then flags it transient so every
    /// persistence sink is skipped while it plays. The detached episode has no
    /// `podcast`, so the show name is set explicitly for the Now Playing surfaces.
    /// No-op (logged) when `audioURL` is empty.
    func playPreview(
        guid: String,
        title: String,
        audioURL: String,
        showTitle: String,
        episodeDescription: String? = nil,
        artworkURL: String? = nil,
        chapterURL: String? = nil,
        durationSeconds: Int? = nil
    ) {
        beginUserMediaAttempt()
        guard !audioURL.isEmpty else {
            AppLog.player.error("playPreview called with no audio URL for \(title, privacy: .public)")
            return
        }
        // A detached @Model: built with `init` and deliberately never inserted into
        // a ModelContext, so mutating it leaves `context.hasChanges` false and no
        // store rows are ever created by a preview stream.
        let episode = Episode(
            guid: guid,
            title: title,
            audioURL: audioURL,
            episodeDescription: episodeDescription,
            durationSeconds: durationSeconds,
            artworkURL: artworkURL,
            chapterURL: chapterURL
        )
        play(
            episode,
            preparedItem: nil,
            transient: true,
            originEvent: .started(nil)
        )
        // The detached episode has no `podcast`, so `play` left the artist empty.
        // Set the show name so the Now Playing bar / lock screen read correctly.
        currentArtist = showTitle
        updateNowPlayingInfo()
        Announcer.announce("Streaming \(title)")
    }

    /// Sole construction point for every `AVPlayerItem` the engine plays (#549, #605).
    /// Sets an explicit time-pitch algorithm because the framework default
    /// (`.lowQualityZeroLatency`-class variable-rate processing) only supports
    /// 0.5×–2.0× — this engine plays 0.5×–5.0× plus a 4× fast-forward scan — and
    /// it can render a flushed buffer chunk garbled/pitch-shifted when the render
    /// pipeline is reconfigured (the tester-reported burst before export, #549).
    /// `.timeDomain` (WSOLA) is Apple's spoken-audio algorithm and sounds cleaner
    /// than `.spectral` at everyday podcast speeds. #697 provisionally reverted
    /// this while isolating #695; build 151 remained crash-stable after the same
    /// change stopped needless live-session reconfiguration, so the #607 quality
    /// fix is restored here without changing session routing.
    private func makePlayerItem(url: URL) -> AVPlayerItem {
        let item = AVPlayerItem(url: url)
        item.audioTimePitchAlgorithm = PlaybackAudioLogic.timePitchAlgorithm
        return item
    }

    private func beginMediaResolution() {
        mediaResolutionGeneration &+= 1
        pendingCleartextPlaybackWarning = nil
        pendingCleartextPlaybackAction = nil
        pendingCleartextApprovalKey = nil
    }

    private func beginUserMediaAttempt() {
        mediaRecoveryGeneration &+= 1
        mediaRecoveryAttemptedEpisodeID = nil
        mediaRecoveryInProgressEpisodeID = nil
        playbackFailureMessage = nil
    }

    private func clearPendingCleartextPlayback(invalidateResolution: Bool = true) {
        if invalidateResolution { mediaResolutionGeneration &+= 1 }
        pendingCleartextPlaybackWarning = nil
        pendingCleartextPlaybackAction = nil
        pendingCleartextApprovalKey = nil
    }

    private func resolveCleartextMediaURL(
        _ cleartextURL: URL,
        for episode: Episode,
        generation: Int,
        onResolved: @escaping @MainActor (URL) -> Void
    ) {
        Task { @MainActor [weak self, weak episode] in
            guard let self else { return }
            let secureURL = await mediaHTTPSProbe.secureAlternative(for: cleartextURL)
            guard mediaResolutionGeneration == generation,
                  let episode,
                  !episode.isDeleted else { return }

            if let secureURL {
                AppLog.networking.info("Using verified HTTPS for podcast media (#709)")
                onResolved(secureURL)
                return
            }

            let approvalIdentity = episode.podcast?.feedURL
                ?? cleartextURL.host(percentEncoded: false)
                ?? cleartextURL.absoluteString
            let approvalKey = SettingsKey.cleartextMediaApproval(identity: approvalIdentity)
            if settings?.bool(approvalKey, default: false) == true {
                AppLog.networking.notice("Using listener-approved cleartext podcast media (#709)")
                onResolved(cleartextURL)
                return
            }

            // Do not let the outgoing episode continue speaking beneath a
            // security decision for the newly selected episode.
            if isPlaying { pause(providesPauseHaptic: false) }
            pendingCleartextApprovalKey = approvalKey
            pendingCleartextPlaybackAction = { [weak self, weak episode] in
                guard let self, let episode, !episode.isDeleted,
                      self.mediaResolutionGeneration == generation else { return }
                AppLog.networking.notice("Listener approved cleartext podcast media (#709)")
                onResolved(cleartextURL)
            }
            pendingCleartextPlaybackWarning = CleartextPlaybackWarning(
                episodeTitle: episode.title
            )
        }
    }

    /// Shared play path. `preparedItem`, when supplied, is a pre-buffered
    /// `AVPlayerItem` from the gapless preload, used for near-seamless advance.
    /// `transient` is true only for a stream-only Search preview (#517): the
    /// `episode` is a detached, non-inserted `@Model` and every persistence sink
    /// is gated off while it plays. All real entry points pass the default `false`,
    /// so a normal play after a preview restores full persistence.
    private func play(
        _ episode: Episode,
        preparedItem: AVPlayerItem?,
        transient: Bool = false,
        originEvent: PlaybackOriginEvent,
        handoff: PlaybackHandoffSnapshot? = nil,
        resolvedURL: URL? = nil,
        startSecondsOverride: Double? = nil,
        presentsFullPlayerWhenStarted: Bool = false,
        providesStartHaptic: Bool = false,
        announcesQueueNavigation: Bool = false,
        automaticallyAdvancing: Bool = false
    ) {
        guard !automaticallyAdvancing || !automaticPlaybackStoppedByTimer else { return }
        folderRuns.playbackWillStart(episode)
        if !automaticallyAdvancing { automaticPlaybackStoppedByTimer = false }
        if resolvedURL == nil {
            beginMediaResolution()
        }
        let item: AVPlayerItem
        if let preparedItem {
            item = preparedItem
            currentPlaybackURL = nil
            currentMediaResolutionComplete = true
        } else {
            guard let url = PlaybackLogic.resolvePlaybackURL(
                downloadPath: episode.localAudioURL?.path,
                audioURL: episode.audioURL
            ) else {
                AppLog.player.error("Cannot play episode, no usable source: \(episode.audioURL, privacy: .public)")
                if announcesQueueNavigation {
                    Announcer.announce("Could not play \(episode.title). No usable audio source.")
                }
                return
            }
            if resolvedURL == nil, url.scheme?.lowercased() == "http" {
                let generation = mediaResolutionGeneration
                resolveCleartextMediaURL(
                    url,
                    for: episode,
                    generation: generation
                ) { [weak self, weak episode] resolved in
                    guard let self, let episode, !episode.isDeleted else { return }
                    self.play(
                        episode,
                        preparedItem: nil,
                        transient: transient,
                        originEvent: originEvent,
                        handoff: handoff,
                        resolvedURL: resolved,
                        startSecondsOverride: startSecondsOverride,
                        presentsFullPlayerWhenStarted: presentsFullPlayerWhenStarted,
                        providesStartHaptic: providesStartHaptic,
                        announcesQueueNavigation: announcesQueueNavigation,
                        automaticallyAdvancing: automaticallyAdvancing
                    )
                }
                return
            }
            let finalURL = resolvedURL ?? url
            item = makePlayerItem(url: finalURL)
            currentPlaybackURL = finalURL
            currentMediaResolutionComplete = true
        }

        // Only deliberate starts supersede an expired timer's fade/pause.
        if !automaticallyAdvancing { cancelFadeIfNeeded() }

        // Apply source context only after resolving a playable URL. A failed
        // start must not clear or replace the origin of audio that remains loaded.
        playbackOrigin = PlaybackLogic.playbackOrigin(
            after: originEvent,
            current: playbackOrigin
        )

        // Persist + record the session of whatever was playing before we swap.
        persistCurrentPosition()
        publishCurrentPlaybackHandoff()
        flushListeningSession()

        // Cancel any running sleep timer when the user manually starts a new
        // episode. PRD 5.5: "timer clears when the user plays something else."
        // Both countdown and end-of-episode modes are cancelled. The cancellation
        // is announced via VoiceOver only if the timer was actually running so we
        // don't fire a spurious announcement on every episode start.
        if sleepTimer.isActive && !automaticallyAdvancing {
            sleepTimer.cancel()
            Announcer.announce("Sleep timer cancelled")
        }

        guard configureSession() else { return }

        // A new episode invalidates the loaded chapter list, the auto-skip loop
        // guard, and any in-progress fast-forward scan. The skipped-chapter map
        // is keyed by guid so it survives the switch (and still resets on app
        // restart, which is the intended lifetime).
        currentChapters = []
        resetChapterObservables()
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

        currentEpisodeIsTransient = transient
        setCurrentEpisode(episode)
        handoffRateOverride = handoff?.playbackRate
        didLogDeletedEpisodeGuard = false
        currentTitle = episode.title
        currentArtist = episode.podcast?.displayName ?? episode.podcast?.author
        durationSeconds = episode.durationSeconds.map(Double.init) ?? 0

        // Halt the outgoing item's render before the swap (#549). Without this,
        // switching episodes mid-playback replaces the item while `player.rate`
        // is still non-zero, so the NEW item can audibly render from 0:00 at the
        // inherited rate before the resume seek below lands. `play()` at the end
        // of this method restarts audio, so this is a no-op for gapless advance
        // (the finished item already left the player paused).
        player.pause()
        player.replaceCurrentItem(with: item)
        observeCurrentItem(item)
        applyAudioProcessing(to: item)

        // Always honor saved progress, including the final five percent. Ads or
        // credits near the end remain seekable until playback actually finishes.
        if let handoff {
            episode.positionSeconds = handoff.positionSeconds
            writeLivePosition(episode, second: handoff.positionSeconds)
            _ = saveContext()
        }
        let resume = startSecondsOverride ?? Double(PlaybackLogic.playbackStartPosition(
            position: handoff?.positionSeconds ?? resumePosition(for: episode),
            duration: episode.durationSeconds,
            introSkipSeconds: episode.podcast?.introSkipSeconds
        ))
        if resume > 0 {
            player.seek(to: CMTime(seconds: resume, preferredTimescale: 1))
            currentPositionSeconds = resume
        } else {
            currentPositionSeconds = 0
        }
        resetListeningTracking()

        applyRate()
        player.play()
        isPlaying = true
        intendsToPlay = true
        pausedByInterruption = false
        if providesStartHaptic {
            PlaybackStartHaptics.playIfNeeded(
                enabled: settings?.bool(
                    SettingsKey.hapticFeedbackEnabled,
                    default: SettingsDefault.hapticFeedbackEnabled
                ) ?? SettingsDefault.hapticFeedbackEnabled
            )
        }

        if announcesQueueNavigation || automaticallyAdvancing {
            Announcer.announce("Now playing \(episode.title)")
        }
        persistLastPlayingEpisode(episode)
        updateNowPlayingInfo()
        refreshPreload()
        loadChaptersForCurrentEpisode()
        if presentsFullPlayerWhenStarted,
           settings?.bool(SettingsKey.openPlayerOnPlay, default: SettingsDefault.openPlayerOnPlay)
            ?? SettingsDefault.openPlayerOnPlay {
            pendingFullPlayerPresentation = true
        }
    }

    /// User-initiated episode starts wait briefly for one explicit record fetch.
    /// The outgoing item is paused first so it cannot continue speaking under the
    /// bounded handoff delay. Automatic queue advance continues to use `play(_:)`
    /// and therefore has no network gap between episodes.
    private func playAfterFetchingHandoff(
        _ episode: Episode,
        originEvent: PlaybackOriginEvent,
        presentsFullPlayerWhenStarted: Bool = false,
        providesStartHaptic: Bool = false
    ) {
        guard playbackHandoff.isEnabled,
              let identity = followedPlaybackHandoffIdentity(for: episode) else {
            play(
                episode,
                preparedItem: nil,
                originEvent: originEvent,
                presentsFullPlayerWhenStarted: presentsFullPlayerWhenStarted,
                providesStartHaptic: providesStartHaptic
            )
            return
        }
        if isPlaying { pause(providesPauseHaptic: false) }
        beginHandoffOperation()
        let generation = playbackHandoffGeneration
        playbackHandoffTask = Task { @MainActor [weak self, weak episode] in
            guard let self else { return }
            let fetched = await fetchPlaybackHandoff(identity: identity)
            guard !Task.isCancelled,
                  playbackHandoffGeneration == generation,
                  let episode,
                  !episode.isDeleted else { return }
            playbackHandoffTask = nil
            // A Follow can be superseded while the direct CloudKit request is
            // in flight. Catalog-only playback is device-local, so a response
            // fetched before that transition must not cross the new boundary.
            let eligibleHandoff = followedPlaybackHandoffIdentity(for: episode) == identity
                ? fetched : nil
            play(
                episode,
                preparedItem: nil,
                originEvent: originEvent,
                handoff: eligibleHandoff,
                presentsFullPlayerWhenStarted: presentsFullPlayerWhenStarted,
                providesStartHaptic: providesStartHaptic
            )
        }
    }

    /// Loads an episode paused, restoring its saved position. Used on launch to
    /// repopulate the Now Playing bar without starting audio.
    func load(_ episode: Episode, autoplay: Bool = false) {
        cancelHandoffOperation()
        if autoplay {
            play(episode)
            return
        }
        guard let url = PlaybackLogic.resolvePlaybackURL(
            downloadPath: episode.localAudioURL?.path,
            audioURL: episode.audioURL
        ) else {
            AppLog.player.error("Cannot load episode, no usable source: \(episode.audioURL, privacy: .public)")
            return
        }
        beginMediaResolution()
        // Like the play() path, switching the loaded episode invalidates the
        // chapter list, the auto-skip loop guard, and any fast-forward scan.
        currentChapters = []
        resetChapterObservables()
        lastAutoSkipFromChapterIndex = nil
        isFastForwarding = false
        rateBeforeFastForward = nil
        playbackOrigin = PlaybackLogic.playbackOrigin(
            after: .restoredAfterRelaunch,
            current: playbackOrigin
        )

        currentEpisodeIsTransient = false
        setCurrentEpisode(episode)
        handoffRateOverride = nil
        didLogDeletedEpisodeGuard = false
        currentTitle = episode.title
        currentArtist = episode.podcast?.displayName ?? episode.podcast?.author
        durationSeconds = episode.durationSeconds.map(Double.init) ?? 0

        let item = makePlayerItem(url: url)
        currentPlaybackURL = url
        currentMediaResolutionComplete = url.scheme?.lowercased() != "http"
        player.replaceCurrentItem(with: item)
        observeCurrentItem(item)
        applyAudioProcessing(to: item)

        let resume = PlaybackLogic.playbackStartPosition(
            position: resumePosition(for: episode),
            duration: episode.durationSeconds,
            introSkipSeconds: episode.podcast?.introSkipSeconds
        )
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
        guard !releaseInvalidCurrentEpisodeIfNeeded() else { return }
        // Decide from playback intent + the live transport, never the `isPlaying`
        // display flag alone: single-button Bluetooth earbuds send this command,
        // and a stale-`false` flag made the first press resume (a no-op) instead
        // of pause (Shokz two-press / Bose "pause does nothing"). See
        // `PlaybackLogic.remoteToggleAction`.
        let action = PlaybackLogic.remoteToggleAction(
            intendsToPlay: intendsToPlay,
            playerIsPlaying: player.timeControlStatus == .playing
        )
        switch action {
        case .pause: pause()
        case .resume: resume()
        }
    }

    func resume() {
        automaticPlaybackStoppedByTimer = false
        resume(providesStartHaptic: true)
    }

    private func resume(providesStartHaptic: Bool) {
        if folderRuns.resumeTransportIfNeeded() { return }
        guard !releaseInvalidCurrentEpisodeIfNeeded() else { return }
        guard let episode = currentEpisode else { return }
        if !currentMediaResolutionComplete,
           let cleartextURL = currentPlaybackURL,
           cleartextURL.scheme?.lowercased() == "http" {
            beginMediaResolution()
            let generation = mediaResolutionGeneration
            resolveCleartextMediaURL(
                cleartextURL,
                for: episode,
                generation: generation
            ) { [weak self, weak episode] resolvedURL in
                guard let self, let episode, self.currentEpisode === episode else { return }
                self.installResolvedURLForLoadedEpisode(resolvedURL)
                self.resume(providesStartHaptic: providesStartHaptic)
            }
            return
        }
        guard playbackHandoff.isEnabled,
              !currentEpisodeIsTransient,
              let identity = followedPlaybackHandoffIdentity(for: episode) else {
            resumeImmediately(providesStartHaptic: providesStartHaptic)
            return
        }
        beginHandoffOperation()
        let generation = playbackHandoffGeneration
        let episodeID = episode.persistentModelID
        playbackHandoffTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let fetched = await fetchPlaybackHandoff(identity: identity)
            guard !Task.isCancelled,
                  playbackHandoffGeneration == generation,
                  !releaseInvalidCurrentEpisodeIfNeeded(),
                  nowPlayingEpisodeID == episodeID,
                  let episode = currentEpisode else { return }
            if followedPlaybackHandoffIdentity(for: episode) == identity,
               let fetched {
                applyFetchedHandoff(fetched, to: episode)
            }
            playbackHandoffTask = nil
            resumeImmediately(providesStartHaptic: providesStartHaptic)
        }
    }

    private func resumeImmediately(providesStartHaptic: Bool) {
        recordPlaybackDiagnostic("resume.begin")
        guard currentEpisode != nil else { return }
        // Resuming during a sleep-timer fade supersedes it (P1-4).
        cancelFadeIfNeeded()
        guard configureSession() else { return }
        applyRate()
        player.play()
        isPlaying = true
        intendsToPlay = true
        pausedByInterruption = false
        if providesStartHaptic {
            PlaybackStartHaptics.playIfNeeded(
                enabled: settings?.bool(
                    SettingsKey.hapticFeedbackEnabled,
                    default: SettingsDefault.hapticFeedbackEnabled
                ) ?? SettingsDefault.hapticFeedbackEnabled
            )
        }
        updateNowPlayingInfo()
    }

    private func installResolvedURLForLoadedEpisode(_ url: URL) {
        let item = makePlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        observeCurrentItem(item)
        applyAudioProcessing(to: item)
        if currentPositionSeconds > 0 {
            player.seek(to: CMTime(seconds: currentPositionSeconds, preferredTimescale: 1))
        }
        currentPlaybackURL = url
        currentMediaResolutionComplete = true
    }

    func pause() {
        // An explicit stop supersedes any automatic or manual pending start.
        beginMediaResolution()
        pause(providesPauseHaptic: true)
    }

    private func pause(providesPauseHaptic: Bool, folderRunInternal: Bool = false) {
        recordPlaybackDiagnostic("pause.begin")
        if !folderRunInternal { folderRuns.pauseForTransport() }
        guard !releaseInvalidCurrentEpisodeIfNeeded() else { return }
        let wasPlaying = isPlaying
            || intendsToPlay
            || player.timeControlStatus == .playing
        // An explicit pause while Siri owns the route (including a Siri-issued
        // remote pause command) cancels automatic post-interruption resume.
        pausedByInterruption = false
        cancelHandoffOperation()
        player.pause()
        isPlaying = false
        intendsToPlay = false
        if providesPauseHaptic, wasPlaying {
            PlaybackPauseHaptics.playIfNeeded(
                enabled: settings?.bool(
                    SettingsKey.hapticFeedbackEnabled,
                    default: SettingsDefault.hapticFeedbackEnabled
                ) ?? SettingsDefault.hapticFeedbackEnabled
            )
        }
        persistCurrentPosition()
        publishCurrentPlaybackHandoff()
        flushListeningSession()
        updateNowPlayingInfo()
    }

    /// userInfo key for `.earshotWillDeleteEpisodes`: the `PersistentIdentifier`
    /// of the podcast whose episodes are about to be deleted. Absent means all
    /// local data is being wiped (factory reset).
    nonisolated static let willDeletePodcastIDKey = "podcastID"
    nonisolated static let willDeleteEpisodeIDsKey = "episodeIDs"

    /// Stops playback and detaches the player from its episode entirely (#574).
    /// Runs (via `.earshotWillDeleteEpisodes`) BEFORE the loaded episode's model
    /// objects are deleted — unfollowing the playing show, factory reset — so no
    /// later tick, position persist, session flush, or now-playing update can
    /// touch a deleted SwiftData instance. Safe to call when nothing is loaded:
    /// every step below no-ops on nil/idle state.
    func stopAndUnload() {
        // Persist + flush FIRST, while the episode instance is still valid —
        // the same durability anchors pause() uses. (In the unsubscribe flow
        // the flushed session is removed moments later by
        // `StatsRepository.removeSessions`; harmless.) After the clears below,
        // nothing episode-referencing is ever written again.
        persistCurrentPosition()
        publishCurrentPlaybackHandoff()
        flushListeningSession()

        unloadWithoutPersisting()
    }

    /// Drops every retained episode reference without reading the model. A
    /// saved SwiftData deletion can leave `isDeleted == false` on a detached
    /// object even though stored-property access will trap.
    private func unloadWithoutPersisting() {
        recordPlaybackDiagnostic("unload")
        folderRuns.pauseForTransport()

        // Supersede any in-flight sleep-timer fade and clear the timer itself:
        // its episode (or the whole library) is going away, and PRD 5.5 clears
        // the timer whenever playback of the timed episode ends. Silent — the
        // deletion flows already announce their own outcome.
        cancelFadeIfNeeded()
        if sleepTimer.isActive { sleepTimer.cancel() }

        player.pause()
        player.replaceCurrentItem(with: nil)
        // The per-item buffer KVO tokens would otherwise dangle on the
        // discarded item (mirrors observeCurrentItem's teardown). The
        // player-level timeControlStatus observation stays — it outlives items.
        bufferEmptyObservation?.invalidate()
        bufferEmptyObservation = nil
        likelyToKeepUpObservation?.invalidate()
        likelyToKeepUpObservation = nil
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        if let failedToEndObserver {
            NotificationCenter.default.removeObserver(failedToEndObserver)
            self.failedToEndObserver = nil
        }

        isPlaying = false
        intendsToPlay = false
        pausedByInterruption = false
        isFastForwarding = false
        rateBeforeFastForward = nil
        stopAfterCurrentEpisode = false
        playbackOrigin = PlaybackLogic.playbackOrigin(after: .stopped, current: playbackOrigin)

        // Drop every episode-derived reference and observable surface.
        setCurrentEpisode(nil)
        currentEpisodeIsTransient = false
        handoffRateOverride = nil
        currentTitle = nil
        currentArtist = nil
        durationSeconds = 0
        currentPositionSeconds = 0
        currentChapters = []
        resetChapterObservables()
        lastAutoSkipFromChapterIndex = nil
        // Invalidates any in-flight async chapter load: its apply guard
        // requires this guid to still match, so the stale result is dropped.
        chapterLoadEpisodeGUID = nil
        clearPreload()

        lastTickPosition = nil
        accumulatedListenSeconds = 0
        lastPersistedSecond = nil
        lastNowPlayingSyncSecond = nil
        lastArtworkURL = nil
        didLogDeletedEpisodeGuard = false

        // Nothing is loaded any more: clear the lock screen / Control Center
        // entirely rather than leaving a stale title behind. The AVAudioSession
        // is left exactly as the existing stop paths leave it (never
        // deactivated here), so route/interruption behavior is unchanged.
        clearNowPlayingInfo()
        // Nothing loaded → no crash-recovery position to keep (#736).
        clearLivePosition()
    }

    /// Clears every observable "now playing" surface after playback stops with
    /// nothing to advance to — a natural end-of-episode with an empty queue, an
    /// end-of-episode sleep timer, stop-after-current, or "mark played" with
    /// nothing queued (#730). ``currentTitle`` drives the mini player's
    /// visibility, so nil-ing it hides the bar instead of leaving it stranded on
    /// a finished episode. The lock screen is cleared (``updateNowPlayingInfo``
    /// would write an empty-title dict, not clear it), and the persisted
    /// last-playing episode is dropped so a relaunch doesn't restore a finished
    /// episode back into the bar.
    ///
    /// Deliberately NOT called on pause, seek, interruption, buffering, or
    /// auto-advance to a next queue item — every one of those keeps the bar.
    /// Lighter than ``stopAndUnload`` (no player-item teardown): the item has
    /// already played to its end, and the next ``play`` replaces it anyway.
    private func clearNowPlayingPresentation() {
        playbackOrigin = PlaybackLogic.playbackOrigin(after: .stopped, current: playbackOrigin)
        setCurrentEpisode(nil)
        currentTitle = nil
        currentArtist = nil
        durationSeconds = 0
        currentPositionSeconds = 0
        currentChapters = []
        resetChapterObservables()
        // Drop the persisted last-playing episode so launch restore doesn't
        // repopulate the bar with the episode that just finished. An empty
        // string reads as "nothing stored" to `PlaybackStartup` (#730).
        settings?.setRawValue("", for: SettingsKey.lastPlayingEpisodeID)
        // And drop the UserDefaults crash-recovery position so a finished
        // episode is never resumed on the next launch (#736).
        clearLivePosition()
        // Clear the lock screen / Control Center entirely rather than leaving a
        // stale (or empty) title behind, exactly as `stopAndUnload` does.
        clearNowPlayingInfo()
    }

    /// Skips forward by the user-configured interval (default 30s).
    func skipForward() {
        seek(by: Double(skipForwardSeconds))
    }

    /// Skips back by the user-configured interval (default 15s).
    func skipBack() {
        seek(by: -Double(skipBackSeconds))
    }

    /// Skips forward by an explicit interval supplied by a system App Intent.
    /// Returns false when no episode is loaded so Siri can report that outcome
    /// instead of claiming a seek occurred (#551).
    @discardableResult
    func skipForward(seconds: Int) -> Bool {
        guard currentEpisode != nil else { return false }
        seek(by: Double(max(0, seconds)))
        return true
    }

    /// Skips backward by an explicit interval supplied by a system App Intent.
    @discardableResult
    func skipBack(seconds: Int) -> Bool {
        guard currentEpisode != nil else { return false }
        seek(by: -Double(max(0, seconds)))
        return true
    }

    /// Seeks to an absolute position in seconds, clamped to the item duration.
    func seek(to seconds: Double) {
        // A deliberate local transport action is newer than any resume-time
        // CloudKit handoff fetch. Without this cancellation, the late fetch can
        // seek straight back to the position the listener just left.
        cancelHandoffOperation()
        let loadedDuration = player.currentItem?.duration.seconds
        let authoritativeDuration: Double
        if let loadedDuration, loadedDuration.isFinite, loadedDuration > 0 {
            authoritativeDuration = loadedDuration
        } else {
            authoritativeDuration = durationSeconds
        }
        let clamped = max(
            0,
            min(seconds, authoritativeDuration > 0 ? authoritativeDuration : seconds)
        )

        userSeekGeneration &+= 1
        let generation = userSeekGeneration
        pendingUserSeekTarget = clamped
        player.currentItem?.cancelPendingSeeks()

        // Keep repeated button presses cumulative immediately: a second 30s
        // skip starts from this optimistic target rather than the old AVPlayer
        // clock. Periodic ticks are held until AVPlayer confirms the request.
        currentPositionSeconds = clamped
        persistCurrentPosition()
        publishCurrentPlaybackHandoff()
        updateNowPlayingInfo()

        player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            completionHandler: { [weak self] finished in
                Task { @MainActor [weak self] in
                    self?.finishUserSeek(
                        generation: generation,
                        requestedTarget: clamped,
                        finished: finished
                    )
                }
            }
        )
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

    /// Reconciles the optimistic transport position with AVPlayer's confirmed
    /// landing point. A completion belonging to an older repeated skip is
    /// ignored, so it cannot pull the newest request backward.
    private func finishUserSeek(
        generation: Int,
        requestedTarget: Double,
        finished: Bool
    ) {
        guard generation == userSeekGeneration else { return }
        pendingUserSeekTarget = nil

        let playerPosition = player.currentTime().seconds
        let settledPosition: Double
        if playerPosition.isFinite, playerPosition >= 0 {
            settledPosition = playerPosition
        } else {
            settledPosition = requestedTarget
        }

        // AVPlayer promises the completion callback even for an interrupted
        // request. On success, use its actual landing point (which may differ
        // slightly for compressed audio). On interruption, restoring the real
        // clock is more honest than leaving an unreachable optimistic target.
        if settledPosition != currentPositionSeconds {
            currentPositionSeconds = settledPosition
            persistCurrentPosition()
            publishCurrentPlaybackHandoff()
            updateNowPlayingInfo()
        }
    }

    /// Invalidates an explicit seek when the loaded episode changes. The
    /// generation check keeps a late completion from mutating the replacement
    /// episode's position.
    private func invalidatePendingUserSeek() {
        guard pendingUserSeekTarget != nil else { return }
        userSeekGeneration &+= 1
        pendingUserSeekTarget = nil
        player.currentItem?.cancelPendingSeeks()
    }

    // MARK: Private — rate

    /// The playback rate that applies to the loaded episode (per-podcast override
    /// or the global speed). Also the speed recorded on listening sessions.
    private var currentEffectiveRate: Double {
        if let handoffRateOverride { return handoffRateOverride }
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

    /// The rate to publish to `MPNowPlayingInfoPropertyPlaybackRate`. Derived from
    /// playback intent and the intended effective rate — NOT the live
    /// `player.rate`, which reads 0 mid-buffer and would falsely advertise
    /// "paused" to Bluetooth/AVRCP accessories that mirror the system's play state
    /// (Bose Ultra Open). See `PlaybackLogic.nowPlayingRate`.
    private var reportedNowPlayingRate: Double {
        PlaybackLogic.nowPlayingRate(
            intendsToPlay: intendsToPlay,
            effectiveRate: currentEffectiveRate,
            isFastForwarding: isFastForwarding,
            fastForwardRate: ChapterSkipLogic.fastForwardRate
        )
    }

    /// The AVPlayer's `defaultRate`, exposed only so tests can assert it never goes
    /// stale relative to ``effectiveRate`` (#609). Not for UI use -- read
    /// ``effectiveRate`` instead.
    var debugDefaultRate: Double { Double(player.defaultRate) }

    /// Now Playing transport rates exposed for regression tests. The current
    /// rate becomes zero while paused; the default rate remains the user's
    /// selected playback speed so Bluetooth accessories interpret play/pause
    /// correctly above 1x.
    var debugNowPlayingRate: Double? {
        (cachedNowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber)?.doubleValue
    }

    var debugNowPlayingDefaultRate: Double? {
        (cachedNowPlayingInfo[MPNowPlayingInfoPropertyDefaultPlaybackRate] as? NSNumber)?.doubleValue
    }

    /// Re-applies the effective rate to the player. Call when the global speed —
    /// or the current podcast's override — changes mid-playback.
    func reapplyRate() {
        // This entry point is driven by an explicit local settings change. That
        // intent supersedes a session-only rate received during handoff.
        handoffRateOverride = nil
        applyRate()
        publishCurrentPlaybackHandoff()
    }

    /// Sets the per-podcast speed override on the current episode's podcast and
    /// immediately re-applies the rate. No-op when nothing is loaded. Announces
    /// the change to VoiceOver unless `announce` is false — pass false from a
    /// VoiceOver-adjustable control that already re-reads its own value, so the
    /// new speed isn't spoken twice.
    func setPodcastSpeedOverride(_ speed: Double, announce: Bool = true) {
        guard let podcast = currentEpisode?.podcast else { return }
        let clamped = PlaybackLogic.clampedSpeed(speed)
        handoffRateOverride = nil
        podcast.speedOverride = clamped
        if saveContext() {
            NotificationCenter.default.post(
                name: .earshotSubscriptionsDidChange,
                object: podcast.feedURL
            )
        }
        applyRate()
        publishCurrentPlaybackHandoff()
        if announce {
            Announcer.announce("Speed set to \(PlaybackLogic.spokenRate(clamped)) for this podcast")
        }
    }

    /// Clears the per-podcast speed override on the current episode's podcast so
    /// global speed takes effect. No-op when nothing is loaded.
    func clearPodcastSpeedOverride() {
        guard let podcast = currentEpisode?.podcast else { return }
        handoffRateOverride = nil
        podcast.speedOverride = nil
        if saveContext() {
            NotificationCenter.default.post(
                name: .earshotSubscriptionsDidChange,
                object: podcast.feedURL
            )
        }
        applyRate()
        publishCurrentPlaybackHandoff()
        let global = settings?.double(SettingsKey.globalSpeed, default: SettingsDefault.globalSpeed)
            ?? SettingsDefault.globalSpeed
        Announcer.announce("Speed reset to global \(PlaybackLogic.spokenRate(global))")
    }

    /// Sets the global playback speed in persistent settings, clears any
    /// per-podcast override on the current podcast, and immediately re-applies.
    /// Announces the change to VoiceOver unless `announce` is false — pass false
    /// from a VoiceOver-adjustable control that already re-reads its own value.
    func setGlobalSpeed(_ speed: Double, announce: Bool = true) {
        let clamped = PlaybackLogic.clampedSpeed(speed)
        handoffRateOverride = nil
        settings?.setDouble(clamped, for: SettingsKey.globalSpeed)
        let podcastWithClearedOverride = currentEpisode?.podcast.flatMap { podcast in
            podcast.speedOverride == nil ? nil : podcast
        }
        currentEpisode?.podcast?.speedOverride = nil
        if saveContext(), let podcastWithClearedOverride {
            NotificationCenter.default.post(
                name: .earshotSubscriptionsDidChange,
                object: podcastWithClearedOverride.feedURL
            )
        }
        applyRate()
        publishCurrentPlaybackHandoff()
        if announce {
            Announcer.announce("Speed set to \(PlaybackLogic.spokenRate(clamped)) globally")
        }
    }

    /// True when the currently loaded episode's podcast has a speed override set.
    var hasPodcastSpeedOverride: Bool {
        currentEpisode?.podcast?.speedOverride != nil
    }

    /// True when a per-podcast speed override could be saved for the currently
    /// loaded episode. False for a transient stream-only preview (#517), whose
    /// detached episode has no `podcast` to attach an override to — those always
    /// fall back to the global speed.
    var canOverridePerPodcast: Bool {
        currentEpisode?.podcast != nil
    }

    private func applyRate() {
        // While a fast-forward scan is active, the scan rate wins; the prior rate
        // is restored by `endFastForward`.
        let rate = isFastForwarding ? ChapterSkipLogic.fastForwardRate : currentEffectiveRate
        observePeriodicTime(playbackRate: rate)
        // Always keep `defaultRate` in sync with the effective rate, not just when
        // paused (#609). `AVPlayer.play()` can reassert the rate from `defaultRate`
        // when resuming from a paused state (iOS 16+) -- `play(_:preparedItem:...)`
        // pauses right before swapping in the next episode's item, then calls this
        // method followed immediately by `player.play()`. `isPlaying` stays `true`
        // across an ordinary auto-advance, so without this line `defaultRate` would
        // only ever be refreshed by an explicit pause/resume cycle and could go
        // stale -- silently reasserting a previous podcast's rate on the very next
        // `play()`, until some unrelated event (e.g. stall recovery) happened to
        // reapply the correct rate again.
        player.defaultRate = Float(rate)
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
        }
    }

    // MARK: Public — hold-to-fast-forward (4× scan, #373)

    /// True when the VoiceOver rotor "Start/Stop Fast Forward" action should be
    /// offered. Always true (#610) -- previously gated on the "Direct-touch
    /// playback area" setting (default off), which left VoiceOver users with no
    /// way to reach the 4x scan at all unless they'd already found and enabled
    /// that specific setting. That gate was unnecessary: the rotor action calls
    /// `beginFastForward()`/`endFastForward()` directly and has no dependency on
    /// the artwork's raw `.onLongPressGesture` (the actual source of the
    /// touch-gesture-vs-VoiceOver conflict the setting was meant to address) --
    /// the sighted press-and-hold gesture is itself always available, ungated, and
    /// unaffected by this change. The setting had no other consumer, so it and its
    /// Settings UI toggle were removed entirely (`SettingsKey.directTouchEnabled`
    /// is retained only for data-compatibility, per the project's established
    /// pattern for other removed settings).
    var fastForwardRotorAvailable: Bool { true }

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
    ///
    /// When the Queue screen is displaying episodes grouped by podcast or folder
    /// (``SettingsKey/groupQueueEpisodes``), "next" walks that SAME grouped
    /// order (#627 follow-up) — not the raw, possibly interleaved queue order,
    /// which the grouped display never shows the user in the first place.
    /// `QueueLogic.group` is the exact transform the Queue screen itself uses to
    /// render, reused here so the two can never drift apart.
    ///
    /// EXCEPT: an episode the user explicitly "Play Next"-ed is inserted
    /// immediately after `finished` in the RAW queue (``QueueRepository/playNext(_:after:)``)
    /// — that raw adjacency IS the Play Next guarantee. The grouped reorder
    /// above would otherwise cluster it behind the rest of `finished`'s own
    /// group, silently breaking Play Next across podcasts, so the raw
    /// positional candidate wins immediately whenever it's a registered
    /// override — checked before grouping is ever applied.
    private func nextAdvanceID(
        after finished: Episode, in queued: [Episode], allowsWrapping: Bool = false
    ) -> PersistentIdentifier? {
        let wrap = allowsWrapping && (settings?.bool(
            SettingsKey.wrapQueue, default: SettingsDefault.wrapQueue
        ) ?? SettingsDefault.wrapQueue)
        let eligibleIDs = Set(queued.filter {
            !$0.isPlayed || $0.persistentModelID == finished.persistentModelID
        }.map(\.persistentModelID))
        let continueEpisode = settings?.bool(
            SettingsKey.continueAfterEpisode, default: SettingsDefault.continueAfterEpisode
        ) ?? SettingsDefault.continueAfterEpisode
        guard continueEpisode else { return nil }

        let rawIDs = queued.map(\.persistentModelID)
        let rawCandidate = PlaybackLogic.nextUpID(queue: rawIDs, after: finished.persistentModelID)
        if let rawCandidate, playNextOverrides.contains(rawCandidate) {
            return rawCandidate
        }

        let groupSetting = settings?.bool(
            SettingsKey.continueAfterGroupEnds, default: SettingsDefault.continueAfterGroupEnds
        ) ?? SettingsDefault.continueAfterGroupEnds
        let allPairs = displayedQueuePairs(queued.contains(where: { $0.persistentModelID == finished.persistentModelID })
            ? queued : queued + [finished])
        let queuedIDs = Set(queued.map(\.persistentModelID))
        let orderedPairs = allPairs.filter { queuedIDs.contains($0.id) && (!wrap || eligibleIDs.contains($0.id)) }
        let currentGroup = allPairs.first { $0.id == finished.persistentModelID }?.groupKey ?? .unfiled

        let candidate = PlaybackLogic.nextUpID(
            queue: orderedPairs.map(\.id), after: finished.persistentModelID
        )
        return PlaybackLogic.nextUpHonoringBoundaries(
            queue: orderedPairs,
            after: finished.persistentModelID,
            currentGroupKey: currentGroup,
            continueAfterEpisode: continueEpisode,
            continueAfterGroupEnds: PlaybackLogic.continueAfterGroupEnds(
                setting: groupSetting, nextCandidate: candidate, playNextOverrides: playNextOverrides
            ),
            wrapToRemaining: wrap
        )
    }

    /// Shared ordering for explicit navigation and automatic advancement.
    private func displayedQueuePairs(
        _ queued: [Episode]
    ) -> [(id: PersistentIdentifier, groupKey: QueueGroup.Kind)] {
        let grouping = settings?.queueGrouping() ?? SettingsDefault.queueGrouping

        // Group boundaries always use the same key as the Queue display. Folder
        // mode resolves nested memberships to their top-level folder once, then
        // each episode is an O(1) lookup; None and Podcast retain podcast
        // boundaries for the "Continue after group ends" setting.
        let folderResolution: QueueFolderResolution
        if grouping == .folder, let context {
            folderResolution = FolderRepository(context: context).queueFolderResolution()
        } else {
            folderResolution = .empty
        }
        let groupKey: (Episode) -> QueueGroup.Kind = { episode in
            if grouping == .folder {
                return folderResolution.key(for: episode)
            }
            if let podcastID = episode.podcast?.persistentModelID { return .podcast(podcastID) }
            return .unfiled
        }

        let orderedPairs: [(id: PersistentIdentifier, groupKey: QueueGroup.Kind)]
        if grouping != .none {
            let forGrouping = queued.map { (id: $0.persistentModelID, key: groupKey($0)) }
            orderedPairs = QueueLogic.group(forGrouping).flatMap { group in
                group.ids.map { (id: $0, groupKey: group.key) }
            }
        } else {
            orderedPairs = queued.map { (id: $0.persistentModelID, groupKey: groupKey($0)) }
        }

        return orderedPairs
    }

    func previousInQueue() { navigateQueue(.previous) }
    func nextInQueue() { navigateQueue(.next) }

    /// Leave the old episode exactly where it is in Queue, with its saved place.
    /// Explicit navigation ignores auto-advance stop preferences, but uses the
    /// established manual-play timer/stop-after-current policy.
    private func navigateQueue(_ direction: QueueNavigationDirection) {
        guard !releaseInvalidCurrentEpisodeIfNeeded(),
              let current = currentEpisode, let context,
              !currentEpisodeIsTransient else {
            Announcer.announce("The current episode is not in Queue")
            return
        }
        let queued = QueueRepository(context: context).queue()
        let ids = displayedQueuePairs(queued).map(\.id)
        guard ids.contains(current.persistentModelID) else {
            Announcer.announce("The current episode is not in Queue")
            return
        }
        guard let targetID = PlaybackLogic.queueNeighborID(
            queue: ids, current: current.persistentModelID, direction: direction
        ), let target = queued.first(where: { $0.persistentModelID == targetID }) else {
            Announcer.announce(direction == .previous
                ? "No previous episode in Queue" : "No next episode in Queue")
            return
        }
        guard persistCurrentPosition() else {
            Announcer.announce("Could not save your playback position")
            return
        }
        // Invalidate any pending handoff or media resolution from an older tap.
        beginUserMediaAttempt()
        cancelHandoffOperation()
        play(target, preparedItem: nil, originEvent: playbackOriginAdvanceEvent(to: target),
             announcesQueueNavigation: true)
    }

    func markCurrentPlayedAndNextInQueue() {
        guard !releaseInvalidCurrentEpisodeIfNeeded(),
              let current = currentEpisode, let context,
              !currentEpisodeIsTransient,
              QueueRepository(context: context).queue().contains(where: {
                  $0.persistentModelID == current.persistentModelID
              }) else {
            Announcer.announce("The current episode is not in Queue")
            return
        }
        markCurrentPlayedAndAdvance(explicitQueueNavigation: true)
    }

    /// Builds the origin transition for Queue advancement. Folder context only
    /// survives while the next episode's podcast remains in the live source
    /// folder subtree; crossing a folder boundary clears it before the episode
    /// becomes observable in Now Playing.
    private func playbackOriginAdvanceEvent(to nextEpisode: Episode) -> PlaybackOriginEvent {
        guard let playbackOrigin, let context else {
            return .advanced(nextEpisodeBelongsToOrigin: false)
        }
        let repository = FolderRepository(context: context)
        guard let folder = repository.folders().first(where: {
            $0.persistentModelID == playbackOrigin.folderID
        }) else {
            return .advanced(nextEpisodeBelongsToOrigin: false)
        }
        let belongs = repository.episode(nextEpisode, belongsToSubtreeOf: folder)
        return .advanced(nextEpisodeBelongsToOrigin: belongs)
    }

    /// Manual "mark as played" for the loaded episode: marks it played, removes
    /// it from the queue, and advances to the next queue item WITHOUT playing the
    /// current one to the end. Distinct from natural end-of-item completion.
    /// No-op when nothing is loaded. Announces the result.
    func markCurrentPlayedAndAdvance(explicitQueueNavigation: Bool = false) {
        guard let finished = currentEpisode, let context, !currentEpisodeIsTransient else { return }
        if !explicitQueueNavigation, folderRuns.completeCurrent(finished, continuePlayback: true) {
            Announcer.announce("Marked as played")
            return
        }

        if explicitQueueNavigation {
            beginUserMediaAttempt()
            cancelHandoffOperation()
        }
        flushListeningSession()
        let repo = QueueRepository(context: context)

        let queued = repo.queue()
        let nextID = explicitQueueNavigation
            ? PlaybackLogic.queueNeighborID(
                queue: displayedQueuePairs(queued).map(\.id),
                current: finished.persistentModelID, direction: .next
            )
            : nextAdvanceID(after: finished, in: queued)
        let nextEpisode = queued.first { $0.persistentModelID == nextID }
        if explicitQueueNavigation, let nextEpisode,
           PlaybackLogic.resolvePlaybackURL(
               downloadPath: nextEpisode.localAudioURL?.path, audioURL: nextEpisode.audioURL
           ) == nil {
            Announcer.announce("Could not play \(nextEpisode.title). No usable audio source.")
            return
        }

        guard repo.markPlayedAndRemove(finished) else {
            Announcer.announce("Could not mark as played")
            return
        }
        finished.positionSeconds = 0
        saveContext()
        Announcer.announce("Marked as played")

        guard let nextEpisode else {
            // Nothing queued after this one: stop cleanly and hide the bar (#730).
            pause(providesPauseHaptic: false)
            isPlaying = false
            clearNowPlayingPresentation()
            return
        }

        let prepared = preloadedEpisode?.persistentModelID == nextEpisode.persistentModelID
            ? preloadedItem : nil
        preloadedItem = nil
        preloadedEpisode = nil
        play(
            nextEpisode,
            preparedItem: prepared,
            originEvent: playbackOriginAdvanceEvent(to: nextEpisode),
            announcesQueueNavigation: explicitQueueNavigation
        )
        if !explicitQueueNavigation {
            Announcer.announce("Now playing \(nextEpisode.title)")
        }
    }

    /// Removes `episode` from the queue (#619). If it's the episode currently
    /// playing, stops it and advances to the next queued episode -- mirrors
    /// ``markCurrentPlayedAndAdvance()``'s resolve-next-before-remove shape, but
    /// does NOT mark the episode played: removing isn't the same as finishing,
    /// and per #614 a removal must not affect the "Episodes completed" listening
    /// stat. Removing any OTHER (not currently playing) episode is unaffected --
    /// a plain queue mutation with no playback side effect, exactly as before.
    ///
    /// Takes `context` explicitly rather than reading the stored `self.context`
    /// so this stays callable (and the plain-removal path stays correct) even
    /// from a `PlayerService` that hasn't been `configure(context:)`-ed, matching
    /// how `QuickActionBuildersTests` deliberately tests queue-action building in
    /// isolation from full playback setup.
    func removeFromQueue(_ episode: Episode, context: ModelContext) {
        let repo = QueueRepository(context: context)

        guard nowPlayingEpisodeID == episode.persistentModelID else {
            repo.cancelFromQueue(episode)
            return
        }

        // Resolve the next episode from the CURRENT queue, before removal --
        // exactly as markCurrentPlayedAndAdvance() does, so nextAdvanceID still
        // sees `episode` in the list when computing "the one after it."
        let queued = repo.queue()
        let nextID = nextAdvanceID(after: episode, in: queued)
        let nextEpisode = queued.first { $0.persistentModelID == nextID }

        flushListeningSession()
        // The repository resolves the canonical queue item by episode identity.
        // If persistence fails or the membership disappeared concurrently, keep
        // playback intact instead of advancing while the row remains queued.
        guard repo.cancelFromQueue(episode) else { return }

        guard let nextEpisode else {
            // Nothing queued after this one: stop cleanly and hide the bar (#730).
            pause(providesPauseHaptic: false)
            isPlaying = false
            clearNowPlayingPresentation()
            return
        }

        let prepared = preloadedEpisode?.persistentModelID == nextEpisode.persistentModelID
            ? preloadedItem : nil
        preloadedItem = nil
        preloadedEpisode = nil
        play(
            nextEpisode,
            preparedItem: prepared,
            originEvent: playbackOriginAdvanceEvent(to: nextEpisode)
        )
        Announcer.announce("Now playing \(nextEpisode.title)")
    }

    /// True when the loaded episode's audio is available as a local file (already
    /// downloaded). Drives whether "Export audio file" shares immediately or has
    /// to download first.
    var currentEpisodeIsDownloaded: Bool {
        guard let url = currentEpisode?.localAudioURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
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
        // Shared with the per-row "Export audio" Quick Action (#689): the
        // download-then-copy orchestration lives in ``EpisodeExporter`` so it
        // works for any episode, not just the loaded one.
        return await EpisodeExporter.export(episode: episode, using: downloads)
    }

    // MARK: Public — chapter auto-skip (#373)

    /// Supplies the current episode's chapter list to the engine so auto-skip can
    /// evaluate the active chapter on each tick. Called by the player screen once
    /// chapters are loaded. Clears the loop guard so a fresh list starts clean.
    func setChapters(_ chapters: [Chapter]) {
        currentChapters = chapters
        lastAutoSkipFromChapterIndex = nil
        chapterCount = chapters.count
        // Force a refresh: a fresh list means the cached index may now point at a
        // different chapter (or none), so don't let updateCurrentChapter's
        // same-index early-return keep a stale title.
        currentChapterIndex = nil
        updateCurrentChapter()
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
        let downloadPath = episode.localAudioURL?.path
        let descriptionHTML = episode.episodeDescription
        chapterLoadEpisodeGUID = guid
        Task { @MainActor [weak self] in
            guard let self else { return }
            let found = await self.chapterService.chapters(
                chapterURL: chapterURL,
                audioURL: audioURL,
                downloadPath: downloadPath,
                descriptionHTML: descriptionHTML
            )
            // Drop a stale load: only apply if this is still the loaded episode
            // and no newer load has superseded us.
            guard self.chapterLoadEpisodeGUID == guid,
                  self.currentEpisode?.guid == guid else { return }
            self.currentChapters = found
            self.lastAutoSkipFromChapterIndex = nil
            self.chapterCount = found.count
            // A fresh list invalidates the cached index; clear it so the refresh
            // below isn't suppressed by the same-index early-return.
            self.currentChapterIndex = nil
            self.updateCurrentChapter()
        }
    }

    /// Recomputes the observable ``currentChapterIndex`` / ``currentChapterTitle``
    /// from the live position. Called from the per-tick handler and whenever a new
    /// chapter list is installed. Cheap and idempotent: when the active chapter
    /// index hasn't changed it returns without touching `@Observable` state, so it
    /// can run every tick without churn (#508). Never announces — automatic
    /// chapter changes during playback update the label silently; only MANUAL
    /// previous/next announces (too chatty otherwise).
    private func updateCurrentChapter() {
        let activeIndex = currentChapters.activeChapterIndex(at: currentPositionSeconds)
        guard activeIndex != currentChapterIndex else { return }
        currentChapterIndex = activeIndex
        if let activeIndex, currentChapters.indices.contains(activeIndex) {
            currentChapterTitle = currentChapters[activeIndex].title
        } else {
            currentChapterTitle = nil
        }
    }

    /// Clears the observable chapter surface on an episode switch (before the new
    /// episode's chapters resolve). Paired with `currentChapters = []`.
    private func resetChapterObservables() {
        chapterCount = 0
        currentChapterIndex = nil
        currentChapterTitle = nil
    }

    /// Manual "Next chapter": seeks to the start of the chapter after the active
    /// one, by index, regardless of the per-episode skip set (a manual override).
    /// No-op when there are no chapters or already in the last chapter. Announces
    /// the chapter landed on for VoiceOver.
    func nextChapter() {
        guard !currentChapters.isEmpty else { return }
        let activeIndex = currentChapters.activeChapterIndex(at: currentPositionSeconds)
        guard let target = ChapterNavLogic.nextIndex(
            currentIndex: activeIndex,
            count: currentChapters.count
        ), currentChapters.indices.contains(target) else { return }
        seekToChapter(at: target)
    }

    /// Manual "Previous chapter": follows the common podcast-player convention —
    /// more than ``ChapterNavLogic/previousRestartThreshold`` seconds into the
    /// current chapter restarts it, otherwise steps to the prior chapter. Clamped
    /// at the first chapter (restarts it). No-op when there are no chapters.
    /// Navigates by index regardless of the skip set; announces for VoiceOver.
    func previousChapter() {
        guard !currentChapters.isEmpty else { return }
        let activeIndex = currentChapters.activeChapterIndex(at: currentPositionSeconds)
        let withinChapter: Double
        if let activeIndex, currentChapters.indices.contains(activeIndex) {
            withinChapter = currentPositionSeconds - currentChapters[activeIndex].startTime
        } else {
            withinChapter = 0
        }
        guard let target = ChapterNavLogic.previousIndex(
            currentIndex: activeIndex,
            count: currentChapters.count,
            positionWithinChapter: withinChapter
        ), currentChapters.indices.contains(target) else { return }
        seekToChapter(at: target)
    }

    /// VoiceOver custom-action entry points for chapter nav from the transport
    /// Skip back / Skip forward controls (#560). Unlike ``previousChapter()`` /
    /// ``nextChapter()`` — which silently no-op when the episode has no chapters —
    /// these give a clear spoken response so the rotor action never fails
    /// silently. When chapters exist they defer to the same seek+announce path.
    func nextChapterOrAnnounceNoChapters() {
        guard chapterCount > 0 else {
            Announcer.announce("This episode has no chapters")
            return
        }
        nextChapter()
    }

    func refreshPodcastDisplayName() {
        guard let currentEpisode, !currentEpisodeIsTransient else { return }
        currentArtist = currentEpisode.podcast?.displayName ?? currentEpisode.podcast?.author
        updateNowPlayingInfo()
    }

    func previousChapterOrAnnounceNoChapters() {
        guard chapterCount > 0 else {
            Announcer.announce("This episode has no chapters")
            return
        }
        previousChapter()
    }

    /// Seeks to a chapter's start and announces it. Shared by manual prev/next.
    /// `seek(to:)` updates `currentPositionSeconds` synchronously, so the
    /// follow-up `updateCurrentChapter()` reflects the new chapter immediately.
    private func seekToChapter(at index: Int) {
        let chapter = currentChapters[index]
        seek(to: chapter.startTime)
        updateCurrentChapter()
        Announcer.announce("Chapter: \(chapter.title)")
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

    private func configureSession() -> Bool {
        recordPlaybackDiagnostic("session.configure.begin")
        do {
            try audioSession.setCategory(
                .playback,
                // Podcasts are continuous spoken audio. Declaring that intent
                // tells iOS to pause Earshot, rather than mix it underneath,
                // when Siri or another short spoken prompt takes the route.
                mode: .spokenAudio,
                // Output-only playback already supports AirPlay and A2DP.
                // HFP is an input option and is invalid for this category.
                options: []
            )
            try audioSession.activate()
            recordPlaybackDiagnostic("session.activate.succeeded")
        } catch {
            let failure = error as NSError
            recordPlaybackDiagnostic("session.configure.failed domain=\(failure.domain) code=\(failure.code)")
            AppLog.player.error("Failed to configure audio session: \(error.localizedDescription, privacy: .public)")
            return false
        }
        // A route may not support the stereo preference. That does not undo
        // successful activation or prevent playback on a valid mono route.
        do { try audioSession.setPreferredOutputNumberOfChannels(2) }
        catch { recordPlaybackDiagnostic("session.channelPreference.failed") }
        return true
    }

    // MARK: Private — periodic time / persistence

    private func observePeriodicTime(playbackRate: Double = 1) {
        let mediaInterval = PlaybackLogic.mediaSeconds(
            forWallClockSeconds: 1,
            playbackRate: playbackRate
        )
        guard timeObserverMediaInterval != mediaInterval else { return }
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        timeObserverMediaInterval = mediaInterval
        let interval = CMTime(seconds: mediaInterval, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            // The observer is already delivered on the main queue, so run the
            // tick synchronously instead of allocating a `Task` and deferring a
            // runloop hop every second. Scaling the media-time interval to the
            // playback rate keeps this work near once per wall-clock second.
            MainActor.assumeIsolated {
                self.handleTick(currentSeconds: time.seconds)
            }
        }
    }

    private func handleTick(currentSeconds: Double) {
        guard currentSeconds.isFinite else { return }
        // AVPlayer can deliver a periodic callback carrying the pre-seek time
        // while its asynchronous seek is still settling. Publishing that sample
        // makes the scrubber, VoiceOver value, persistence, and CloudKit handoff
        // all bounce back. The seek completion performs the authoritative
        // reconciliation instead.
        guard pendingUserSeekTarget == nil else { return }
        currentPositionSeconds = currentSeconds

        // Belt-and-braces (#574): the loaded episode can be deleted out from
        // under the player (unfollow-while-playing, factory reset).
        // `stopAndUnload()` — driven by `.earshotWillDeleteEpisodes` — is the
        // primary defense; if a tick still lands on a deleted instance, never
        // read or write the model again. SwiftData traps on deleted-instance
        // mutation (or resurrects a zombie row). `isDeleted` itself is a
        // `PersistentModel` flag, safe to read on a deleted instance.
        let episodeWasDeleted = currentEpisode?.isDeleted == true
        if episodeWasDeleted { logDeletedEpisodeGuardOnce("periodic tick") }

        // Once AVPlayer has loaded the media, its duration is authoritative.
        // RSS durations are optional metadata and can be rounded or simply
        // wrong; retaining a stale feed duration can clamp ordinary skips too
        // early even when playable audio remains.
        if let itemDuration = player.currentItem?.duration.seconds,
           itemDuration.isFinite, itemDuration > 0,
           abs(durationSeconds - itemDuration) >= 0.5 {
            durationSeconds = itemDuration
            if !episodeWasDeleted {
                currentEpisode?.durationSeconds = Int(itemDuration)
            }
        }

        persistPositionThrottled(currentSecond: Int(currentSeconds))
        publishPositionProjectionThrottled(currentSecond: Int(currentSeconds))
        recordListeningTick()
        updateNowPlayingElapsedThrottled(currentSecond: Int(currentSeconds))
        // Chapter auto-skip reads the episode's guid; skip it on a deleted
        // instance. The chapter TITLE refresh below is model-free (positions
        // against the in-memory chapter list) and stays live.
        if !episodeWasDeleted {
            evaluateChapterAutoSkip()
        }
        updateCurrentChapter()

        guard !episodeWasDeleted else { return }
    }

    /// Logs the deleted-instance guard once per loaded episode (#574) so the
    /// per-second tick can't spam. Reset when a new episode loads or unloads.
    private func logDeletedEpisodeGuardOnce(_ sink: String) {
        guard !didLogDeletedEpisodeGuard else { return }
        didLogDeletedEpisodeGuard = true
        AppLog.player.debug(
            "Skipped \(sink, privacy: .public): the loaded episode was deleted from the store (#574)"
        )
    }

    // MARK: Live playback position — crash recovery without a per-tick store save (#736)

    enum LivePositionKey {
        static let episode = "live_playback_episode_key"
        static let seconds = "live_playback_seconds"
    }

    /// Records the in-flight playback position to `UserDefaults` (NOT SwiftData)
    /// on the ~5s tick. A `context.save()` there invalidates every live `@Query`
    /// — the Inbox screen re-materializes the whole unplayed backlog — which on a
    /// large library heated the phone during playback. This keeps ~5s
    /// crash-recovery granularity with no store write. Keyed by the same
    /// composite the last-playing-episode restore uses, so it's only ever honored
    /// for that exact episode.
    private func writeLivePosition(_ episode: Episode, second: Int) {
        let key = DownloadTaskKey.key(feedURL: episode.podcast?.feedURL, guid: episode.guid)
        let defaults = UserDefaults.standard
        defaults.set(key, forKey: LivePositionKey.episode)
        defaults.set(second, forKey: LivePositionKey.seconds)
    }

    private func clearLivePosition() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: LivePositionKey.episode)
        defaults.removeObject(forKey: LivePositionKey.seconds)
    }

    /// The UserDefaults live position stored for `episode`, or nil if the stored
    /// live position is for a different (or no) episode.
    private func livePosition(for episode: Episode) -> Int? {
        let key = DownloadTaskKey.key(feedURL: episode.podcast?.feedURL, guid: episode.guid)
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: LivePositionKey.episode) == key,
              defaults.object(forKey: LivePositionKey.seconds) != nil else { return nil }
        return defaults.integer(forKey: LivePositionKey.seconds)
    }

    /// The position to resume `episode` from: the durable SwiftData value, or the
    /// fresher UserDefaults live value if a crash left one for this same episode
    /// (#736). Prevents losing progress on a crash now that the ~5s tick no
    /// longer writes to the store.
    private func resumePosition(for episode: Episode) -> Int {
        max(episode.positionSeconds, livePosition(for: episode) ?? 0)
    }

    /// Durably persists position + listening session when the app backgrounds —
    /// a natural anchor now that the ~5s tick no longer writes to the store
    /// (#736). Saving here is off the visible view hot path, so the resulting
    /// `@Query` invalidation costs nothing the user can feel.
    func persistForBackground() {
        recordPlaybackDiagnostic("background")
        guard !releaseInvalidCurrentEpisodeIfNeeded() else { return }
        persistCurrentPosition()
        publishCurrentPlaybackHandoff()
        flushListeningSession()
    }

    // MARK: Direct CloudKit playback handoff

    private static let playbackHandoffFetchTimeoutNanoseconds: UInt64 = 1_500_000_000

    private func playbackHandoffIdentity(for episode: Episode) -> PlaybackHandoffIdentity? {
        PlaybackHandoffIdentity(feedURL: episode.podcast?.feedURL, guid: episode.guid)
    }

    /// Direct handoff is subscription state, not catalog state. Catalog-only
    /// episodes remain fully playable and durable on this device, but they must
    /// never fetch or publish the account-wide direct CloudKit record. Keeping
    /// raw identity construction separate lets callers still reason about the
    /// episode without treating this device's catalog status as permission to
    /// delete legitimate followed state written by another device.
    private func followedPlaybackHandoffIdentity(
        for episode: Episode
    ) -> PlaybackHandoffIdentity? {
        guard !episode.isDeleted, episode.podcast?.isFollowed == true else { return nil }
        return playbackHandoffIdentity(for: episode)
    }

    private func currentPlaybackHandoffSnapshot() -> PlaybackHandoffSnapshot? {
        guard playbackHandoff.isEnabled,
              !currentEpisodeIsTransient,
              let episode = currentEpisode,
              !episode.isDeleted,
              currentPositionSeconds.isFinite,
              let identity = followedPlaybackHandoffIdentity(for: episode) else { return nil }
        return PlaybackHandoffSnapshot(
            identity: identity,
            positionSeconds: Int(max(0, currentPositionSeconds)),
            playbackRate: currentEffectiveRate
        )
    }

    /// Uploads only at durable playback boundaries. This is intentionally absent
    /// from the periodic tick so direct handoff cannot create sustained radio,
    /// battery, or main-thread pressure on long listening sessions.
    private func publishCurrentPlaybackHandoff() {
        guard let episode = currentEpisode,
              let snapshot = currentPlaybackHandoffSnapshot() else { return }
        let client = playbackHandoff
        Task { @MainActor [weak self, weak episode] in
            // Task scheduling is itself a suspension boundary: Unfollow may
            // commit after the snapshot was formed but before this body starts.
            // Revalidate the captured episode immediately before the transport
            // call. It need not still be current (episode switches deliberately
            // publish the outgoing boundary), but it must still be a live,
            // followed episode with the exact same natural identity.
            guard let self, let episode,
                  self.followedPlaybackHandoffIdentity(for: episode) == snapshot.identity else {
                return
            }
            do {
                try await client.publish(snapshot)
                AppLog.data.debug(
                    "Published direct playback handoff at second \(snapshot.positionSeconds, privacy: .public)"
                )
            } catch is CancellationError {
                // The client persisted the pending boundary before network I/O.
            } catch {
                AppLog.data.info(
                    "Direct playback handoff upload deferred: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func fetchPlaybackHandoff(
        identity: PlaybackHandoffIdentity
    ) async -> PlaybackHandoffSnapshot? {
        let client = playbackHandoff
        return await withCheckedContinuation { continuation in
            let race = PlaybackHandoffFetchRace(continuation)
            Task {
                do {
                    let snapshot = try await client.fetchLatest(for: identity)
                    await race.resolve(snapshot)
                } catch is CancellationError {
                    await race.resolve(nil)
                } catch {
                    AppLog.data.info(
                        "Direct playback handoff fetch fell back to local state: \(error.localizedDescription, privacy: .public)"
                    )
                    await race.resolve(nil)
                }
            }
            Task {
                try? await Task.sleep(
                    nanoseconds: Self.playbackHandoffFetchTimeoutNanoseconds
                )
                await race.resolve(nil)
            }
        }
    }

    private func applyFetchedHandoff(
        _ snapshot: PlaybackHandoffSnapshot,
        to episode: Episode
    ) {
        // Recheck after the network suspension as a final defense even though
        // both fetch callers also revalidate. A catalog transition must never
        // apply a response that was authorized by an earlier followed state.
        guard followedPlaybackHandoffIdentity(for: episode) == snapshot.identity else { return }
        let position = snapshot.positionSeconds
        episode.positionSeconds = position
        handoffRateOverride = snapshot.playbackRate
        player.seek(to: CMTime(seconds: Double(position), preferredTimescale: 1))
        currentPositionSeconds = Double(position)
        lastPersistedSecond = position
        lastProjectedSecond = position
        lastNowPlayingSyncSecond = nil
        writeLivePosition(episode, second: position)
        _ = saveContext()
        applyRate()
    }

    private func beginHandoffOperation() {
        playbackHandoffGeneration &+= 1
        playbackHandoffTask?.cancel()
        playbackHandoffTask = nil
    }

    private func cancelHandoffOperation() {
        beginHandoffOperation()
    }

    /// Eagerly writes the current position to disk (used by pause, seek, episode
    /// switch, and app-background — the durability anchors). Resets the per-tick
    /// throttle so the next tick doesn't redundantly re-save the same second.
    @discardableResult
    private func persistCurrentPosition() -> Bool {
        // A transient Search-preview stream is never persisted (#517).
        guard !currentEpisodeIsTransient else { return true }
        guard let episode = currentEpisode, currentPositionSeconds.isFinite else { return true }
        // Never write to a deleted instance (#574) — SwiftData traps.
        guard !episode.isDeleted else {
            logDeletedEpisodeGuardOnce("position persist")
            return false
        }
        // Same stale-write defense as the throttled tick (issue #653). An
        // explicit Mark as Played can zero the position while an in-flight player
        // clock still reports the old value. Once played, there is nothing left
        // to persist.
        guard !episode.isPlayed else { return true }
        let second = Int(max(0, currentPositionSeconds))
        episode.positionSeconds = second
        lastPersistedSecond = second
        guard saveContext() else { return false }
        // Keep the UserDefaults live position in step with the durable value so a
        // seek/pause can't leave a stale (larger) live value that resume would
        // wrongly prefer (#736).
        writeLivePosition(episode, second: second)
        return true
    }

    /// Per-tick position write, throttled to ``PlaybackLogic/positionPersistInterval``
    /// so the synchronous `context.save()` doesn't run every second and stall the
    /// main run loop (issue #362). The observed `currentPositionSeconds` and the
    /// lock-screen elapsed time still update every tick — only the SwiftData
    /// write is coarsened.
    private func persistPositionThrottled(currentSecond: Int) {
        // A transient Search-preview stream is never persisted (#517).
        guard !currentEpisodeIsTransient else { return }
        guard let episode = currentEpisode else { return }
        // Never write to a deleted instance (#574) — SwiftData traps.
        guard !episode.isDeleted else {
            logDeletedEpisodeGuardOnce("throttled position persist")
            return
        }
        guard PlaybackLogic.shouldPersistTick(
            currentSecond: currentSecond,
            lastPersistedSecond: lastPersistedSecond,
            interval: Int(ceil(PlaybackLogic.mediaSeconds(
                forWallClockSeconds: Double(PlaybackLogic.positionPersistInterval),
                playbackRate: timeObserverMediaInterval ?? currentEffectiveRate
            ))),
            isPlayed: episode.isPlayed
        ) else { return }
        lastPersistedSecond = currentSecond
        // #736: do NOT `context.save()` on the playback tick. A save invalidates
        // every live `@Query` and, on a large library, re-materializes the whole
        // unplayed backlog (Inbox screen) every ~5s — sustained main-thread work
        // that ran the phone hot. Record the position to UserDefaults instead;
        // the durable SwiftData write happens at the anchors (pause / seek /
        // switch / background), and `resumePosition` reads this back after a
        // crash so we still recover within ~5s.
        writeLivePosition(episode, second: max(0, currentSecond))
    }

    /// Publishes only a value snapshot to the compact CloudKit projection. It
    /// does not mutate or save the application `ModelContext`; consequently the
    /// large Inbox/Library query graph receives no invalidation on this path.
    private func publishPositionProjectionThrottled(currentSecond: Int) {
        guard !currentEpisodeIsTransient,
              let episode = currentEpisode,
              !episode.isDeleted,
              !episode.isPlayed else { return }
        guard PlaybackLogic.shouldProjectPlaybackPosition(
            currentSecond: currentSecond,
            lastProjectedSecond: lastProjectedSecond,
            playbackRate: currentEffectiveRate
        ) else { return }
        guard let snapshot = EpisodeUserStateSnapshot(
            episode: episode,
            positionSeconds: currentSecond
        ) else { return }
        lastProjectedSecond = currentSecond
        postEpisodeUserStateSnapshots([snapshot])
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
        // A transient Search-preview stream never records a ListeningSession —
        // this is the real pollution vector, since `context.insert(session)`
        // references the current episode and would pull the detached preview
        // Episode into the store (#517). Just discard the accumulator.
        guard !currentEpisodeIsTransient else {
            accumulatedListenSeconds = 0
            return
        }
        guard let episode = currentEpisode, let context else {
            accumulatedListenSeconds = 0
            return
        }
        // Never insert a ListeningSession referencing a deleted instance
        // (#574) — the insert would resurrect a zombie row or trap on save.
        guard !episode.isDeleted else {
            logDeletedEpisodeGuardOnce("listening-session flush")
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
        NotificationCenter.default.post(name: .earshotListeningHistoryDidChange, object: nil)
    }

    /// Resets per-episode tick tracking when a new episode loads.
    private func resetListeningTracking() {
        lastTickPosition = currentPositionSeconds
        accumulatedListenSeconds = 0
        // Force the next tick to persist this episode's first position.
        lastPersistedSecond = nil
        // Periodic Cloud publication begins after one full bounded interval;
        // play/load itself must not manufacture an immediate zero-position row.
        lastProjectedSecond = Int(max(0, currentPositionSeconds))
    }

    private func markCurrentEpisodePlayed() {
        // A transient Search-preview stream is never marked played in the store
        // (#517); it has no store row to update.
        guard !currentEpisodeIsTransient else { return }
        guard let episode = currentEpisode else { return }
        // Never write to a deleted instance (#574) — SwiftData traps.
        guard !episode.isDeleted else {
            logDeletedEpisodeGuardOnce("mark played")
            return
        }
        episode.isPlayed = true
        episode.positionSeconds = 0
        currentPositionSeconds = 0
        // Auto-delete the download once played, when the user opted in. Uses the
        // player's own context so it lands in the same saveContext() below.
        if let context {
            DownloadCleanup.removeDownloadAfterPlayedIfEnabled(episode, in: context)
        }
        saveContext()
        publishCurrentPlaybackHandoff()
        postEpisodeUserStateChanges([episode], playedChangedExplicitly: true)
        // The finished episode just left the inbox — refresh the tab badge
        // (the badge no longer polls on every position save, #736).
        NotificationCenter.default.post(name: .earshotInboxDidChange, object: nil)
        AppLog.player.info("Marked episode played: \(episode.title, privacy: .public)")
    }

    private func persistLastPlayingEpisode(_ episode: Episode) {
        // A transient Search-preview stream must not be remembered as the last
        // playing episode — its guid isn't in the store, so restoring it on
        // relaunch would find nothing (#517).
        guard !currentEpisodeIsTransient else { return }
        // Composite "feedURL|guid" (#576): feed-level guids repeat across
        // podcasts, so a bare guid could restore the wrong show's episode.
        // Readers (PlaybackStartup, FeedRefreshActor) still resolve legacy
        // bare-guid values by guid alone.
        settings?.setRawValue(
            DownloadTaskKey.key(feedURL: episode.podcast?.feedURL, guid: episode.guid),
            for: SettingsKey.lastPlayingEpisodeID
        )
    }

    @discardableResult
    private func saveContext() -> Bool {
        guard let context else { return false }
        guard context.hasChanges else { return true }
        do {
            try context.save()
            if let currentEpisode {
                // The five-second tick lives in UserDefaults, so the Episode row
                // can be intentionally stale during playback. Never let an
                // unrelated context save publish that stale value as an explicit
                // rewind over the newer compact projection.
                let position = currentEpisode.isPlayed
                    ? 0 : Int(max(0, currentPositionSeconds))
                if let snapshot = EpisodeUserStateSnapshot(
                    episode: currentEpisode,
                    positionSeconds: position
                ) {
                    lastProjectedSecond = position
                    postEpisodeUserStateSnapshots([snapshot])
                }
            }
            return true
        } catch {
            AppLog.player.error("Failed to persist playback state: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: Private — item completion

    private func observeItemDidPlayToEnd() {
        didFinishObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let reported = notification.object as? AVPlayerItem
            MainActor.assumeIsolated {
                guard let self else { return }
                let expected = self.player.currentItem
                if let reported, reported !== expected { return }
                Task { @MainActor [weak self, weak expected] in
                    guard let self, let expected, expected === self.player.currentItem else { return }
                    self.handlePlaybackEnded()
                }
            }
        }
    }

    private func handlePlaybackEnded() {
        guard !releaseInvalidCurrentEpisodeIfNeeded() else { return }
        guard let finished = currentEpisode, let context else {
            isPlaying = false
            intendsToPlay = false
            markCurrentEpisodePlayed()
            updateNowPlayingInfo()
            return
        }

        guard !automaticPlaybackStoppedByTimer else { return }
        let stopsFolderRun = sleepTimer.endOfEpisode || stopAfterCurrentEpisode
        if folderRuns.completeCurrent(finished, continuePlayback: !stopsFolderRun) {
            if sleepTimer.endOfEpisode {
                sleepTimer.episodeEnded()
                Announcer.announce("Sleep timer ended. Playback stopped.")
            } else if stopAfterCurrentEpisode {
                stopAfterCurrentEpisode = false
                Announcer.announce("Stopped after this episode")
            }
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
            intendsToPlay = false
            clearNowPlayingPresentation()
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
            intendsToPlay = false
            clearNowPlayingPresentation()
            Announcer.announce("Stopped after this episode")
            return
        }

        let queued = repo.queue()
        let nextID = nextAdvanceID(after: finished, in: queued, allowsWrapping: true)
        let nextEpisode = queued.first { $0.persistentModelID == nextID }

        // The finished episode: mark played and remove it from the queue. Reset
        // its position since it played to the end.
        guard repo.markPlayedAndRemove(finished) else {
            pause(providesPauseHaptic: false)
            Announcer.announce("Could not save episode completion. Playback stopped.")
            return
        }
        finished.positionSeconds = 0
        guard saveContext() else {
            pause(providesPauseHaptic: false)
            Announcer.announce("Could not save episode completion. Playback stopped.")
            return
        }

        guard let nextEpisode else {
            // Episode finished with nothing queued after it: stop and hide the
            // mini player instead of leaving it on a finished episode (#730).
            // Announce completion explicitly — without it a VoiceOver listener
            // hears only the root-level "Paused" and can't tell an episode ended
            // from an accidental pause of a bar that just vanished.
            isPlaying = false
            intendsToPlay = false
            clearNowPlayingPresentation()
            completedPlaybackStopID = UUID()
            Announcer.announce("Episode finished")
            return
        }
        guard PlaybackLogic.resolvePlaybackURL(
            downloadPath: nextEpisode.localAudioURL?.path, audioURL: nextEpisode.audioURL
        ) != nil else {
            isPlaying = false
            intendsToPlay = false
            clearNowPlayingPresentation()
            Announcer.announce("Could not play \(nextEpisode.title). No usable audio source.")
            return
        }
        // We're advancing to it now, so its Play-next override is spent.
        playNextOverrides.remove(nextEpisode.persistentModelID)

        // Use the pre-buffered item when it's still the right one.
        let prepared = preloadedEpisode?.persistentModelID == nextEpisode.persistentModelID
            ? preloadedItem : nil
        preloadedItem = nil
        preloadedEpisode = nil
        play(
            nextEpisode,
            preparedItem: prepared,
            originEvent: playbackOriginAdvanceEvent(to: nextEpisode),
            automaticallyAdvancing: true
        )
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
        if folderRuns.driving { clearPreload(); return }
        guard let context, let current = currentEpisode else {
            clearPreload()
            return
        }
        let queued = QueueRepository(context: context).queue()
        let nextID = nextAdvanceID(after: current, in: queued, allowsWrapping: true)
        guard let next = queued.first(where: { $0.persistentModelID == nextID }) else {
            clearPreload()
            return
        }
        // Already buffering the right episode — nothing to do.
        if preloadedEpisode?.persistentModelID == next.persistentModelID { return }
        guard let url = PlaybackLogic.resolvePlaybackURL(
            downloadPath: next.localAudioURL?.path,
            audioURL: next.audioURL
        ) else {
            clearPreload()
            return
        }
        // An HTTP enclosure must pass the HTTPS probe (and, when necessary, the
        // approved warning) at the actual episode boundary. Preloading it here
        // would create an AVPlayerItem that bypasses that decision (#709).
        guard url.scheme?.lowercased() != "http" else {
            clearPreload()
            return
        }
        preloadedItem = makePlayerItem(url: url)
        preloadedEpisode = next
    }

    private func clearPreload() {
        preloadedItem = nil
        preloadedEpisode = nil
    }

    // MARK: Private — audio processing

    private func observeVolumeBoostSetting() {
        volumeBoostSettingObserver = NotificationCenter.default.addObserver(
            forName: .earshotVolumeBoostSettingDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.currentVolumeBoostOverride == nil,
                      let item = self.player.currentItem else { return }
                self.applyAudioProcessing(to: item)
            }
        }
    }

    private func observeSkipSilenceSetting() {
        skipSilenceSettingObserver = NotificationCenter.default.addObserver(
            forName: .earshotSkipSilenceSettingDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let changedFeedURL = notification.object as? String
            Task { @MainActor [weak self] in
                guard let self, let item = self.player.currentItem else { return }
                if let feedURL = changedFeedURL,
                   feedURL != self.currentEpisode?.podcast?.feedURL { return }
                if changedFeedURL == nil,
                   self.currentEpisode?.podcast?.trimSilenceOverride != nil { return }
                self.applyAudioProcessing(to: item)
            }
        }
    }

    /// Replaces the item's immutable tap whenever the resolved level changes.
    /// Unsupported streams keep playing through AVPlayer's untouched baseline.
    private func applyAudioProcessing(to item: AVPlayerItem) {
        audioProcessingGeneration &+= 1
        let generation = audioProcessingGeneration
        let level = effectiveVolumeBoost
        let trimsSilence = effectiveSilenceTrimming
        collectAudioProcessingMetrics()
        guard level != .off || trimsSilence else {
            currentAudioProcessingMetrics = nil
            item.audioMix = nil
            return
        }
        let metrics = trimsSilence ? AudioProcessingMetrics() : nil
        let configuration = AudioProcessingConfiguration(
            gainLimiter: level.processingConfiguration,
            silenceTrimming: trimsSilence ? SilenceDetectionConfiguration() : nil
        )
        Task { @MainActor [weak self, weak item] in
            guard let self, let item else { return }
            do {
                let mix = try await AudioProcessingTapFactory.makeFileAudioMix(
                    asset: item.asset,
                    configuration: configuration,
                    metrics: metrics
                )
                guard self.audioProcessingGeneration == generation,
                      self.player.currentItem === item else { return }
                self.currentAudioProcessingMetrics = metrics
                item.audioMix = mix
            } catch {
                guard self.audioProcessingGeneration == generation,
                      self.player.currentItem === item else { return }
                self.currentAudioProcessingMetrics = nil
                item.audioMix = nil
                AppLog.player.notice(
                    "Audio processing unavailable for this media; using baseline playback: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func collectAudioProcessingMetrics() {
        guard let metrics = currentAudioProcessingMetrics else { return }
        silenceTrimmedSecondsThisSession += metrics.consumeDiscardedSeconds()
    }

    // MARK: Private — interruptions & route changes (PRD 5.5)

    private func observeNotifications() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: audioSession.notificationObject,
            queue: .main
        ) { [weak self] note in
            let typeValue = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsValue = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            let reason = note.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt
            Task { @MainActor in
                self?.recordPlaybackDiagnostic("interruption type=\(String(describing: typeValue)) options=\(String(describing: optionsValue)) reason=\(String(describing: reason))")
                self?.handleInterruption(typeValue: typeValue, optionsValue: optionsValue)
            }
        }
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: audioSession.notificationObject,
            queue: .main
        ) { [weak self] note in
            let reasonValue = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor in self?.handleRouteChange(reasonValue: reasonValue) }
        }
        // Pre-delete hook (#574). Identity repair also posts from its background
        // ModelActor, so force delivery onto the main queue. NotificationCenter
        // waits for the queued observer before `post` returns, preserving the
        // contract that the player fully unloads before `context.delete` runs.
        deletionObserver = NotificationCenter.default.addObserver(
            forName: .earshotWillDeleteEpisodes,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let podcastID = note.userInfo?[Self.willDeletePodcastIDKey] as? PersistentIdentifier
            let episodeIDs = note.userInfo?[Self.willDeleteEpisodeIDsKey]
                as? Set<PersistentIdentifier>
            MainActor.assumeIsolated {
                self?.handleWillDeleteEpisodes(
                    podcastID: podcastID,
                    episodeIDs: episodeIDs ?? []
                )
            }
        }
        folderDeletionObserver = NotificationCenter.default.addObserver(
            forName: .earshotFoldersDidDelete,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let ids = note.userInfo?[FolderRepository.deletedFolderIDsKey]
                    as? Set<PersistentIdentifier> else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.playbackOrigin = PlaybackLogic.playbackOrigin(
                    after: .foldersDeleted(ids),
                    current: self.playbackOrigin
                )
            }
        }
        cloudProjectionObserver = NotificationCenter.default.addObserver(
            forName: .earshotCloudProjectionDidApply,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshProjectedPlaybackPosition()
                self?.refreshProjectedPlaybackRate()
            }
        }
    }

    /// Reconciles the player-owned presentation cache with the episode row that
    /// CloudKit just updated. This is intentionally independent of view state:
    /// the Now Playing scrubber and its existing VoiceOver value both observe
    /// `currentPositionSeconds`, so updating that single source refreshes every
    /// open presentation without changing accessibility semantics.
    ///
    /// While paused, follow the projected row exactly so explicit remote rewinds
    /// work. While playing or buffering with playback intent, never move behind
    /// the live local clock: its per-tick position lives in UserDefaults and can
    /// legitimately be ahead of the coarsely persisted SwiftData row (#736).
    func refreshProjectedPlaybackPosition() {
        guard !releaseInvalidCurrentEpisodeIfNeeded(),
              !currentEpisodeIsTransient,
              pendingUserSeekTarget == nil,
              let episode = currentEpisode,
              let context else { return }
        // A CloudKit import may be saved through a different ModelContext. The
        // player deliberately retains its loaded Episode for the lifetime of the
        // AVPlayer item, so that instance can still expose its pre-import value
        // even though the durable row is already current. Resolve the same row
        // by its stable identifier in a fresh context before refreshing the
        // observable player cache (#825, physical iPhone-to-Mac verification).
        let persistedContext = ModelContext(context.container)
        let episodeID = episode.persistentModelID
        var descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate { $0.persistentModelID == episodeID }
        )
        descriptor.fetchLimit = 1
        guard let persistedEpisode = try? persistedContext.fetch(descriptor).first else {
            unloadWithoutPersisting()
            return
        }
        let target = PlaybackLogic.projectedPlaybackPosition(
            current: currentPositionSeconds,
            projected: persistedEpisode.positionSeconds,
            isActivelyPlaying: intendsToPlay
        )
        guard target != currentPositionSeconds else { return }
        player.seek(to: CMTime(seconds: target, preferredTimescale: 1))
        currentPositionSeconds = target
        lastPersistedSecond = Int(target)
        lastNowPlayingSyncSecond = nil
        writeLivePosition(episode, second: Int(target))
        updateNowPlayingInfo()
    }

    /// Reconciles the loaded player's per-podcast speed with the durable row
    /// after CloudKit imports through another `ModelContext`. The retained
    /// `Episode` graph can otherwise keep its pre-import `speedOverride`, so a
    /// cross-device handoff resumes at the right position but the wrong rate.
    /// Reapplying while paused updates `AVPlayer.defaultRate`; reapplying while
    /// playing also changes the live rate without restarting the episode.
    func refreshProjectedPlaybackRate() {
        guard !releaseInvalidCurrentEpisodeIfNeeded(),
              !currentEpisodeIsTransient,
              let episode = currentEpisode,
              let loadedPodcast = episode.podcast,
              let context else { return }
        let persistedContext = ModelContext(context.container)
        let episodeID = episode.persistentModelID
        var descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate { $0.persistentModelID == episodeID }
        )
        descriptor.fetchLimit = 1
        guard let persistedEpisode = try? persistedContext.fetch(descriptor).first,
              let persistedPodcast = persistedEpisode.podcast else { return }
        let projectedOverride = persistedPodcast.speedOverride
        guard loadedPodcast.speedOverride != projectedOverride else { return }
        handoffRateOverride = nil
        loadedPodcast.speedOverride = projectedOverride
        applyRate()
    }

    /// Reacts to `.earshotWillDeleteEpisodes` (#574). With a podcast ID in
    /// userInfo (unsubscribe): if the CURRENT episode belongs to that podcast,
    /// stop and unload; if only the gapless PRELOAD does, just drop the preload
    /// and leave unrelated playback running. With no podcast ID (factory
    /// reset): stop unconditionally when anything is loaded.
    private func handleWillDeleteEpisodes(
        podcastID doomedPodcastID: PersistentIdentifier?,
        episodeIDs doomedEpisodeIDs: Set<PersistentIdentifier>
    ) {
        if !doomedEpisodeIDs.isEmpty {
            let currentMatches = currentEpisode.map {
                doomedEpisodeIDs.contains($0.persistentModelID)
            } ?? false
            let preloadMatches = preloadedEpisode.map {
                doomedEpisodeIDs.contains($0.persistentModelID)
            } ?? false
            guard currentMatches || preloadMatches else { return }
            guard currentMatches else {
                clearPreload()
                return
            }
            stopAndUnload()
            return
        }
        if let doomedPodcastID {
            let currentMatches = currentEpisode?.podcast?.persistentModelID == doomedPodcastID
            let preloadMatches = preloadedEpisode?.podcast?.persistentModelID == doomedPodcastID
            guard currentMatches || preloadMatches else { return }
            guard currentMatches else {
                AppLog.player.info("Dropping gapless preload: its podcast is being unfollowed (#574)")
                clearPreload()
                return
            }
            AppLog.player.info("Stopping playback: the playing podcast is being unfollowed (#574)")
        } else {
            guard currentEpisode != nil || preloadedEpisode != nil else { return }
            AppLog.player.info("Stopping playback: all local data is being deleted (#574)")
        }
        stopAndUnload()
    }

    private func handleInterruption(typeValue: UInt?, optionsValue: UInt?) {
        guard let typeValue,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            // AVPlayer may already have stopped its transport before this
            // callback arrives, so preserve the user's pre-interruption intent
            // instead of consulting only the presentation flag.
            if isPlaying || intendsToPlay {
                pause(providesPauseHaptic: false)
                pausedByInterruption = true
            }
        case .ended:
            // Missing options means the system did not authorize resumption.
            // Always consume the one-shot flag so a later unrelated end event
            // cannot revive stale playback intent.
            defer { pausedByInterruption = false }
            guard let optionsValue else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume), pausedByInterruption {
                resume(providesStartHaptic: false)
            }
        @unknown default:
            break
        }
    }

    private func handleRouteChange(reasonValue: UInt?) {
        recordPlaybackDiagnostic("route.change reason=\(String(describing: reasonValue))")
        guard let reasonValue,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }
        // Headphones / Bluetooth unplugged: pause FIRST so audio doesn't blast
        // aloud on the speaker. This must not be delayed by the AVAudioSession
        // work below.
        if reason == .oldDeviceUnavailable, isPlaying {
            pause(providesPauseHaptic: false)
        }
        // The baseline stereo session needs no route-change reconfiguration.
        // Avoiding live session churn preserves the build-150 crash fix (#695).
    }

    // MARK: Private — streaming stall recovery (#522)

    /// Installs the player-level stall resilience: explicitly opts into automatic
    /// stall-minimizing buffering, watches `timeControlStatus` so we notice when
    /// the player settles into `.paused` (or sits `.waitingToPlayAtSpecifiedRate`),
    /// and listens for the per-item stall notification. Per-item buffer KVO is
    /// added separately in ``observeCurrentItem(_:)`` as items are replaced.
    ///
    /// Buffer policy: `automaticallyWaitsToMinimizeStalling = true` lets AVPlayer
    /// adaptively size its forward buffer. We deliberately leave
    /// `preferredForwardBufferDuration` at its default (0 = automatic) on each
    /// item: a fixed large value raises startup latency and memory, while a fixed
    /// small value invites more frequent rebuffering. AVPlayer's adaptive buffering
    /// plus the auto-resume below is the lower-risk combination, so we don't pin a
    /// guessed value.
    private func observeStallRecovery() {
        player.automaticallyWaitsToMinimizeStalling = true
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.handleTimeControlStatusChanged() }
        }
        stallObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.playbackStalledNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handlePlaybackStalled() }
        }
    }

    /// Adds buffer KVO for the newly set item, tearing down the previous item's
    /// observers first so there are no dangling KVO registrations (which crash on
    /// dealloc) and no leaks. Called right after every `replaceCurrentItem`.
    private func observeCurrentItem(_ item: AVPlayerItem) {
        bufferEmptyObservation?.invalidate()
        likelyToKeepUpObservation?.invalidate()
        itemStatusObservation?.invalidate()
        bufferEmptyObservation = item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.handleBufferEmptyChanged() }
        }
        likelyToKeepUpObservation = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.handleLikelyToKeepUpChanged() }
        }
        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self, weak item] _, _ in
            Task { @MainActor in
                guard let self, let item, item === self.player.currentItem,
                      item.status == .failed else { return }
                self.handleUnplayableCurrentItem()
            }
        }
        if let failedToEndObserver {
            NotificationCenter.default.removeObserver(failedToEndObserver)
        }
        failedToEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleUnplayableCurrentItem()
            }
        }
    }

    /// A downloaded copy gets one automatic escape to the current enclosure.
    /// Remote failures never recurse: they remain visible and actionable.
    private func handleUnplayableCurrentItem() {
        guard let episode = currentEpisode, !currentEpisodeIsTransient else {
            surfacePlaybackFailure()
            return
        }
        let episodeID = episode.persistentModelID
        if mediaRecoveryInProgressEpisodeID == episodeID { return }
        guard currentPlaybackURL?.isFileURL == true else {
            let unavailable = player.currentItem?.errorLog()?.events.contains {
                $0.errorStatusCode == 404 || $0.errorStatusCode == 410
            } == true
            folderRuns.playbackFailed(episode, unavailable: unavailable)
            // A normal remote stream can fail transiently while the player is
            // still resolving or buffering it. Only surface a remote failure
            // when it is the retry from a known-bad downloaded copy.
            if mediaRecoveryAttemptedEpisodeID == episodeID {
                surfacePlaybackFailure()
            }
            return
        }
        guard mediaRecoveryAttemptedEpisodeID != episodeID else {
            surfacePlaybackFailure()
            return
        }
        mediaRecoveryAttemptedEpisodeID = episodeID
        mediaRecoveryInProgressEpisodeID = episodeID
        mediaRecoveryGeneration &+= 1
        let generation = mediaRecoveryGeneration
        let resumePosition = currentPositionSeconds
        let shouldResume = intendsToPlay
        let feedURL = episode.podcast?.feedURL
        let guid = episode.guid
        let staleLocalURL = episode.localAudioURL

        player.pause()
        episode.downloadPath = nil
        if let context {
            ActiveDownload.setDownloadStatus(.none, on: episode, in: context)
            guard saveContext() else {
                surfacePlaybackFailure()
                return
            }
        }
        if let staleLocalURL { try? FileManager.default.removeItem(at: staleLocalURL) }
        Announcer.announce("The downloaded copy could not play. Trying the current episode audio.")

        Task { @MainActor [weak self, weak episode] in
            guard let self, let episode, !episode.isDeleted else { return }
            var correctedItem: ParsedEpisode?
            if let feedURL {
                correctedItem = try? await self.mediaRecoveryFeed.fetch(feedURL)
                    .episodes.first { $0.guid == guid }
            }
            guard self.mediaRecoveryGeneration == generation,
                  self.currentEpisode === episode else { return }
            if let item = correctedItem {
                self.applyRecoveredMetadata(item, to: episode)
                _ = self.saveContext()
            }
            guard !episode.audioURL.isEmpty else {
                self.mediaRecoveryInProgressEpisodeID = nil
                self.surfacePlaybackFailure()
                return
            }
            self.play(
                episode,
                preparedItem: nil,
                originEvent: .continuedCurrentEpisode,
                startSecondsOverride: resumePosition
            )
            self.mediaRecoveryInProgressEpisodeID = nil
            if !shouldResume {
                self.pause(providesPauseHaptic: false)
            }
        }
    }

    private func applyRecoveredMetadata(_ item: ParsedEpisode, to episode: Episode) {
        if !item.title.isEmpty { episode.title = item.title }
        if !item.audioURL.isEmpty { episode.audioURL = item.audioURL }
        if let value = item.description { episode.episodeDescription = value }
        if let value = item.durationSeconds { episode.durationSeconds = value }
        if let value = item.pubDate { episode.pubDate = value }
        if let value = item.artworkURL { episode.artworkURL = value }
        if let value = item.episodeNumber { episode.episodeNumber = value }
        if let value = item.seasonNumber { episode.seasonNumber = value }
        if let value = item.chapterURL { episode.chapterURL = value }
        if let value = item.transcriptURL { episode.transcriptURL = value }
    }

    private func surfacePlaybackFailure() {
        guard playbackFailureMessage == nil else { return }
        mediaRecoveryInProgressEpisodeID = nil
        isPlaying = false
        intendsToPlay = false
        let message = "This episode’s audio could not be played. Refresh the episode audio and try again."
        playbackFailureMessage = message
        Announcer.announce(message, assertive: true)
        updateNowPlayingInfo()
    }

    /// Explicit recovery for valid-but-wrong media that AVFoundation cannot
    /// distinguish automatically (for example, silence at an unchanged URL).
    func refreshEpisodeAudio(
        _ episode: Episode,
        using downloads: DownloadManager? = nil
    ) async {
        guard let feedURL = episode.podcast?.feedURL else {
            Announcer.announce("Could not refresh this episode’s audio")
            return
        }
        Announcer.announce("Refreshing episode audio")
        do {
            let feed = try await mediaRecoveryFeed.fetch(feedURL)
            guard let item = feed.episodes.first(where: { $0.guid == episode.guid }) else {
                throw FeedError.parse
            }
            let restoreDownloadIntent = episode.downloadStatus == .downloaded
                || episode.downloadStatus == .downloading
                || episode.downloadStatus == .pending
            let staleDownloadPath = episode.downloadPath
            let staleLocalURL = episode.localAudioURL
            episode.downloadPath = nil
            if let context {
                ActiveDownload.setDownloadStatus(.none, on: episode, in: context)
            }
            applyRecoveredMetadata(item, to: episode)
            guard saveContext() else { throw FeedError.parse }
            if let downloads {
                await downloads.replaceCorrectedMedia([
                    CorrectedEpisodeMedia(
                        episodeID: episode.persistentModelID,
                        restoreDownloadIntent: restoreDownloadIntent,
                        staleDownloadPath: staleDownloadPath
                    )
                ])
            } else if let staleLocalURL {
                try? FileManager.default.removeItem(at: staleLocalURL)
            }
            if currentEpisode === episode {
                let position = currentPositionSeconds
                let shouldResume = intendsToPlay
                mediaRecoveryAttemptedEpisodeID = episode.persistentModelID
                play(
                    episode,
                    preparedItem: nil,
                    originEvent: .continuedCurrentEpisode,
                    startSecondsOverride: position
                )
                if !shouldResume { pause(providesPauseHaptic: false) }
            }
            playbackFailureMessage = nil
            Announcer.announce("Episode audio refreshed")
        } catch {
            Announcer.announce("Could not refresh this episode’s audio")
        }
    }

    private func handleTimeControlStatusChanged() {
        if player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
            let reason = player.reasonForWaitingToPlay?.rawValue ?? "unknown"
            AppLog.player.info("Player waiting to play (reason: \(reason, privacy: .public))")
        }
        // Sync the display flag when the player actually reaches `.playing`
        // without an explicit resume having set it — most notably automatic stall
        // recovery, which re-issues `player.play()` but never touches `isPlaying`.
        // Left unsynced, the flag reads stale-`false` while audio plays, which
        // feeds the toggle/now-playing-rate drift the Bluetooth pause fix
        // addresses. `intendsToPlay` gates out a brief post-pause `.playing` blip.
        if PlaybackLogic.shouldMarkPlayingOnTransition(
            playerIsPlaying: player.timeControlStatus == .playing,
            intendsToPlay: intendsToPlay,
            currentlyMarkedPlaying: isPlaying
        ) {
            isPlaying = true
            updateNowPlayingInfo()
        }
        attemptStallRecovery()
    }

    private func handlePlaybackStalled() {
        AppLog.player.info("Playback stalled; will auto-resume when the buffer recovers if still intended")
        attemptStallRecovery()
    }

    private func handleBufferEmptyChanged() {
        if player.currentItem?.isPlaybackBufferEmpty == true {
            AppLog.player.info("Playback buffer empty; waiting for it to refill")
        }
        attemptStallRecovery()
    }

    private func handleLikelyToKeepUpChanged() {
        attemptStallRecovery()
    }

    /// Re-issues `play()` exactly when ``StallRecoveryLogic`` says we should: the
    /// user still intends playback, the player has settled into `.paused` after a
    /// stall, and the buffer can sustain playback again. The `.paused` gate means
    /// one recovery flips the player to `.playing`, so repeat observer callbacks
    /// no-op — no busy loop, no repeated hammering. `applyRate()` restores the
    /// exact effective (or fast-forward) rate the user was at.
    private func attemptStallRecovery() {
        guard currentEpisode != nil, let item = player.currentItem else { return }
        guard StallRecoveryLogic.shouldResume(
            intendedToPlay: intendsToPlay,
            isLikelyToKeepUp: item.isPlaybackLikelyToKeepUp,
            timeControlStatus: player.timeControlStatus
        ) else { return }
        AppLog.player.info("Stall recovery: buffer recovered, resuming playback")
        player.play()
        applyRate()
        updateNowPlayingInfo()
    }

    // MARK: Private — Now Playing info

    /// Local mirror of `MPNowPlayingInfoCenter.default().nowPlayingInfo`, kept in
    /// lockstep with the center by routing every write through
    /// ``writeNowPlayingInfo(_:)`` / ``clearNowPlayingInfo()``. Its one reader is
    /// the throttled per-tick elapsed sync (``updateNowPlayingElapsed()``), which
    /// mutates this cache instead of reading the cross-process dict back — the
    /// `nowPlayingInfo` getter is a `mediaserverd` round-trip that copies the whole
    /// dict (artwork reference included), and it fired every ~5 media seconds
    /// (#412 heat trim). The infrequent artwork paths still read the center
    /// directly so they stay correct regardless of the cache's state.
    private var cachedNowPlayingInfo: [String: Any] = [:]

    /// Assigns `info` to the Now Playing center and updates the local mirror in
    /// one step. Every write to `nowPlayingInfo` must go through here (or
    /// ``clearNowPlayingInfo()``) so the cache never drifts from the center.
    private func writeNowPlayingInfo(_ info: [String: Any]) {
        cachedNowPlayingInfo = info
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Clears the Now Playing center and the local mirror together.
    private func clearNowPlayingInfo() {
        recordPlaybackDiagnostic("nowPlaying.clear")
        cachedNowPlayingInfo = [:]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func updateNowPlayingInfo() {
        guard !releaseInvalidCurrentEpisodeIfNeeded() else { return }
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = currentTitle ?? ""
        if let artist = currentArtist {
            info[MPMediaItemPropertyArtist] = artist
        }
        if durationSeconds > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = durationSeconds
        }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentPositionSeconds
        info[MPNowPlayingInfoPropertyPlaybackRate] = reportedNowPlayingRate
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = currentEffectiveRate
        // Preserve artwork that was already set by a prior fetch so it isn't
        // cleared by this synchronous update. The async artwork path will
        // overwrite it (or set it for the first time) when the image arrives.
        if let existing = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] {
            info[MPMediaItemPropertyArtwork] = existing
        }
        writeNowPlayingInfo(info)

        // This is a discontinuity write (play / pause / seek / resume): the elapsed
        recordPlaybackDiagnostic("nowPlaying.publish")
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

    /// Returns true after releasing a retained Episode whose row no longer
    /// exists. Resolve by stable identity in a fresh context; never touch a
    /// stored property on the retained instance to determine its validity.
    @discardableResult
    private func releaseInvalidCurrentEpisodeIfNeeded() -> Bool {
        guard !currentEpisodeIsTransient,
              let episode = currentEpisode,
              let context else { return false }
        let episodeID = episode.persistentModelID
        let resolver = ModelContext(context.container)
        var descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate { $0.persistentModelID == episodeID }
        )
        descriptor.fetchLimit = 1
        guard (try? resolver.fetchCount(descriptor)) == 0 else { return false }
        AppLog.player.error("Unloading a retained episode missing from the store")
        unloadWithoutPersisting()
        return true
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
            writeNowPlayingInfo(info)
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
        // MediaPlayer invokes this handler on its private access queue. The
        // image is immutable after decoding, so it is safe to return without
        // inheriting PlayerService's main-actor isolation.
        let artworkImage = image
        let artwork = MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in artworkImage }
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyArtwork] = artwork
        writeNowPlayingInfo(info)
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
            lastSyncedSecond: lastNowPlayingSyncSecond,
            interval: Int(ceil(PlaybackLogic.mediaSeconds(
                forWallClockSeconds: Double(PlaybackLogic.nowPlayingElapsedSyncInterval),
                playbackRate: timeObserverMediaInterval ?? currentEffectiveRate
            )))
        ) else { return }
        lastNowPlayingSyncSecond = currentSecond
        updateNowPlayingElapsed()
    }

    /// Writes just the moving fields (elapsed time, rate, duration) into
    /// `nowPlayingInfo` without disturbing the title/artist/artwork.
    private func updateNowPlayingElapsed() {
        // Start from the local mirror rather than reading the cross-process
        // dictionary back — this is the throttled per-tick path (#412 heat trim).
        var info = cachedNowPlayingInfo
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentPositionSeconds
        info[MPNowPlayingInfoPropertyPlaybackRate] = reportedNowPlayingRate
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = currentEffectiveRate
        if durationSeconds > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = durationSeconds
        }
        writeNowPlayingInfo(info)
    }

    // MARK: Private — remote commands

    enum RemotePlaybackCommand { case play, pause, toggle }

    /// Shared by real command handlers and regression tests. Configuration has
    /// already supplied the context before handlers are registered. Restore the
    /// one saved episode synchronously rather than waiting for maintenance.
    func handleRemotePlaybackCommand(_ command: RemotePlaybackCommand) -> MPRemoteCommandHandlerStatus {
        recordPlaybackDiagnostic("remote.\(command)")
        if currentEpisode == nil, command != .pause, let context {
            PlaybackStartup.restoreLastEpisode(into: self, context: context)
        }
        guard currentEpisode != nil else { return .noSuchContent }
        switch command {
        case .play: resume()
        case .pause: pause()
        case .toggle: togglePlayPause()
        }
        return .success
    }

    private func configureRemoteCommands() {
        guard !remoteCommandsConfigured else { return }
        remoteCommandsConfigured = true
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            return self.handleRemotePlaybackCommand(.play)
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            return self.handleRemotePlaybackCommand(.pause)
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            return self.handleRemotePlaybackCommand(.toggle)
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

    /// Diagnostic-only scalar snapshot. The local metadata dictionary is NOT
    /// evidence that iOS still selects Earshot as its global Now Playing app.
    /// No titles, episode IDs, URLs, audio, or other apps' content are recorded.
    private func recordPlaybackDiagnostic(_ event: String) {
#if EARSHOT_PLAYBACK_DIAGNOSTICS
        let session = AVAudioSession.sharedInstance()
        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
        let routes = session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")
        let line = "\(event) app=\(UIApplication.shared.applicationState.rawValue) episode=\(currentEpisode != nil) item=\(player.currentItem != nil) playing=\(isPlaying) intent=\(intendsToPlay) transport=\(player.timeControlStatus.rawValue) rate=\(player.rate) metadata=\(info != nil) metadataRate=\(String(describing: info?[MPNowPlayingInfoPropertyPlaybackRate])) otherAudio=\(session.isOtherAudioPlaying) route=\(routes)"
        PausedPlaybackDiagnosticLog.record(line)
#endif
    }
}

#if EARSHOT_PLAYBACK_DIAGNOSTICS
/// Compiled only into the explicitly requested local diagnostic build.
/// All filesystem operations run on this one serial queue, preserving enqueue
/// order without mutable state crossing isolation boundaries. No timers,
/// background assertions, audio activation, or debugger are used.
enum PausedPlaybackDiagnosticLog {
    private static let queue = DispatchQueue(label: "media.payown.earshot.playback-diagnostics", qos: .utility)
    private static let sessionID = UUID().uuidString

    static func record(_ event: String) {
        let timestamp = Date().timeIntervalSince1970
        let uptime = ProcessInfo.processInfo.systemUptime
        let line = "\(timestamp) uptime=\(uptime) session=\(sessionID) \(event)\n"
        queue.async {
            do {
                let manager = FileManager.default
                let directory = try manager.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                    .appendingPathComponent("PlaybackDiagnostics", isDirectory: true)
                try manager.createDirectory(at: directory, withIntermediateDirectories: true)
                let file = directory.appendingPathComponent("events.log")
                let previous = directory.appendingPathComponent("previous.log")
                let size = (try? manager.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
                if size >= 262_144 {
                    if manager.fileExists(atPath: previous.path) { try manager.removeItem(at: previous) }
                    try manager.moveItem(at: file, to: previous)
                }
                if !manager.fileExists(atPath: file.path) { manager.createFile(atPath: file.path, contents: nil) }
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
            } catch {
                AppLog.player.error("Playback diagnostic write failed")
            }
        }
    }
}
#endif

#if DEBUG
extension PlayerService {
    /// In-memory UI fixture only; never included in an installed Release build.
    func showLayoutTestFailure(folderID: PersistentIdentifier) {
        guard ScreenshotHarness.isSeeding else { return }
        playbackOrigin = .folder(folderID)
        playbackFailureMessage = "Layout test: audio unavailable. Try refreshing this episode."
    }
}
#endif
