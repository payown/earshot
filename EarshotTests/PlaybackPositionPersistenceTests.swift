import XCTest
import SwiftData
@testable import Earshot

/// Durability tests for the #736 root fix: the ~5-second playback tick no longer
/// writes the position to SwiftData (that save invalidated every live `@Query`
/// and heated the phone on large libraries). Instead it records the position to
/// `UserDefaults`, and restore prefers that fresher value so a crash mid-playback
/// still resumes within ~5 seconds instead of at the last pause.
///
/// These guard the thing that must NOT regress: the user never loses their place.
@MainActor
final class PlaybackPositionPersistenceTests: XCTestCase {

    private func makeEpisode(_ ctx: ModelContext, guid: String = "ep1") -> Episode {
        let podcast = Podcast(feedURL: "https://x/feed", title: "Show")
        ctx.insert(podcast)
        let episode = Episode(guid: guid, title: "Episode", audioURL: "https://x/\(guid).mp3")
        episode.podcast = podcast
        ctx.insert(episode)
        try? ctx.save()
        return episode
    }

    private func setLive(_ episode: Episode, _ seconds: Int) {
        let key = DownloadTaskKey.key(feedURL: episode.podcast?.feedURL, guid: episode.guid)
        UserDefaults.standard.set(key, forKey: PlayerService.LivePositionKey.episode)
        UserDefaults.standard.set(seconds, forKey: PlayerService.LivePositionKey.seconds)
    }

    private nonisolated func clearLive() {
        UserDefaults.standard.removeObject(forKey: PlayerService.LivePositionKey.episode)
        UserDefaults.standard.removeObject(forKey: PlayerService.LivePositionKey.seconds)
    }

    override nonisolated func tearDown() {
        // Inline (don't call an instance method) so nothing sends `self` across
        // isolation from this nonisolated override.
        UserDefaults.standard.removeObject(forKey: PlayerService.LivePositionKey.episode)
        UserDefaults.standard.removeObject(forKey: PlayerService.LivePositionKey.seconds)
        super.tearDown()
    }

    /// Crash recovery: the durable SwiftData position is stale (last pause), but a
    /// fresher live position was recorded by the tick before the crash. Restore
    /// must resume at the live position, not the stale durable one.
    func test_restore_prefersFresherLivePosition() {
        let ctx = TestStore.freshContext()
        let player = PlayerService()
        player.configure(context: ctx)
        defer { player.stopAndUnload() }

        let episode = makeEpisode(ctx)
        episode.positionSeconds = 10 // durable value from the last anchor
        try? ctx.save()
        setLive(episode, 50)         // fresher tick value just before a "crash"

        player.load(episode)         // paused restore, as at launch

        XCTAssertEqual(Int(player.currentPositionSeconds), 50,
                       "restore must resume at the fresher live position, not the stale durable 10")
    }

    /// The live position is keyed to a specific episode, so it must NOT bleed into
    /// a different episode's resume.
    func test_restore_ignoresLivePositionForADifferentEpisode() {
        let ctx = TestStore.freshContext()
        let player = PlayerService()
        player.configure(context: ctx)
        defer { player.stopAndUnload() }

        let other = makeEpisode(ctx, guid: "other")
        setLive(other, 999)          // live position belongs to a different episode

        let episode = makeEpisode(ctx, guid: "target")
        episode.positionSeconds = 20
        try? ctx.save()

        player.load(episode)

        XCTAssertEqual(Int(player.currentPositionSeconds), 20,
                       "a live position for another episode must be ignored; use this episode's durable value")
    }

    /// When there's no live value (e.g. a clean prior stop), restore uses the
    /// durable SwiftData position.
    func test_restore_usesDurablePositionWhenNoLiveValue() {
        let ctx = TestStore.freshContext()
        let player = PlayerService()
        player.configure(context: ctx)
        defer { player.stopAndUnload() }
        clearLive()

        let episode = makeEpisode(ctx)
        episode.positionSeconds = 33
        try? ctx.save()

        player.load(episode)

        XCTAssertEqual(Int(player.currentPositionSeconds), 33,
                       "with no live value, resume at the durable position")
    }

    /// Regression: reaching 95% used to mark the episode played, zero its
    /// position, and make outro ads impossible to skip. Near-end progress must
    /// load unchanged and the transport must remain seekable until actual end.
    func test_nearEndPositionRemainsUnplayedAndSeekable() {
        let ctx = TestStore.freshContext()
        let player = PlayerService()
        player.configure(context: ctx)
        defer { player.stopAndUnload() }
        clearLive()

        let episode = makeEpisode(ctx)
        episode.durationSeconds = 100
        episode.positionSeconds = 96
        try? ctx.save()

        player.load(episode)

        XCTAssertEqual(Int(player.currentPositionSeconds), 96)
        XCTAssertFalse(episode.isPlayed)

        player.seek(to: 99)

        XCTAssertEqual(Int(player.currentPositionSeconds), 99)
        XCTAssertEqual(episode.positionSeconds, 99)
        XCTAssertFalse(episode.isPlayed, "Seeking near the end must not complete the episode")
    }

    /// A CloudKit reconcile occurs while the app remains open. The player owns a
    /// separate observable position cache, so its notification hook must update
    /// the visible scrubber/VoiceOver value without requiring relaunch.
    func test_cloudProjectionNotificationRefreshesLoadedPausedPosition() async {
        let ctx = TestStore.freshContext()
        let player = PlayerService()
        player.configure(context: ctx)
        defer { player.stopAndUnload() }
        clearLive()

        let episode = makeEpisode(ctx)
        episode.positionSeconds = 274
        try? ctx.save()
        player.load(episode)

        episode.positionSeconds = 379
        try? ctx.save()
        NotificationCenter.default.post(name: .earshotCloudProjectionDidApply, object: nil)
        await Task.yield()

        XCTAssertEqual(Int(player.currentPositionSeconds), 379)
    }

    /// A real CloudKit import can save through another context, leaving the
    /// player's retained Episode instance stale even though the store is current.
    /// The notification hook must resolve the durable row rather than trusting
    /// that retained object; the original same-instance test did not model this.
    func test_cloudProjectionNotificationRefreshesStaleLoadedEpisodeReference() async throws {
        let ctx = TestStore.freshContext()
        let player = PlayerService()
        player.configure(context: ctx)
        defer { player.stopAndUnload() }
        clearLive()

        let episode = makeEpisode(ctx)
        episode.positionSeconds = 274
        try ctx.save()
        player.load(episode)

        let writer = ModelContext(ctx.container)
        let imported = try XCTUnwrap(
            writer.model(for: episode.persistentModelID) as? Episode
        )
        imported.positionSeconds = 379
        try writer.save()
        XCTAssertEqual(episode.positionSeconds, 274,
                       "the loaded player reference should model the stale device instance")

        NotificationCenter.default.post(name: .earshotCloudProjectionDidApply, object: nil)
        await Task.yield()

        XCTAssertEqual(Int(player.currentPositionSeconds), 379)
    }

    /// The projection merge marks explicit rewinds by timestamp; once it has
    /// selected that value, the paused player must not let the larger crash-
    /// recovery cache hide it.
    func test_cloudProjectionRefreshHonorsExplicitRewindAndReplacesLiveCache() {
        let ctx = TestStore.freshContext()
        let player = PlayerService()
        player.configure(context: ctx)
        defer { player.stopAndUnload() }

        let episode = makeEpisode(ctx)
        episode.positionSeconds = 379
        try? ctx.save()
        setLive(episode, 379)
        player.load(episode)

        episode.positionSeconds = 80
        try? ctx.save()
        player.refreshProjectedPlaybackPosition()

        XCTAssertEqual(Int(player.currentPositionSeconds), 80)
        player.load(episode)
        XCTAssertEqual(Int(player.currentPositionSeconds), 80,
                       "the old larger live cache must not undo a projected rewind")
    }
}
