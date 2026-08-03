import XCTest
import SwiftData
import AVFoundation
@testable import Earshot

/// Tests for the #373 advanced-playback engine state on ``PlayerService``:
/// hold-to-fast-forward rate swap and chapter auto-skip toggling / guarding.
///
/// These exercise the observable engine state and the in-memory skipped-chapter
/// map directly. The actual AVPlayer seek/rate side effects need a device, so the
/// pure decision math is covered separately in ``ChapterSkipLogicTests``.
@MainActor
final class AdvancedPlaybackTests: XCTestCase {

    private func makeContext() -> ModelContext {
        TestStore.freshContext()
    }

    private func makePlayer() -> PlayerService {
        let player = PlayerService()
        player.configure(context: makeContext())
        return player
    }

    private func makeEpisode(_ ctx: ModelContext, guid: String = "ep1") -> Episode {
        let podcast = Podcast(feedURL: "https://x/feed", title: "Show")
        ctx.insert(podcast)
        let episode = Episode(guid: guid, title: "Episode", audioURL: "https://x/\(guid).mp3")
        episode.podcast = podcast
        ctx.insert(episode)
        try? ctx.save()
        return episode
    }

    // MARK: Fast-forward

    func test_beginFastForward_noEpisode_isNoOp() {
        let player = makePlayer()
        player.beginFastForward()
        XCTAssertFalse(player.isFastForwarding, "Without a loaded episode, fast-forward must not engage")
    }

    func test_beginAndEndFastForward_togglesState() {
        let ctx = TestStore.freshContext()
        let player = PlayerService()
        player.configure(context: ctx)
        let episode = makeEpisode(ctx)
        player.load(episode)

        player.beginFastForward()
        XCTAssertTrue(player.isFastForwarding)

        player.endFastForward()
        XCTAssertFalse(player.isFastForwarding)
    }

    func test_beginFastForward_whenAlreadyScanning_isNoOp() {
        let ctx = TestStore.freshContext()
        let player = PlayerService()
        player.configure(context: ctx)
        player.load(makeEpisode(ctx))

        player.beginFastForward()
        player.beginFastForward() // second call must not crash or double-engage
        XCTAssertTrue(player.isFastForwarding)
        player.endFastForward()
        XCTAssertFalse(player.isFastForwarding)
    }

    func test_endFastForward_whenNotScanning_isNoOp() {
        let player = makePlayer()
        player.endFastForward()
        XCTAssertFalse(player.isFastForwarding)
    }

    /// #610: the fast-forward rotor action is no longer gated behind any setting
    /// -- it must always be available so VoiceOver users can reach the 4x scan
    /// without first finding and enabling an unrelated toggle.
    func test_fastForwardRotorAvailable_isAlwaysTrue() {
        XCTAssertTrue(makePlayer().fastForwardRotorAvailable)
    }

    func test_switchingEpisode_clearsActiveFastForward() {
        let ctx = TestStore.freshContext()
        let player = PlayerService()
        player.configure(context: ctx)
        player.load(makeEpisode(ctx, guid: "a"))
        player.beginFastForward()
        XCTAssertTrue(player.isFastForwarding)

        // Loading a different episode must drop the scan.
        player.load(makeEpisode(ctx, guid: "b"))
        XCTAssertFalse(player.isFastForwarding)
    }

    // MARK: Chapter skip toggle

    func test_toggleChapterSkipped_flipsState() {
        let ctx = TestStore.freshContext()
        let player = PlayerService()
        player.configure(context: ctx)
        player.load(makeEpisode(ctx))
        let chapter = Chapter(index: 1, startTime: 60, title: "Ads")

        XCTAssertFalse(player.isChapterSkipped(chapter))

        let nowSkipped = player.toggleChapterSkipped(chapter)
        XCTAssertTrue(nowSkipped)
        XCTAssertTrue(player.isChapterSkipped(chapter))

        let nowUnskipped = player.toggleChapterSkipped(chapter)
        XCTAssertFalse(nowUnskipped)
        XCTAssertFalse(player.isChapterSkipped(chapter))
    }

    func test_toggleChapterSkipped_noEpisode_isNoOp() {
        let player = makePlayer()
        let chapter = Chapter(index: 0, startTime: 0, title: "Intro")
        XCTAssertFalse(player.toggleChapterSkipped(chapter))
        XCTAssertFalse(player.isChapterSkipped(chapter))
    }

    func test_skippedState_isPerEpisode() {
        let ctx = TestStore.freshContext()
        let player = PlayerService()
        player.configure(context: ctx)
        let chapter = Chapter(index: 2, startTime: 120, title: "Sponsor")

        let epA = makeEpisode(ctx, guid: "a")
        player.load(epA)
        player.toggleChapterSkipped(chapter)
        XCTAssertTrue(player.isChapterSkipped(chapter))

        // A different episode does not inherit episode A's skipped set.
        let epB = makeEpisode(ctx, guid: "b")
        player.load(epB)
        XCTAssertFalse(player.isChapterSkipped(chapter))

        // Returning to episode A restores its in-memory skipped set.
        player.load(epA)
        XCTAssertTrue(player.isChapterSkipped(chapter))
    }

    func test_setChapters_doesNotCrashWithEmptyList() {
        let ctx = TestStore.freshContext()
        let player = PlayerService()
        player.configure(context: ctx)
        player.load(makeEpisode(ctx))
        player.setChapters([])
        // No assertion beyond "did not crash"; auto-skip is a no-op with no list.
        XCTAssertNotNil(player.nowPlayingEpisode)
    }

    // MARK: Chapter nav as VoiceOver transport actions (#560)

    /// Acceptance criterion: activating the rotor action on an episode with no
    /// chapters must NOT seek — it announces instead of silently no-oping. Here
    /// we assert the "no seek" half (Announcer is a no-op with VoiceOver off).
    func test_nextChapterOrAnnounce_noChapters_doesNotChangePosition() {
        let ctx = TestStore.freshContext()
        let player = PlayerService()
        player.configure(context: ctx)
        player.load(makeEpisode(ctx))
        player.setChapters([])
        player.currentPositionSeconds = 42

        player.nextChapterOrAnnounceNoChapters()

        XCTAssertEqual(player.chapterCount, 0)
        XCTAssertEqual(player.currentPositionSeconds, 42, "no-chapters next must not seek")
    }

    /// Acceptance criterion: previous-chapter rotor action with no chapters must
    /// not seek either.
    func test_previousChapterOrAnnounce_noChapters_doesNotChangePosition() {
        let ctx = TestStore.freshContext()
        let player = PlayerService()
        player.configure(context: ctx)
        player.load(makeEpisode(ctx))
        player.setChapters([])
        player.currentPositionSeconds = 42

        player.previousChapterOrAnnounceNoChapters()

        XCTAssertEqual(player.chapterCount, 0)
        XCTAssertEqual(player.currentPositionSeconds, 42, "no-chapters previous must not seek")
    }

    /// Acceptance criterion: with chapters present, the wrapper defers to the
    /// existing next-chapter navigation and seeks to the following chapter start.
    func test_nextChapterOrAnnounce_withChapters_defersToNextChapter() {
        let ctx = TestStore.freshContext()
        let player = PlayerService()
        player.configure(context: ctx)
        player.load(makeEpisode(ctx))
        player.setChapters([
            Chapter(index: 0, startTime: 0, title: "Intro"),
            Chapter(index: 1, startTime: 60, title: "Main"),
            Chapter(index: 2, startTime: 120, title: "Outro"),
        ])
        player.currentPositionSeconds = 10 // active chapter 0

        player.nextChapterOrAnnounceNoChapters()

        XCTAssertEqual(player.currentPositionSeconds, 60, "should seek to chapter 1 start")
    }

    /// Acceptance criterion: with chapters present, previous-chapter wrapper
    /// defers to the existing previous-chapter navigation and seeks backward.
    func test_previousChapterOrAnnounce_withChapters_defersToPreviousChapter() {
        let ctx = TestStore.freshContext()
        let player = PlayerService()
        player.configure(context: ctx)
        player.load(makeEpisode(ctx))
        player.setChapters([
            Chapter(index: 0, startTime: 0, title: "Intro"),
            Chapter(index: 1, startTime: 60, title: "Main"),
            Chapter(index: 2, startTime: 120, title: "Outro"),
        ])
        // 1s into chapter 1 (below the restart threshold) steps back to chapter 0.
        player.currentPositionSeconds = 61

        player.previousChapterOrAnnounceNoChapters()

        XCTAssertEqual(player.currentPositionSeconds, 0, "should seek back to chapter 0 start")
    }

    // MARK: Stream-only Search preview (#517)

    private func storeCounts(_ ctx: ModelContext) -> (episodes: Int, sessions: Int, queue: Int) {
        let episodes = (try? ctx.fetch(FetchDescriptor<Episode>()))?.count ?? -1
        let sessions = (try? ctx.fetch(FetchDescriptor<ListeningSession>()))?.count ?? -1
        let queue = (try? ctx.fetch(FetchDescriptor<QueueItem>()))?.count ?? -1
        return (episodes, sessions, queue)
    }

    func test_playPreview_setsNowPlayingAndInsertsNothing() {
        let ctx = TestStore.freshContext()
        let player = PlayerService()
        player.configure(context: ctx)

        let before = storeCounts(ctx)

        player.playPreview(
            guid: "preview-guid",
            title: "Preview Episode",
            audioURL: "https://example.com/audio.mp3",
            showTitle: "Some Show",
            episodeDescription: "Notes",
            artworkURL: "https://example.com/art.jpg",
            chapterURL: nil,
            durationSeconds: 1800
        )

        // Now-playing surfaces reflect the streamed episode and the show name.
        XCTAssertEqual(player.currentTitle, "Preview Episode")
        XCTAssertEqual(player.currentArtist, "Some Show")
        XCTAssertNotNil(player.nowPlayingEpisode)

        // No store rows were created by the preview stream.
        let after = storeCounts(ctx)
        XCTAssertEqual(after.episodes, before.episodes, "Preview must not insert an Episode")
        XCTAssertEqual(after.sessions, before.sessions, "Preview must not insert a ListeningSession")
        XCTAssertEqual(after.queue, before.queue, "Preview must not insert a QueueItem")
    }

    func test_playPreview_emptyAudioURL_isNoOp() {
        let ctx = TestStore.freshContext()
        let player = PlayerService()
        player.configure(context: ctx)

        player.playPreview(
            guid: "g", title: "T", audioURL: "", showTitle: "Show"
        )
        XCTAssertNil(player.nowPlayingEpisode, "An empty audio URL must not load anything")
    }

    func test_playPreview_playbackEnds_stopsCleanlyWithoutInserting() async {
        let ctx = TestStore.freshContext()
        let player = PlayerService()
        player.configure(context: ctx)

        player.playPreview(
            guid: "preview", title: "Preview", audioURL: "https://x/p.mp3", showTitle: "Show"
        )
        XCTAssertNotNil(player.nowPlayingEpisode)
        let before = storeCounts(ctx)

        // Drive natural end-of-track. The observer registered in configure()
        // listens for this notification (object: nil) and routes to the private
        // completion handler on the main actor.
        NotificationCenter.default.post(
            name: AVPlayerItem.didPlayToEndTimeNotification, object: nil
        )

        // The handler runs in a hopped main-actor Task; poll until it clears the
        // transient episode (network is irrelevant — completion is synchronous).
        var cleared = false
        for _ in 0..<200 {
            if player.nowPlayingEpisode == nil { cleared = true; break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertTrue(cleared, "Preview completion must stop cleanly (currentEpisode == nil)")
        XCTAssertFalse(player.isPlaying)

        // The empty queue has no next item, so a finished preview must leave the
        // store exactly as it was — no Episode, ListeningSession, or QueueItem.
        let after = storeCounts(ctx)
        XCTAssertEqual(after.episodes, before.episodes, "Completion must not insert an Episode")
        XCTAssertEqual(after.sessions, before.sessions, "Completion must not insert a ListeningSession")
        XCTAssertEqual(after.queue, before.queue, "Completion must not insert a QueueItem")
    }

    // MARK: Now-playing identity mirror (Item 2)

    func test_play_setsNowPlayingEpisodeID() {
        let ctx = TestStore.freshContext()
        let player = PlayerService()
        player.configure(context: ctx)
        XCTAssertNil(player.nowPlayingEpisodeID, "precondition: nothing loaded")

        let episode = makeEpisode(ctx)
        player.play(episode)

        XCTAssertEqual(player.nowPlayingEpisodeID, episode.persistentModelID,
                       "play mirrors the loaded episode's identity")
    }

    func test_load_setsNowPlayingEpisodeID() {
        let ctx = TestStore.freshContext()
        let player = PlayerService()
        player.configure(context: ctx)

        let episode = makeEpisode(ctx)
        player.load(episode)

        XCTAssertEqual(player.nowPlayingEpisodeID, episode.persistentModelID,
                       "load (paused restore) mirrors the loaded episode's identity")
    }

    func test_switchingEpisodes_updatesNowPlayingEpisodeID() {
        let ctx = TestStore.freshContext()
        let player = PlayerService()
        player.configure(context: ctx)
        let first = makeEpisode(ctx, guid: "e1")
        let second = makeEpisode(ctx, guid: "e2")

        player.play(first)
        XCTAssertEqual(player.nowPlayingEpisodeID, first.persistentModelID)

        player.play(second)
        XCTAssertEqual(player.nowPlayingEpisodeID, second.persistentModelID,
                       "the mirror follows the newly loaded episode")
    }

    func test_stopAndUnload_clearsNowPlayingEpisodeID() {
        // stopAndUnload backs the #574 pre-delete release path; clearing the
        // mirror here means no row shows "Now Playing" for a released episode.
        let ctx = TestStore.freshContext()
        let player = PlayerService()
        player.configure(context: ctx)
        player.play(makeEpisode(ctx))

        player.stopAndUnload()

        XCTAssertNil(player.nowPlayingEpisodeID, "stopAndUnload clears the now-playing mirror")
    }

    func test_markCurrentPlayedAndAdvance_nothingQueued_clearsNowPlayingEpisodeID() {
        // The "advance with nothing queued" clear path (PlayerService line ~852)
        // routes through setCurrentEpisode(nil), so the mirror clears too.
        let ctx = TestStore.freshContext()
        let player = PlayerService()
        player.configure(context: ctx)
        let episode = makeEpisode(ctx)
        player.play(episode)
        XCTAssertEqual(player.nowPlayingEpisodeID, episode.persistentModelID)

        player.markCurrentPlayedAndAdvance()

        XCTAssertNil(player.nowPlayingEpisodeID,
                     "advancing with an empty queue clears the now-playing mirror")
    }

    // MARK: Open full player on play (#562)

    /// Acceptance criterion: with the openPlayerOnPlay setting ON (the default),
    /// the deliberate "Play now" row path raises the full player by setting
    /// pendingFullPlayerPresentation.
    func test_playFromEpisodeList_settingOn_setsPendingFullPlayerPresentation() {
        let ctx = TestStore.freshContext()
        // Default is ON; set it explicitly so the test states its precondition.
        let store = AppSettingsStore(context: ctx)
        store.setBool(true, for: SettingsKey.openPlayerOnPlay)
        let player = PlayerService()
        player.configure(context: ctx)
        XCTAssertFalse(player.pendingFullPlayerPresentation, "precondition: flag starts clear")

        player.playFromEpisodeList(makeEpisode(ctx))

        XCTAssertTrue(player.pendingFullPlayerPresentation,
                      "Play now with setting ON must raise the full player")
    }

    /// Acceptance criterion: with openPlayerOnPlay OFF, the same row path plays in
    /// the background and never raises the full player.
    func test_playFromEpisodeList_settingOff_doesNotSetPendingFullPlayerPresentation() {
        let ctx = TestStore.freshContext()
        let store = AppSettingsStore(context: ctx)
        store.setBool(false, for: SettingsKey.openPlayerOnPlay)
        let player = PlayerService()
        player.configure(context: ctx)

        player.playFromEpisodeList(makeEpisode(ctx))

        XCTAssertFalse(player.pendingFullPlayerPresentation,
                       "Play now with setting OFF must not raise the full player")
    }

    /// Acceptance criterion: the plain play(_:) path — used by queue auto-advance,
    /// resume, and jump-to-bookmark — must never raise the full player, even when
    /// the setting is ON.
    func test_play_settingOn_neverSetsPendingFullPlayerPresentation() {
        let ctx = TestStore.freshContext()
        let store = AppSettingsStore(context: ctx)
        store.setBool(true, for: SettingsKey.openPlayerOnPlay)
        let player = PlayerService()
        player.configure(context: ctx)

        player.play(makeEpisode(ctx))

        XCTAssertFalse(player.pendingFullPlayerPresentation,
                       "Non-deliberate play(_:) must never raise the full player")
    }

    /// The default (no explicit write to the setting) is ON, so a fresh store's
    /// Play now still raises the player — guards the SettingsDefault fallback.
    func test_playFromEpisodeList_defaultSetting_setsPendingFullPlayerPresentation() {
        let ctx = TestStore.freshContext()
        let player = PlayerService()
        player.configure(context: ctx)

        player.playFromEpisodeList(makeEpisode(ctx))

        XCTAssertTrue(player.pendingFullPlayerPresentation,
                      "Default (unset) openPlayerOnPlay is true, so Play now raises the player")
    }

    func test_playPreview_realPlayAfterPreview_restoresPersistence() {
        let ctx = TestStore.freshContext()
        let player = PlayerService()
        player.configure(context: ctx)

        player.playPreview(
            guid: "preview", title: "Preview", audioURL: "https://x/p.mp3", showTitle: "Show"
        )
        // A real episode played after a preview must persist again: its position
        // writes prove the transient flag was cleared by the normal play path.
        let real = makeEpisode(ctx, guid: "real")
        player.play(real)
        player.seek(to: 42)

        XCTAssertEqual(real.positionSeconds, 42, "Real play after preview must persist position")
    }

    // MARK: playFromEpisodeList queues the episode (#612)

    func test_playFromEpisodeList_notAlreadyQueued_addsToQueue() {
        let ctx = TestStore.freshContext()
        let player = PlayerService()
        player.configure(context: ctx)
        let episode = makeEpisode(ctx)
        XCTAssertNil(episode.queueItem, "Precondition: episode starts un-queued")

        player.playFromEpisodeList(episode)

        XCTAssertNotNil(episode.queueItem, "Play now from a list must queue the episode")
        XCTAssertEqual(episode.status, .inQueue)
    }

    func test_playFromEpisodeList_alreadyQueued_isNoOp() {
        let ctx = TestStore.freshContext()
        let player = PlayerService()
        player.configure(context: ctx)
        let episode = makeEpisode(ctx)
        let repo = QueueRepository(context: ctx)
        repo.add(episode)
        let originalItem = episode.queueItem

        player.playFromEpisodeList(episode)

        XCTAssertEqual(episode.queueItem?.persistentModelID, originalItem?.persistentModelID,
                       "Playing an already-queued episode must not create a duplicate QueueItem")
        XCTAssertEqual(repo.queue().count, 1)
    }

    // MARK: canOverridePerPodcast (#606)

    func test_canOverridePerPodcast_noEpisodeLoaded_isFalse() {
        let player = makePlayer()
        XCTAssertFalse(player.canOverridePerPodcast)
    }

    func test_canOverridePerPodcast_episodeWithPodcast_isTrue() {
        let ctx = TestStore.freshContext()
        let player = PlayerService()
        player.configure(context: ctx)
        player.load(makeEpisode(ctx))

        XCTAssertTrue(player.canOverridePerPodcast,
                      "A normally-loaded episode always has a podcast, so scope can default to per-show")
    }

    func test_canOverridePerPodcast_streamPreview_isFalse() {
        let ctx = TestStore.freshContext()
        let player = PlayerService()
        player.configure(context: ctx)

        player.playPreview(
            guid: "preview", title: "Preview", audioURL: "https://x/p.mp3", showTitle: "Show"
        )

        XCTAssertFalse(player.canOverridePerPodcast,
                       "A detached stream preview has no podcast, so it must fall back to global speed")
    }

    // MARK: defaultRate stays in sync across auto-advance (#609)

    func test_applyRate_defaultRateNeverStaleAcrossConsecutivePlays() {
        let ctx = TestStore.freshContext()
        let settings = AppSettingsStore(context: ctx)
        settings.setDouble(1.5, for: SettingsKey.globalSpeed)
        let player = PlayerService()
        player.configure(context: ctx)

        let podcastA = Podcast(feedURL: "https://x/a", title: "Show A")
        podcastA.speedOverride = 1.0
        ctx.insert(podcastA)
        let episodeA = Episode(guid: "a1", title: "A1", audioURL: "https://x/a1.mp3")
        episodeA.podcast = podcastA
        ctx.insert(episodeA)

        let podcastB = Podcast(feedURL: "https://x/b", title: "Show B")
        // No override -- falls back to the 1.5x global default.
        ctx.insert(podcastB)
        let episodeB = Episode(guid: "b1", title: "B1", audioURL: "https://x/b1.mp3")
        episodeB.podcast = podcastB
        ctx.insert(episodeB)
        try? ctx.save()

        // Play A: effective rate 1.0, defaultRate must match immediately.
        player.play(episodeA)
        XCTAssertEqual(player.effectiveRate, 1.0)
        XCTAssertEqual(player.debugDefaultRate, 1.0, accuracy: 0.001,
                       "defaultRate must match the effective rate right after play()")

        // Simulate auto-advance to B exactly as handlePlaybackEnded() does: play()
        // is called directly with no intervening pause, so isPlaying stays true the
        // whole time. Before the #609 fix, applyRate() never touched defaultRate in
        // that branch, so it stayed stuck at A's 1.0 here.
        player.play(episodeB)
        XCTAssertEqual(player.effectiveRate, 1.5)
        XCTAssertEqual(player.debugDefaultRate, 1.5, accuracy: 0.001,
                       "defaultRate must track B's global rate, not stay stuck at A's override")

        // And back to A again -- defaultRate must not remain stuck at B's rate.
        player.play(episodeA)
        XCTAssertEqual(player.effectiveRate, 1.0)
        XCTAssertEqual(player.debugDefaultRate, 1.0, accuracy: 0.001,
                       "defaultRate must track A's override again, not stay stuck at B's global rate")
    }

    // MARK: removeFromQueue stops/advances the current episode (#619)

    func test_removeFromQueue_currentEpisodeWithNextQueued_stopsAndAdvances() {
        let ctx = TestStore.freshContext()
        let player = PlayerService()
        player.configure(context: ctx)

        let podcast = Podcast(feedURL: "https://x/feed", title: "Show")
        ctx.insert(podcast)
        let current = Episode(guid: "current", title: "Current", audioURL: "https://x/current.mp3")
        current.podcast = podcast
        ctx.insert(current)
        let next = Episode(guid: "next", title: "Next", audioURL: "https://x/next.mp3")
        next.podcast = podcast
        ctx.insert(next)
        try? ctx.save()

        let repo = QueueRepository(context: ctx)
        repo.add(current)
        repo.add(next)
        player.play(current)
        XCTAssertEqual(player.nowPlayingEpisodeID, current.persistentModelID, "Precondition: current is playing")

        player.removeFromQueue(current, context: ctx)

        XCTAssertNil(current.queueItem, "Removed episode must leave the queue")
        XCTAssertEqual(player.nowPlayingEpisodeID, next.persistentModelID,
                       "Removing the currently playing episode must advance to the next queued episode")
    }

    func test_removeFromQueue_currentEpisodeWithNothingNext_stopsCleanly() {
        let ctx = TestStore.freshContext()
        let player = PlayerService()
        player.configure(context: ctx)

        let podcast = Podcast(feedURL: "https://x/feed", title: "Show")
        ctx.insert(podcast)
        let current = Episode(guid: "current", title: "Current", audioURL: "https://x/current.mp3")
        current.podcast = podcast
        ctx.insert(current)
        try? ctx.save()

        let repo = QueueRepository(context: ctx)
        repo.add(current)
        player.play(current)

        player.removeFromQueue(current, context: ctx)

        XCTAssertNil(current.queueItem, "Removed episode must leave the queue")
        XCTAssertNil(player.nowPlayingEpisodeID, "Nothing queued after it: the player must clear cleanly")
        XCTAssertFalse(player.isPlaying, "Playback must stop when nothing is next")
    }

    func test_removeFromQueue_currentEpisode_doesNotMarkPlayed() {
        // #619 must follow #614's rule: a removal is not a completion, so it must
        // never inflate the "Episodes completed" listening stat.
        let ctx = TestStore.freshContext()
        let player = PlayerService()
        player.configure(context: ctx)

        let podcast = Podcast(feedURL: "https://x/feed", title: "Show")
        ctx.insert(podcast)
        let current = Episode(guid: "current", title: "Current", audioURL: "https://x/current.mp3")
        current.podcast = podcast
        ctx.insert(current)
        try? ctx.save()

        let repo = QueueRepository(context: ctx)
        repo.add(current)
        player.play(current)

        player.removeFromQueue(current, context: ctx)

        XCTAssertFalse(current.isPlayed, "Removing must not be recorded as a completed listen")
        XCTAssertNil(current.playedAt, "Episodes-completed stat must not count this episode")
        XCTAssertTrue(current.inboxDismissed, "Must still dismiss from the inbox, matching #614's cancelFromQueue behavior")
    }

    func test_removeFromQueue_notCurrentEpisode_doesNotAffectPlayback() {
        let ctx = TestStore.freshContext()
        let player = PlayerService()
        player.configure(context: ctx)

        let podcast = Podcast(feedURL: "https://x/feed", title: "Show")
        ctx.insert(podcast)
        let current = Episode(guid: "current", title: "Current", audioURL: "https://x/current.mp3")
        current.podcast = podcast
        ctx.insert(current)
        let other = Episode(guid: "other", title: "Other", audioURL: "https://x/other.mp3")
        other.podcast = podcast
        ctx.insert(other)
        try? ctx.save()

        let repo = QueueRepository(context: ctx)
        repo.add(current)
        repo.add(other)
        player.play(current)

        player.removeFromQueue(other, context: ctx)

        XCTAssertNil(other.queueItem, "The removed (non-current) episode must still leave the queue")
        XCTAssertEqual(player.nowPlayingEpisodeID, current.persistentModelID,
                       "Removing a DIFFERENT episode must not touch what's currently playing")
        XCTAssertTrue(player.isPlaying, "Playback must be undisturbed")
    }

    // MARK: Advance respects the grouped-display order (#627 follow-up)

    /// Two shows interleaved in the REAL queue order -- exactly what "Group by
    /// podcast" hides on screen by visually clustering same-show episodes
    /// together without touching the underlying order (`QueueLogic.group`'s own
    /// doc comment: "even when the flat queue interleaves keys"). Playing X2
    /// (not X1) and turning grouping on, then finishing X2, must advance to X3
    /// -- the next episode in the GROUPED order actually shown on screen -- not
    /// Y2, which is what the raw interleaved order would give.
    private func makeInterleavedShowsQueue(_ ctx: ModelContext) -> (x1: Episode, x2: Episode, x3: Episode, y1: Episode, y2: Episode) {
        let showX = Podcast(feedURL: "https://x/feed", title: "Show X")
        ctx.insert(showX)
        let showY = Podcast(feedURL: "https://y/feed", title: "Show Y")
        ctx.insert(showY)

        let x1 = Episode(guid: "x1", title: "X1", audioURL: "https://x/1.mp3")
        x1.podcast = showX
        ctx.insert(x1)
        let y1 = Episode(guid: "y1", title: "Y1", audioURL: "https://y/1.mp3")
        y1.podcast = showY
        ctx.insert(y1)
        let x2 = Episode(guid: "x2", title: "X2", audioURL: "https://x/2.mp3")
        x2.podcast = showX
        ctx.insert(x2)
        let y2 = Episode(guid: "y2", title: "Y2", audioURL: "https://y/2.mp3")
        y2.podcast = showY
        ctx.insert(y2)
        let x3 = Episode(guid: "x3", title: "X3", audioURL: "https://x/3.mp3")
        x3.podcast = showX
        ctx.insert(x3)
        try? ctx.save()

        let repo = QueueRepository(context: ctx)
        // Real (flat) order: X1, Y1, X2, Y2, X3 -- interleaved.
        repo.add(x1)
        repo.add(y1)
        repo.add(x2)
        repo.add(y2)
        repo.add(x3)

        return (x1, x2, x3, y1, y2)
    }

    func test_markCurrentPlayedAndAdvance_groupedDisplayOn_followsGroupedOrderNotRawInterleavedOrder() {
        let ctx = TestStore.freshContext()
        let player = PlayerService()
        player.configure(context: ctx)
        let episodes = makeInterleavedShowsQueue(ctx)
        AppSettingsStore(context: ctx).setQueueGrouping(.podcast)

        player.play(episodes.x2)
        player.markCurrentPlayedAndAdvance()

        XCTAssertEqual(
            player.nowPlayingEpisodeID, episodes.x3.persistentModelID,
            "With grouped display on, advance must follow the grouped (same-show) order shown on "
                + "screen, not the raw interleaved queue order"
        )
    }

    func test_markCurrentPlayedAndAdvance_groupedDisplayOff_followsRawInterleavedOrder() {
        // Control: grouping off (the default) must preserve #627's original fix
        // -- the true flat queue order, unaffected by which show anything belongs to.
        let ctx = TestStore.freshContext()
        let player = PlayerService()
        player.configure(context: ctx)
        let episodes = makeInterleavedShowsQueue(ctx)

        player.play(episodes.x2)
        player.markCurrentPlayedAndAdvance()

        XCTAssertEqual(
            player.nowPlayingEpisodeID, episodes.y2.persistentModelID,
            "With grouped display off, advance must follow the true flat queue order (#627)"
        )
    }

    func test_markCurrentPlayedAndAdvance_folderGroupedDisplay_followsFolderOrder() {
        let ctx = TestStore.freshContext()
        let player = PlayerService()
        player.configure(context: ctx)
        let episodes = makeInterleavedShowsQueue(ctx)

        let showZ = Podcast(feedURL: "https://z/feed", title: "Show Z")
        ctx.insert(showZ)
        let z1 = Episode(guid: "z1", title: "Z1", audioURL: "https://z/1.mp3")
        z1.podcast = showZ
        ctx.insert(z1)
        QueueRepository(context: ctx).add(z1)

        let folders = FolderRepository(context: ctx)
        let shared = folders.createFolder(name: "Shared")
        let other = folders.createFolder(name: "Other")
        folders.add(episodes.x1.podcast!, to: shared)
        folders.add(showZ, to: shared)
        folders.add(episodes.y1.podcast!, to: other)
        AppSettingsStore(context: ctx).setQueueGrouping(.folder)

        // Raw order after X3 is Z1, so finish X2 instead: raw next is Y2, while
        // folder display clusters Shared as X1, X2, X3, Z1 and advances to X3.
        player.play(episodes.x2)
        player.markCurrentPlayedAndAdvance()

        XCTAssertEqual(
            player.nowPlayingEpisodeID, episodes.x3.persistentModelID,
            "Folder grouping must advance through the same top-level folder section shown in Queue"
        )
    }

    /// Caught in security review of the grouped-display fix above: "Play Next"
    /// (#487) guarantees an episode plays immediately after `current` by
    /// inserting it right after `current` in the RAW queue. With grouping on,
    /// naively reordering by group before resolving "next" can cluster that
    /// freshly play-next-ed episode behind the REST of the current group,
    /// silently breaking the Play Next promise across podcasts. The override
    /// must win regardless of the grouped-display setting.
    func test_markCurrentPlayedAndAdvance_groupedDisplayOn_playNextOverrideStillWinsAcrossGroups() {
        let ctx = TestStore.freshContext()
        let player = PlayerService()
        player.configure(context: ctx)
        let episodes = makeInterleavedShowsQueue(ctx)
        AppSettingsStore(context: ctx).setQueueGrouping(.podcast)

        // Play-Next a brand new Show Y episode right after X2 -- raw queue
        // becomes X1, Y1, X2, Y3(new), X3, Y2. Grouped order would otherwise
        // cluster X2's remaining show (X3) ahead of Y3.
        let showY = episodes.y1.podcast!
        let y3 = Episode(guid: "y3", title: "Y3", audioURL: "https://y/3.mp3")
        y3.podcast = showY
        ctx.insert(y3)
        try? ctx.save()

        let repo = QueueRepository(context: ctx)
        player.play(episodes.x2)
        repo.playNext(y3, after: episodes.x2)
        player.registerPlayNext(y3)

        player.markCurrentPlayedAndAdvance()

        XCTAssertEqual(
            player.nowPlayingEpisodeID, y3.persistentModelID,
            "Play Next must still play immediately after the current episode, even when grouped "
                + "display would otherwise advance within the current show's group first"
        )
    }

    // MARK: persistCurrentPosition never clobbers an already-played episode (#653)

    /// Mirrors the ``PlaybackLogicTests`` coverage of `shouldPersistTick`'s
    /// `isPlayed` guard, but against the eager anchor `pause()` uses
    /// (`persistCurrentPosition()`). If the episode was marked played (position
    /// zeroed) while a stale `currentPositionSeconds` was still in flight —
    /// exactly the window between the 95%-played tick and the item actually
    /// finishing — a later `pause()` must not overwrite the zeroed position.
    func test_pause_afterEpisodeMarkedPlayed_doesNotOverwriteZeroedPosition() {
        let ctx = TestStore.freshContext()
        let player = PlayerService()
        player.configure(context: ctx)
        let episode = makeEpisode(ctx)

        player.load(episode)
        player.currentPositionSeconds = 597 // stale in-flight position near the end
        episode.isPlayed = true
        episode.positionSeconds = 0 // simulates markCurrentEpisodePlayed() having already run

        player.pause()

        XCTAssertEqual(
            episode.positionSeconds, 0,
            "pause()'s eager persist must not resurrect a stale position on an already-played episode"
        )
    }

    /// Sanity check for the guard above: an episode that is NOT played still
    /// gets its position persisted normally on pause.
    func test_pause_beforeEpisodeMarkedPlayed_stillPersistsPosition() {
        let ctx = TestStore.freshContext()
        let player = PlayerService()
        player.configure(context: ctx)
        let episode = makeEpisode(ctx)

        player.load(episode)
        player.currentPositionSeconds = 123

        player.pause()

        XCTAssertEqual(episode.positionSeconds, 123, "Normal pause persistence is unaffected by the guard")
    }
}
