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

    private func makeContext(directTouch: Bool = false) -> ModelContext {
        let ctx = TestStore.freshContext()
        let store = AppSettingsStore(context: ctx)
        store.setBool(directTouch, for: SettingsKey.directTouchEnabled)
        return ctx
    }

    private func makePlayer(directTouch: Bool = false) -> PlayerService {
        let player = PlayerService()
        player.configure(context: makeContext(directTouch: directTouch))
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
        let store = AppSettingsStore(context: ctx)
        store.setBool(false, for: SettingsKey.directTouchEnabled)
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

    func test_fastForwardRotorAvailable_followsDirectTouchSetting() {
        let off = makePlayer(directTouch: false)
        XCTAssertFalse(off.fastForwardRotorAvailable)

        let on = makePlayer(directTouch: true)
        XCTAssertTrue(on.fastForwardRotorAvailable)
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
}
