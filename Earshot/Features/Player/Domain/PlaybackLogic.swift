import Foundation
import SwiftData

/// The transient context that explains where the current playback run began.
///
/// Folder origin is deliberately identity-only and in memory. Now Playing
/// resolves the current folder path from SwiftData, so a rename is reflected
/// immediately and a deleted folder can never leave stale display text behind.
/// This value is never written to the episode, Queue, settings, or schema.
enum PlaybackOrigin: Equatable {
    case folder(PersistentIdentifier)

    var folderID: PersistentIdentifier {
        switch self {
        case let .folder(id): id
        }
    }
}

/// Spoken and visible copy for the one Now Playing origin control. Keeping this
/// pure makes the concise, non-duplicated label an accessibility regression test.
enum PlaybackOriginLabel {
    static func playingFrom(folderPath: String) -> String {
        "Playing from \(folderPath)"
    }
}

/// Events that can change a transient ``PlaybackOrigin``. Keeping the policy
/// pure prevents an internal auto-advance and a user-selected episode from
/// accidentally sharing different stale-context behavior.
enum PlaybackOriginEvent: Equatable {
    /// A deliberate episode start. `nil` means every non-folder source; a folder
    /// origin replaces any prior folder rather than being inherited.
    case started(PlaybackOrigin?)
    /// Queue advancement retains a folder origin only while the next episode's
    /// podcast still belongs to that folder's subtree.
    case advanced(nextEpisodeBelongsToOrigin: Bool)
    /// Pause, resume, seek, buffering, and route changes continue the same item.
    case continuedCurrentEpisode
    /// No episode remains loaded.
    case stopped
    /// Relaunch restores the last episode but not session-local source context.
    case restoredAfterRelaunch
    /// A repository deletion can remove one folder or an entire subtree.
    case foldersDeleted(Set<PersistentIdentifier>)
}

extension PlaybackLogic {
    /// Returns the folder origin after `event`, without reading player, queue, or
    /// model state. Callers resolve subtree membership before an advance and pass
    /// the boolean result in, keeping this transition exhaustive and unit-testable.
    static func playbackOrigin(
        after event: PlaybackOriginEvent,
        current: PlaybackOrigin?
    ) -> PlaybackOrigin? {
        switch event {
        case let .started(newOrigin):
            return newOrigin
        case let .advanced(nextEpisodeBelongsToOrigin):
            return nextEpisodeBelongsToOrigin ? current : nil
        case .continuedCurrentEpisode:
            return current
        case .stopped, .restoredAfterRelaunch:
            return nil
        case let .foldersDeleted(ids):
            guard let current, ids.contains(current.folderID) else { return current }
            return nil
        }
    }
}

/// Pure, view- and AVFoundation-free playback rules. These are factored out of
/// ``PlayerService`` so they can be unit-tested without starting real audio:
/// source resolution, speed resolution, and the completion / resume threshold.
enum PlaybackLogic {

    /// Resolves a CloudKit-projected position against the live transport.
    /// Paused playback follows the projection exactly, including an explicit
    /// rewind. While playback is active, the local clock is newer than its
    /// coarsely persisted row, so a lower projected value must not move it
    /// backward; genuinely newer remote progress may still advance it.
    static func projectedPlaybackPosition(
        current: Double,
        projected: Int,
        isActivelyPlaying: Bool
    ) -> Double {
        let projected = Double(max(0, projected))
        return isActivelyPlaying ? max(max(0, current), projected) : projected
    }

    /// Resolves which URL to hand to the player for an episode.
    ///
    /// Prefers a downloaded local file when `downloadPath` is set and the file
    /// exists on disk; otherwise streams `audioURL`. Returns `nil` when neither
    /// a usable file nor a valid stream URL is available, so callers can fail
    /// gracefully instead of crashing.
    ///
    /// - Parameters:
    ///   - downloadPath: The RESOLVED local file path, if the episode was
    ///     downloaded. Callers pass `episode.localAudioURL?.path` — never the
    ///     stored `Episode.downloadPath`, which is just a file name (and, on
    ///     legacy rows, a stale absolute path from a previous container, #575).
    ///   - audioURL: The remote stream URL string from the feed.
    ///   - fileExists: Injectable existence check (defaults to `FileManager`),
    ///     so tests don't need real files on disk.
    static func resolvePlaybackURL(
        downloadPath: String?,
        audioURL: String,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> URL? {
        if let path = downloadPath, !path.isEmpty, fileExists(path) {
            return URL(fileURLWithPath: path)
        }
        let trimmed = audioURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), url.scheme != nil else {
            return nil
        }
        return url
    }

    /// The effective playback rate for an episode: the podcast's per-show
    /// override wins, otherwise the global speed, otherwise 1.0. Non-positive or
    /// missing values fall through to the next source.
    static func effectivePlaybackRate(
        podcastSpeedOverride: Double?,
        globalSpeed: Double
    ) -> Double {
        if let override = podcastSpeedOverride, override > 0 {
            return override
        }
        if globalSpeed > 0 {
            return globalSpeed
        }
        return 1.0
    }

    // MARK: Speed range and helpers (PRD 5.5)

    /// The minimum allowed playback speed (PRD 5.5).
    static let minSpeed: Double = 0.5
    /// The maximum allowed playback speed (PRD 5.5).
    static let maxSpeed: Double = 5.0
    /// Step size for the full-range speed picker (0.1x increments, PRD 5.5).
    static let speedStep: Double = 0.1

    /// Clamps `speed` to the allowed [0.5, 5.0] range and rounds to the nearest
    /// 0.1 increment so floating-point arithmetic does not produce values like
    /// 1.1000000001.
    static func clampedSpeed(_ speed: Double) -> Double {
        let clamped = min(max(speed, minSpeed), maxSpeed)
        return (clamped * 10).rounded() / 10
    }

    /// The human-readable form of a speed value used in VoiceOver announcements.
    /// Whole-number speeds omit the decimal (e.g. 2.0 becomes "2 times"); others
    /// keep the significant digit (e.g. 1.5 becomes "1.5 times").
    static func spokenRate(_ speed: Double) -> String {
        let formatted = speed.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(speed))
            : String(format: "%g", speed)
        return "\(formatted) times"
    }

    /// Quick-tap speed shortcuts shown in the in-player speed picker. Covers
    /// the most common values without requiring the full stepper.
    static let speedShortcuts: [Double] = [0.8, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

    /// Curated, ascending speeds for the menu / VoiceOver-adjustable speed
    /// pickers (Settings + per-podcast). Short enough to flick through quickly;
    /// the in-player precise `Stepper` still covers the full
    /// ``minSpeed``…``maxSpeed`` range at ``speedStep`` for anyone who needs an
    /// exact or higher value. Matches the per-podcast override list.
    static let speedMenuValues: [Double] = [0.5, 0.6, 0.7, 0.8, 0.9, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

    /// The curated menu speed closest to `speed`, for displaying an off-grid
    /// stored value (e.g. one set via the precise in-player stepper) in a menu
    /// picker without silently rewriting it. Ties resolve to the lower value.
    static func nearestMenuSpeed(_ speed: Double) -> Double {
        speedMenuValues.min(by: { abs($0 - speed) < abs($1 - speed) }) ?? 1.0
    }

    /// The id of the episode to play next after `current` finishes: the queue
    /// entry positionally AFTER `current`'s own place in the queue (#627) --
    /// NOT simply the first entry that isn't `current`. Playing an episode that
    /// isn't at the head (leaving earlier, untouched items in place) must
    /// continue from where the listener actually was, not jump back to the
    /// queue's head. Falls back to the head when `current` has no position to
    /// reference (nil, or not found in the queue at all). `nil` when the queue
    /// is empty or `current` is the last item. Drives gapless advance.
    static func nextUpID<ID: Equatable>(queue: [ID], after current: ID?) -> ID? {
        guard let current, let idx = queue.firstIndex(of: current) else {
            return queue.first
        }
        let nextIndex = queue.index(after: idx)
        return nextIndex < queue.endIndex ? queue[nextIndex] : nil
    }

    /// The id of the episode to play next after `current` finishes, honoring the
    /// two auto-advance boundary settings (#446). A `nil` result means STOP --
    /// callers clear now-playing / skip preload exactly as they do when the queue
    /// has no next item.
    ///
    /// Precedence, tightest boundary first:
    /// 1. `continueAfterEpisode` off -> always stop after every episode (makes the
    ///    group setting moot while off).
    /// 2. else `continueAfterGroupEnds` off and the next queue item is a different
    ///    group (podcast) than `currentGroupKey` -> stop at the group boundary.
    /// 3. else advance to the queue entry positionally after `current` (#627;
    ///    both-on is the default), or `nil` if no such item exists.
    ///
    /// This is intentionally independent of the runtime `stopAfterCurrentEpisode`
    /// one-off action: it neither takes nor consults that flag.
    ///
    /// - Parameters:
    ///   - queue: The ordered queue as `(id, groupKey)` pairs. `groupKey` is the
    ///     item's podcast identity.
    ///   - current: The id of the episode that just finished, if any.
    ///   - currentGroupKey: The group (podcast) key of the finished episode.
    ///   - continueAfterEpisode: When false, stop at every episode boundary.
    ///   - continueAfterGroupEnds: When false, stop when the next item is a
    ///     different group than the current one.
    ///
    /// "Next" is resolved the same way as ``nextUpID(queue:after:)`` (#627): the
    /// entry positionally AFTER `current`'s own place in the queue, not simply
    /// the first entry that isn't `current`.
    /// The effective "continue after group ends" flag for one advance. An
    /// episode the user explicitly chose to "Play next" outranks the passive
    /// "stop after group ends" preference: when that episode is the immediate
    /// next item, its group boundary is ignored so it actually plays next (#487).
    /// When the setting is already on, or the next item wasn't Play-next-ed, the
    /// setting passes through unchanged.
    static func continueAfterGroupEnds<ID: Hashable>(
        setting: Bool,
        nextCandidate: ID?,
        playNextOverrides: Set<ID>
    ) -> Bool {
        if setting { return true }
        guard let nextCandidate else { return false }
        return playNextOverrides.contains(nextCandidate)
    }

    static func nextUpHonoringBoundaries<ID: Equatable, Key: Equatable>(
        queue: [(id: ID, groupKey: Key)],
        after current: ID?,
        currentGroupKey: Key?,
        continueAfterEpisode: Bool,
        continueAfterGroupEnds: Bool,
        wrapToRemaining: Bool = false
    ) -> ID? {
        guard continueAfterEpisode else { return nil }
        let next: (id: ID, groupKey: Key)?
        if let current, let idx = queue.firstIndex(where: { $0.id == current }) {
            let nextIndex = queue.index(after: idx)
            next = nextIndex < queue.endIndex ? queue[nextIndex]
                : (wrapToRemaining ? queue.first(where: { $0.id != current }) : nil)
        } else {
            next = queue.first
        }
        guard let next else { return nil }
        if !continueAfterGroupEnds, let cur = currentGroupKey, next.groupKey != cur {
            return nil
        }
        return next.id
    }

    /// How often the per-tick playback position is flushed to SwiftData while
    /// audio plays. The periodic time observer fires every second, but a
    /// synchronous main-actor `context.save()` every second starves the main
    /// run loop (TabView selection/hit-testing stalls -- issue #362). Position is
    /// also persisted on pause, seek, episode switch, and listening-session
    /// flush, so a coarser tick cadence loses at most this many seconds of
    /// progress on an abrupt kill, while keeping the run loop responsive.
    static let positionPersistInterval = 5

    /// How often uninterrupted playback publishes its current position to the
    /// compact CloudKit projection. This never saves the application store, so
    /// it cannot invalidate the large-library `@Query` graph that caused #736.
    /// Pause, seek, episode switch, and background remain immediate anchors.
    static let positionProjectionInterval = 60

    /// Whether uninterrupted playback has advanced far enough to publish one
    /// compact position projection. The media-time threshold is scaled from a
    /// wall-clock cadence so 2x playback does not double CloudKit write traffic.
    static func shouldProjectPlaybackPosition(
        currentSecond: Int,
        lastProjectedSecond: Int,
        playbackRate: Double,
        wallClockInterval: Int = positionProjectionInterval
    ) -> Bool {
        let mediaInterval = Int(ceil(mediaSeconds(
            forWallClockSeconds: Double(wallClockInterval),
            playbackRate: playbackRate
        )))
        if currentSecond < lastProjectedSecond { return true }
        return currentSecond - lastProjectedSecond >= mediaInterval
    }

    /// Converts a wall-clock cadence into media seconds. AVPlayer's periodic
    /// observer interval is measured in item time, so an unscaled one-second
    /// interval fires twice per real second at 2x playback.
    static func mediaSeconds(
        forWallClockSeconds wallClockSeconds: Double,
        playbackRate: Double
    ) -> Double {
        let safeWallClockSeconds = max(wallClockSeconds, 1)
        let safeRate = playbackRate.isFinite ? max(playbackRate, 1) : 1
        return safeWallClockSeconds * safeRate
    }

    /// Whether this tick should write the playback position to disk.
    ///
    /// True on the first tracked tick (`lastPersistedSecond == nil`), whenever at
    /// least ``positionPersistInterval`` seconds have elapsed since the last
    /// write, or whenever the position jumped backwards (a seek/skip-back --
    /// want that reflected promptly). Pure so the cadence is unit-testable.
    ///
    /// Always false once `isPlayed` is true (issue #653). Explicitly marking an
    /// episode played can zero its durable position while a stale player tick is
    /// still in flight. Once an episode is played, no throttled tick has anything
    /// useful left to persist for it.
    ///
    /// - Parameters:
    ///   - currentSecond: The integer playback second for this tick.
    ///   - lastPersistedSecond: The second at which we last wrote, or `nil` if we
    ///     have not written for the current episode yet.
    ///   - interval: The minimum gap between writes (defaults to
    ///     ``positionPersistInterval``).
    ///   - isPlayed: Whether the episode this tick belongs to is already marked
    ///     played. Defaults to `false` so existing call sites are unaffected.
    static func shouldPersistTick(
        currentSecond: Int,
        lastPersistedSecond: Int?,
        interval: Int = positionPersistInterval,
        isPlayed: Bool = false
    ) -> Bool {
        guard !isPlayed else { return false }
        guard let last = lastPersistedSecond else { return true }
        if currentSecond < last { return true }
        return currentSecond - last >= interval
    }

    /// How often, in seconds, the lock-screen / Control Center "elapsed time" is
    /// re-synced to `MPNowPlayingInfoCenter` during steady playback.
    ///
    /// `nowPlayingInfo` is a cross-process dictionary handed to `mediaserverd`;
    /// reading and rewriting the whole thing every second is a real, sustained
    /// energy cost (issue #412). It is also unnecessary: once `elapsedPlaybackTime`,
    /// `playbackRate`, and `playbackDuration` are set, the system extrapolates the
    /// running elapsed time itself from the rate. A periodic re-sync only corrects
    /// the small drift between our clock and the system's; every few seconds is
    /// imperceptible on the lock screen while cutting the IPC rate by this factor.
    /// Discontinuities (play, pause, seek, rate change) still update eagerly and
    /// exactly via ``PlayerService`` so the lock screen never shows a stale jump.
    static let nowPlayingElapsedSyncInterval = 15

    /// Whether this tick should re-sync the lock-screen elapsed time.
    ///
    /// True on the first tick after a discontinuity (`lastSyncedSecond == nil`),
    /// whenever at least ``nowPlayingElapsedSyncInterval`` seconds have elapsed
    /// since the last sync, or whenever the position jumped backwards (a
    /// seek/skip-back the system's extrapolation can't have predicted). Pure so
    /// the cadence is unit-testable.
    ///
    /// - Parameters:
    ///   - currentSecond: The integer playback second for this tick.
    ///   - lastSyncedSecond: The second at which we last wrote now-playing, or
    ///     `nil` to force a sync (set after every discontinuity).
    ///   - interval: The minimum gap between syncs (defaults to
    ///     ``nowPlayingElapsedSyncInterval``).
    static func shouldSyncNowPlayingElapsed(
        currentSecond: Int,
        lastSyncedSecond: Int?,
        interval: Int = nowPlayingElapsedSyncInterval
    ) -> Bool {
        guard let last = lastSyncedSecond else { return true }
        if currentSecond < last { return true }
        return currentSecond - last >= interval
    }

    /// Resolves where playback should begin. Saved progress is always honored,
    /// including positions in the final five percent: only AVPlayer's actual-end
    /// notification or an explicit user action marks an episode played.
    ///
    /// `introSkipSeconds` (#456) applies only on a genuinely fresh start. For a
    /// known duration, leave two seconds of playable audio so an oversized intro
    /// skip cannot jump directly beyond a short episode's end.
    static func playbackStartPosition(
        position: Int,
        duration: Int?,
        introSkipSeconds: Int? = nil
    ) -> Int {
        let safePosition = max(0, position)
        var startPosition = safePosition
        if safePosition == 0, let skip = introSkipSeconds, skip > 0 {
            if let duration, duration > 0 {
                let maxStart = max(0, duration - 2)
                startPosition = min(skip, maxStart)
            } else {
                startPosition = skip
            }
        }
        return startPosition
    }

    // MARK: Scrubber VoiceOver step (#610)

    /// The scrubber's minimum VoiceOver flick step. Also the flat step used for
    /// any episode at or under 30 minutes, matching the original Flutter scrubber.
    static let minScrubberStepSeconds: Double = 30
    /// The scrubber's maximum VoiceOver flick step, so even very long episodes
    /// still land within a bounded jump per flick.
    static let maxScrubberStepSeconds: Double = 300
    /// Roughly how many flicks should be needed to cross an episode start-to-end.
    private static let targetScrubberFlicks: Double = 60

    /// The VoiceOver flick step for the episode progress scrubber, scaled to
    /// `duration` so long episodes don't require 100+ flicks to traverse (#610).
    /// Aims for about ``targetScrubberFlicks`` flicks end-to-end, clamped to
    /// [``minScrubberStepSeconds``, ``maxScrubberStepSeconds``]. Episodes at or
    /// under 30 minutes keep the original flat 30s step; longer episodes scale up
    /// proportionally. Past the 5-hour breakeven point
    /// (``maxScrubberStepSeconds`` × ``targetScrubberFlicks``) the step clamp wins
    /// over the flick-count target: flicks needed can exceed ~60 for such rare,
    /// very long content, but no single flick ever jumps more than 5 minutes --
    /// an unbounded per-flick jump would be a worse regression than a few extra
    /// flicks. Unknown/non-positive duration falls back to the flat step.
    static func scrubberStepSeconds(duration: Double) -> Double {
        guard duration > 0 else { return minScrubberStepSeconds }
        let target = duration / targetScrubberFlicks
        return min(max(target, minScrubberStepSeconds), maxScrubberStepSeconds)
    }

    // MARK: Remote command / lock-screen state (Bluetooth pause fix)

    /// The action a single play/pause toggle should take.
    enum RemoteToggleAction: Equatable {
        case pause
        case resume
    }

    /// Decides whether a `togglePlayPauseCommand` (the command single-button
    /// Bluetooth earbuds send — Bose Ultra Open, Shokz OpenFit) should pause or
    /// resume.
    ///
    /// The decision is made from the user's PLAYBACK INTENT and the player's real
    /// transport state, never from ``PlayerService``'s `isPlaying` display flag
    /// alone. That flag has many mutation sites and nothing syncs it from the
    /// live player, so it can read stale-`false` while audio is actually
    /// rendering. When a toggle handler trusted that stale flag it resumed
    /// (a no-op — already playing) instead of pausing, so the first earbud press
    /// did nothing and only a second press paused (the Shokz two-press symptom).
    ///
    /// Pause whenever the user intends playback OR the player is actively playing;
    /// resume only when we are genuinely stopped. `intendsToPlay` deliberately
    /// dominates so that a press mid-buffer (`.waitingToPlayAtSpecifiedRate`,
    /// where `playerIsPlaying` is still false) still pauses rather than issuing a
    /// redundant resume.
    ///
    /// - Parameters:
    ///   - intendsToPlay: The user's standing intent to play — set on play/resume,
    ///     cleared on pause/stop/finish. Survives buffering and stalls.
    ///   - playerIsPlaying: `true` when `AVPlayer.timeControlStatus == .playing`.
    static func remoteToggleAction(
        intendsToPlay: Bool,
        playerIsPlaying: Bool
    ) -> RemoteToggleAction {
        (intendsToPlay || playerIsPlaying) ? .pause : .resume
    }

    /// The playback rate to publish to `MPNowPlayingInfoPropertyPlaybackRate`.
    ///
    /// Derived from the user's intent and the INTENDED effective rate, not the
    /// live `AVPlayer.rate`. With `automaticallyWaitsToMinimizeStalling` on,
    /// `resume()` reports now-playing while the player is still in
    /// `.waitingToPlayAtSpecifiedRate`, where `AVPlayer.rate` can read 0 — which
    /// would advertise "paused" to the system while audio is starting. Bluetooth/
    /// AVRCP accessories that mirror the system's play state (Bose Ultra Open)
    /// then believe playback is paused and send PLAY on a button press, so the
    /// press never pauses. Reporting the intended rate keeps that accessory-side
    /// state model correct.
    ///
    /// Returns 0 exactly when the user is not intending playback (paused/stopped),
    /// the fast-forward scan rate while a hold-to-scan is active, otherwise the
    /// effective (per-podcast or global) rate.
    ///
    /// - Parameters:
    ///   - intendsToPlay: The user's standing intent to play.
    ///   - effectiveRate: The per-podcast-or-global speed for the current episode.
    ///   - isFastForwarding: Whether a hold-to-fast-forward scan is active.
    ///   - fastForwardRate: The scan rate to report while fast-forwarding.
    static func nowPlayingRate(
        intendsToPlay: Bool,
        effectiveRate: Double,
        isFastForwarding: Bool,
        fastForwardRate: Double
    ) -> Double {
        guard intendsToPlay else { return 0 }
        return isFastForwarding ? fastForwardRate : effectiveRate
    }

    /// Whether `PlayerService` should flip its `isPlaying` display flag to `true`
    /// in response to a `timeControlStatus` change.
    ///
    /// Closes the drift where the player reaches `.playing` without an explicit
    /// resume having set the flag — most notably automatic stall recovery, which
    /// re-issues `player.play()` but never touches `isPlaying`. Only flips when
    /// the player is actually playing AND the user still intends playback (so a
    /// brief post-pause `.playing` blip can't revive a paused UI), and only when
    /// the flag is currently `false` (so callers can skip a redundant now-playing
    /// rewrite).
    ///
    /// - Parameters:
    ///   - playerIsPlaying: `true` when `AVPlayer.timeControlStatus == .playing`.
    ///   - intendsToPlay: The user's standing intent to play.
    ///   - currentlyMarkedPlaying: The present value of `isPlaying`.
    static func shouldMarkPlayingOnTransition(
        playerIsPlaying: Bool,
        intendsToPlay: Bool,
        currentlyMarkedPlaying: Bool
    ) -> Bool {
        playerIsPlaying && intendsToPlay && !currentlyMarkedPlaying
    }
}
