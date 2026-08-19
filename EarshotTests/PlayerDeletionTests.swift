import XCTest
import SwiftData
@testable import Earshot

/// Tests for the #574 deleted-model crash fix.
///
/// Three layers are covered:
/// 1. The `.earshotWillDeleteEpisodes` pre-delete contract — both posters
///    (`SubscriptionRepository.unsubscribe`, `SettingsReset.deleteAllLocalData`)
///    must post it synchronously BEFORE anything is deleted, with the doomed
///    podcast's `PersistentIdentifier` (unsubscribe) or no userInfo (reset).
/// 2. `PlayerService`'s reaction: unloading when its episode is doomed,
///    leaving unrelated playback running, and `stopAndUnload()`'s teardown
///    (position persisted while valid, sleep timer cancelled, state cleared).
/// 3. The belt-and-braces `isDeleted` guards on the persistence sinks: if an
///    episode is deleted WITHOUT the notification, later pause/seek must never
///    write to the deleted instance (which traps or resurrects a zombie row).
///
/// Not coverable headless (documented, not faked): the gapless-preload-only
/// branch of the deletion handler (`preloadedEpisode` is private and only set
/// by the async queue-change observer) and the `handleTick` /
/// `markCurrentEpisodePlayed` guards (driven by the real AVPlayer time
/// observer). Those need the #388 audio test seam.
@MainActor
final class PlayerDeletionTests: XCTestCase {

    // MARK: Helpers

    @discardableResult
    private func makePodcastWithEpisode(
        _ ctx: ModelContext,
        feed: String = "https://x/feed",
        guid: String = "ep1"
    ) -> (podcast: Podcast, episode: Episode) {
        let podcast = Podcast(feedURL: feed, title: "Show \(guid)")
        ctx.insert(podcast)
        let episode = Episode(guid: guid, title: "Episode \(guid)", audioURL: "https://x/\(guid).mp3")
        episode.podcast = podcast
        ctx.insert(episode)
        try? ctx.save()
        return (podcast, episode)
    }

    private func makePlayer(_ ctx: ModelContext) -> PlayerService {
        let player = PlayerService()
        player.configure(context: ctx)
        return player
    }

    /// Captures what a `.earshotWillDeleteEpisodes` observer saw. The observer
    /// block is `@Sendable`, but with `queue: nil` it runs synchronously on the
    /// posting (main) thread, so plain vars are safe in practice.
    private final class PostRecorder: @unchecked Sendable {
        // The notification is posted synchronously on the main actor; the
        // callback immediately reasserts that isolation before using context.
        let context: ModelContext
        var postCount = 0
        var podcastIDInUserInfo: PersistentIdentifier?
        var podcastCountAtPost = -1
        var episodeCountAtPost = -1

        init(context: ModelContext) {
            self.context = context
        }
    }

    /// Observes the pre-delete notification and records store counts INSIDE the
    /// handler, proving the post happens while the doomed rows are still alive.
    private func recordNextPost(context ctx: ModelContext) -> (PostRecorder, NSObjectProtocol) {
        let recorder = PostRecorder(context: ctx)
        let token = NotificationCenter.default.addObserver(
            forName: .earshotWillDeleteEpisodes, object: nil, queue: nil
        ) { note in
            let podcastID =
                note.userInfo?[PlayerService.willDeletePodcastIDKey] as? PersistentIdentifier
            MainActor.assumeIsolated {
                recorder.postCount += 1
                recorder.podcastIDInUserInfo = podcastID
                recorder.podcastCountAtPost = (try? recorder.context.fetchCount(FetchDescriptor<Podcast>())) ?? -1
                recorder.episodeCountAtPost = (try? recorder.context.fetchCount(FetchDescriptor<Episode>())) ?? -1
            }
        }
        return (recorder, token)
    }

    // MARK: 1. Notification contract — the two posters

    /// Acceptance criterion (#574): unsubscribe must announce the deletion
    /// BEFORE it happens, carrying the doomed podcast's identifier, so the
    /// player can let go while the models are still valid.
    func test_unsubscribe_postsWillDeleteEpisodes_withPodcastID_beforeDeleting() throws {
        let ctx = TestStore.freshContext()
        let (podcast, _) = makePodcastWithEpisode(ctx)
        let expectedID = podcast.persistentModelID
        let repo = SubscriptionRepository(context: ctx)
        let (recorder, token) = recordNextPost(context: ctx)
        defer { NotificationCenter.default.removeObserver(token) }

        XCTAssertTrue(repo.unsubscribe(podcast))

        XCTAssertEqual(recorder.postCount, 1, "Exactly one pre-delete post per unsubscribe")
        XCTAssertEqual(
            recorder.podcastIDInUserInfo, expectedID,
            "userInfo must carry the doomed podcast's PersistentIdentifier"
        )
        XCTAssertEqual(
            recorder.podcastCountAtPost, 1,
            "Posted BEFORE the delete: the podcast is still fetchable inside the handler"
        )
        XCTAssertEqual(
            recorder.episodeCountAtPost, 1,
            "Posted BEFORE the cascade: the episode is still fetchable inside the handler"
        )
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<Podcast>()), 0, "…and gone afterward")
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<Episode>()), 0)
    }

    /// Acceptance criterion (#574): the factory reset posts the same hook with
    /// NO userInfo ("everything is going away"), before any delete runs.
    func test_deleteAllLocalData_postsWillDeleteEpisodes_withoutUserInfo_beforeDeleting() throws {
        let ctx = TestStore.freshContext()
        makePodcastWithEpisode(ctx)
        let (recorder, token) = recordNextPost(context: ctx)
        defer { NotificationCenter.default.removeObserver(token) }

        SettingsReset.deleteAllLocalData(context: ctx)

        XCTAssertEqual(recorder.postCount, 1, "Exactly one pre-delete post per reset")
        XCTAssertNil(
            recorder.podcastIDInUserInfo,
            "Factory reset means everything: no podcast ID in userInfo"
        )
        XCTAssertEqual(
            recorder.podcastCountAtPost, 1,
            "Posted BEFORE the wipe: the podcast is still fetchable inside the handler"
        )
        XCTAssertEqual(recorder.episodeCountAtPost, 1)
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<Podcast>()), 0, "…and gone afterward")
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<Episode>()), 0)
    }

    // MARK: 2. Player reaction to the pre-delete hook

    /// The #574 crash scenario: unfollowing the SHOW THAT IS PLAYING. The
    /// player must be fully unloaded by the time unsubscribe returns, and the
    /// durability anchors that used to trap (pause persist, seek persist,
    /// session flush) must be harmless no-ops afterward.
    func test_unsubscribe_whilePlayingThatPodcast_stopsAndUnloadsPlayer() throws {
        let ctx = TestStore.freshContext()
        let (podcast, episode) = makePodcastWithEpisode(ctx)
        let player = makePlayer(ctx)
        player.play(episode)
        XCTAssertNotNil(player.nowPlayingEpisode, "precondition: the doomed episode is loaded")
        XCTAssertTrue(player.isPlaying, "precondition: playback intent is on")

        XCTAssertTrue(SubscriptionRepository(context: ctx).unsubscribe(podcast))

        XCTAssertNil(player.nowPlayingEpisode, "The player let go before the delete")
        XCTAssertNil(player.currentTitle)
        XCTAssertNil(player.currentArtist)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.currentPositionSeconds, 0)
        XCTAssertEqual(player.durationSeconds, 0)

        // The old crash: a later persist wrote to the deleted instance. Now
        // nothing is loaded, so these must be safe and must not resurrect rows.
        player.pause()
        player.seek(to: 30)
        try ctx.save()
        XCTAssertEqual(
            try ctx.fetchCount(FetchDescriptor<Episode>()), 0,
            "No zombie episode row is resurrected by post-unsubscribe persists"
        )
        XCTAssertEqual(
            try ctx.fetchCount(FetchDescriptor<ListeningSession>()), 0,
            "No session referencing the deleted episode is inserted afterward"
        )
    }

    /// Item 2 / #574: the observed now-playing mirror must be cleared by the
    /// pre-delete release, so a list row never shows "Now Playing" for an episode
    /// that was just deleted out from under the player.
    func test_unsubscribe_whilePlayingThatPodcast_clearsNowPlayingEpisodeID() throws {
        let ctx = TestStore.freshContext()
        let (podcast, episode) = makePodcastWithEpisode(ctx)
        let player = makePlayer(ctx)
        player.play(episode)
        XCTAssertEqual(
            player.nowPlayingEpisodeID, episode.persistentModelID,
            "precondition: the mirror points at the loaded episode"
        )

        XCTAssertTrue(SubscriptionRepository(context: ctx).unsubscribe(podcast))

        XCTAssertNil(
            player.nowPlayingEpisodeID,
            "the pre-delete release clears the mirror so no row shows Now Playing for a deleted episode"
        )
    }

    /// Unfollowing a DIFFERENT show must leave playback completely untouched —
    /// the handler's podcast-ID guard keeps unrelated audio running.
    func test_unsubscribe_ofUnrelatedPodcast_leavesPlaybackRunning() throws {
        let ctx = TestStore.freshContext()
        let (_, playingEpisode) = makePodcastWithEpisode(ctx, feed: "https://a/feed", guid: "a1")
        let (doomed, _) = makePodcastWithEpisode(ctx, feed: "https://b/feed", guid: "b1")
        let player = makePlayer(ctx)
        player.play(playingEpisode)

        XCTAssertTrue(SubscriptionRepository(context: ctx).unsubscribe(doomed))

        XCTAssertNotNil(player.nowPlayingEpisode, "Unrelated playback survives the unfollow")
        XCTAssertEqual(player.currentTitle, "Episode a1")
        XCTAssertTrue(player.isPlaying, "Playback intent is untouched")
        XCTAssertEqual(
            try ctx.fetchCount(FetchDescriptor<Episode>()), 1,
            "Only the unfollowed show's episode is gone"
        )
    }

    /// Factory reset (no userInfo) unloads unconditionally when anything is
    /// loaded — the second #574 crash surface.
    func test_deleteAllLocalData_whileEpisodeLoaded_stopsAndUnloadsPlayer() throws {
        let ctx = TestStore.freshContext()
        let (_, episode) = makePodcastWithEpisode(ctx)
        let player = makePlayer(ctx)
        player.play(episode)
        XCTAssertNotNil(player.nowPlayingEpisode)

        SettingsReset.deleteAllLocalData(context: ctx)

        XCTAssertNil(player.nowPlayingEpisode, "Factory reset unloads the player")
        XCTAssertFalse(player.isPlaying)

        // Post-reset durability anchors never touch deleted instances.
        player.pause()
        player.seek(to: 10)
        try ctx.save()
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<Episode>()), 0, "No zombie rows")
    }

    // MARK: 3. stopAndUnload() teardown

    /// Position is persisted FIRST, while the episode instance is still valid —
    /// the same durability anchor pause() uses — and only then is all
    /// episode-derived state dropped.
    func test_stopAndUnload_persistsPositionWhileValid_thenClearsState() throws {
        let ctx = TestStore.freshContext()
        let (_, episode) = makePodcastWithEpisode(ctx)
        let player = makePlayer(ctx)
        player.load(episode)
        player.currentPositionSeconds = 42

        player.stopAndUnload()

        XCTAssertEqual(
            episode.positionSeconds, 42,
            "The last position is written while the instance is still valid"
        )
        XCTAssertNil(player.nowPlayingEpisode)
        XCTAssertNil(player.currentTitle)
        XCTAssertNil(player.currentArtist)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.currentPositionSeconds, 0)
        XCTAssertEqual(player.durationSeconds, 0)
        XCTAssertEqual(player.chapterCount, 0)
        XCTAssertNil(player.currentChapterTitle)
        XCTAssertNil(player.currentChapterIndex)
    }

    /// PRD 5.5: the sleep timer clears when playback of the timed episode ends —
    /// including this teardown path.
    func test_stopAndUnload_cancelsActiveSleepTimer() throws {
        let ctx = TestStore.freshContext()
        let (_, episode) = makePodcastWithEpisode(ctx)
        let player = makePlayer(ctx)
        player.load(episode)
        player.sleepTimer.set(.thirtyMinutes)
        XCTAssertTrue(player.sleepTimer.isActive, "precondition: timer armed")

        player.stopAndUnload()

        XCTAssertFalse(player.sleepTimer.isActive, "Teardown cancels the sleep timer")
    }

    /// Safe when nothing is loaded: every step no-ops on nil/idle state. This is
    /// the factory-reset-while-idle path.
    func test_stopAndUnload_nothingLoaded_isSafeNoOp() {
        let ctx = TestStore.freshContext()
        let player = makePlayer(ctx)

        player.stopAndUnload()

        XCTAssertNil(player.nowPlayingEpisode)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.currentPositionSeconds, 0)
    }

    // MARK: 4. Belt-and-braces isDeleted guards (deletion WITHOUT the hook)

    /// If some future code path deletes the loaded episode without posting the
    /// notification, the guards on the persistence sinks are the last line of
    /// defense: pause/seek must neither trap nor write to the deleted instance
    /// (a write would resurrect a zombie row on the next save).
    func test_persistGuards_episodeDeletedWithoutNotification_neverWriteOrResurrect() throws {
        let ctx = TestStore.freshContext()
        let (_, episode) = makePodcastWithEpisode(ctx)
        let player = makePlayer(ctx)
        player.load(episode)

        // Delete out from under the player, bypassing the pre-delete hook.
        ctx.delete(episode)
        XCTAssertTrue(episode.isDeleted, "precondition: the loaded instance is deleted")

        // seek → persistCurrentPosition; pause → persist + flushListeningSession.
        // Without the #574 guards these write positionSeconds / insert a session
        // on the deleted instance.
        player.seek(to: 10)
        player.pause()

        try ctx.save()
        XCTAssertEqual(
            try ctx.fetchCount(FetchDescriptor<Episode>()), 0,
            "The guards must not resurrect the deleted episode as a zombie row"
        )
        XCTAssertEqual(
            try ctx.fetchCount(FetchDescriptor<ListeningSession>()), 0,
            "No session referencing the deleted instance is inserted"
        )
    }

    /// Backgrounding is a lifecycle boundary, not merely another persistence
    /// sink. If reconciliation invalidated the retained model without the normal
    /// pre-delete hook, the player must release it before later interruption,
    /// lock-screen artwork, or end-of-item callbacks can fault stored properties.
    func test_persistForBackground_deletedEpisodeWithoutNotification_unloadsPlayer() throws {
        let ctx = TestStore.freshContext()
        let (_, episode) = makePodcastWithEpisode(ctx)
        let player = makePlayer(ctx)
        player.load(episode)

        ctx.delete(episode)
        try ctx.save()

        player.persistForBackground()

        XCTAssertNil(player.nowPlayingEpisode)
        XCTAssertNil(player.nowPlayingEpisodeID)
        XCTAssertNil(player.currentTitle)
        XCTAssertFalse(player.isPlaying)
    }

    /// An audio interruption or an app-resign-active callback can pause before
    /// the scene-background persistence anchor runs. A saved remote deletion
    /// must therefore be detected at pause itself, without consulting any
    /// property on the detached Episode.
    func test_pause_savedDeletedEpisodeWithoutNotification_unloadsPlayer() throws {
        let ctx = TestStore.freshContext()
        let (_, episode) = makePodcastWithEpisode(ctx)
        let player = makePlayer(ctx)
        player.load(episode)

        ctx.delete(episode)
        try ctx.save()

        player.pause()

        XCTAssertNil(player.nowPlayingEpisode)
        XCTAssertNil(player.nowPlayingEpisodeID)
        XCTAssertNil(player.currentTitle)
        XCTAssertFalse(player.isPlaying)
    }
}
