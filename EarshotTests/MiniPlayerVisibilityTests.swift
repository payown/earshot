import XCTest
import SwiftData
import AVFoundation
@testable import Earshot

/// Tests for #730: the mini player (`NowPlayingBar`) must HIDE once playback
/// stops with nothing to advance to, instead of lingering on a finished
/// episode. The bar renders only `if let title = player.currentTitle`, so
/// "hidden" is asserted as `currentTitle == nil`. Each stop-with-nothing-next
/// path must also drop the persisted last-playing episode so a relaunch doesn't
/// restore a finished episode back into the bar.
///
/// The complementary invariant — a mid-episode PAUSE must ALWAYS keep the bar —
/// is asserted too, since the whole point of #730 is to hide on natural end
/// WITHOUT hiding on pause.
@MainActor
final class MiniPlayerVisibilityTests: XCTestCase {

    private func makeEpisode(_ ctx: ModelContext, guid: String = "ep1") -> Episode {
        let podcast = Podcast(feedURL: "https://x/feed", title: "Show")
        ctx.insert(podcast)
        let episode = Episode(guid: guid, title: "Episode \(guid)", audioURL: "https://x/\(guid).mp3")
        episode.podcast = podcast
        ctx.insert(episode)
        try? ctx.save()
        return episode
    }

    /// The persisted last-playing episode key, read back raw. Empty (or nil)
    /// means launch restore has nothing to repopulate the bar with.
    private func storedLastPlaying(_ ctx: ModelContext) -> String {
        AppSettingsStore(context: ctx).rawValue(SettingsKey.lastPlayingEpisodeID) ?? ""
    }

    // MARK: Mark-played with nothing queued hides the bar

    func test_markCurrentPlayedAndAdvance_nothingQueued_hidesBarAndClearsRestore() {
        let ctx = TestStore.freshContext()
        let player = PlayerService()
        player.configure(context: ctx)

        player.play(makeEpisode(ctx))
        XCTAssertNotNil(player.currentTitle, "precondition: bar visible while playing")
        XCTAssertFalse(storedLastPlaying(ctx).isEmpty, "precondition: last-playing episode persisted")

        player.markCurrentPlayedAndAdvance()

        XCTAssertNil(player.currentTitle, "mark-played with empty queue hides the mini player")
        XCTAssertNil(player.currentArtist)
        XCTAssertNil(player.nowPlayingEpisodeID)
        XCTAssertTrue(storedLastPlaying(ctx).isEmpty,
                      "restore key cleared so launch doesn't repopulate the bar")
    }

    // MARK: Remove-current-from-queue with nothing next hides the bar

    func test_removeFromQueue_currentWithNothingNext_hidesBar() {
        let ctx = TestStore.freshContext()
        let player = PlayerService()
        player.configure(context: ctx)

        let episode = makeEpisode(ctx)
        QueueRepository(context: ctx).add(episode)
        player.play(episode)
        XCTAssertNotNil(player.currentTitle, "precondition: bar visible while playing")

        player.removeFromQueue(episode, context: ctx)

        XCTAssertNil(player.currentTitle,
                     "removing the playing episode with nothing next hides the mini player")
        XCTAssertNil(player.nowPlayingEpisodeID)
        XCTAssertTrue(storedLastPlaying(ctx).isEmpty)
    }

    // MARK: Natural end-of-track with empty queue hides the bar

    func test_naturalCompletion_emptyQueue_hidesBarAndClearsRestore() async {
        let ctx = TestStore.freshContext()
        let player = PlayerService()
        player.configure(context: ctx)

        player.play(makeEpisode(ctx))
        XCTAssertNotNil(player.currentTitle, "precondition: bar visible while playing")

        // Drive natural end-of-track; the completion handler hops onto the main
        // actor via a Task, so poll until it clears the bar.
        NotificationCenter.default.post(
            name: AVPlayerItem.didPlayToEndTimeNotification, object: nil
        )
        var hidden = false
        for _ in 0..<200 {
            if player.currentTitle == nil { hidden = true; break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertTrue(hidden, "natural completion with an empty queue hides the mini player")
        XCTAssertNil(player.nowPlayingEpisodeID)
        XCTAssertTrue(storedLastPlaying(ctx).isEmpty,
                      "restore key cleared so launch doesn't repopulate the bar")
    }

    // MARK: Invariant — pause must NEVER hide the bar

    func test_pause_keepsBarVisible() {
        let ctx = TestStore.freshContext()
        let player = PlayerService()
        player.configure(context: ctx)

        let episode = makeEpisode(ctx)
        player.play(episode)
        XCTAssertNotNil(player.currentTitle, "precondition: bar visible while playing")

        player.pause()

        XCTAssertNotNil(player.currentTitle, "a mid-episode pause must keep the mini player")
        XCTAssertEqual(player.nowPlayingEpisodeID, episode.persistentModelID,
                       "pause keeps the episode loaded")
        XCTAssertFalse(storedLastPlaying(ctx).isEmpty,
                       "pause must NOT clear the restore key")
    }

    // MARK: Auto-advance keeps the bar (only end-with-nothing-next hides)

    func test_completion_withNextQueued_keepsBarOnNextEpisode() async {
        let ctx = TestStore.freshContext()
        let player = PlayerService()
        player.configure(context: ctx)

        let first = makeEpisode(ctx, guid: "e1")
        let second = makeEpisode(ctx, guid: "e2")
        let repo = QueueRepository(context: ctx)
        repo.add(first)
        repo.add(second)
        player.play(first)

        NotificationCenter.default.post(
            name: AVPlayerItem.didPlayToEndTimeNotification, object: nil
        )
        var advanced = false
        for _ in 0..<200 {
            if player.nowPlayingEpisodeID == second.persistentModelID { advanced = true; break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertTrue(advanced, "completion with a next queued episode auto-advances")
        XCTAssertNotNil(player.currentTitle, "the bar stays — it now shows the next episode")
    }
}
