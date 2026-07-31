import XCTest
import AVFoundation
import SwiftData
@testable import Earshot

/// #374: a route change (headphones plugged in, a Bluetooth device connects,
/// AirPlay picked, etc.) can silently reset `AVAudioSession`'s preferred
/// output channel count and mode, which undoes the mono downmix from voice
/// enhance. `PlayerService` must reapply the current enhancement setting on
/// every route change, not just at episode-load time.
@MainActor
final class PlayerRouteChangeTests: XCTestCase {

    @discardableResult
    private func makePodcastWithEpisode(_ ctx: ModelContext) -> Episode {
        let podcast = Podcast(feedURL: "https://x/feed", title: "Show")
        ctx.insert(podcast)
        let episode = Episode(guid: "ep1", title: "Episode", audioURL: "https://x/ep1.mp3")
        episode.podcast = podcast
        ctx.insert(episode)
        try? ctx.save()
        return episode
    }

    func test_routeChange_reappliesCurrentVoiceEnhanceSetting() async throws {
        let ctx = TestStore.freshContext()
        let episode = makePodcastWithEpisode(ctx)
        let player = PlayerService()
        player.configure(context: ctx)
        player.load(episode)
        // `load()` never touches AVAudioSession (only `play()`/`resume()` do), so
        // asserting `.mode` right after `load()` would rest on whatever the
        // process's session happened to carry over from an earlier test — a real
        // flakiness bug. Explicitly apply the (currently disabled) setting so the
        // precondition is deterministic.
        player.applyAudioEnhancement()
        XCTAssertEqual(
            AVAudioSession.sharedInstance().mode, .default,
            "precondition: voice enhance is off"
        )

        AppSettingsStore(context: ctx).setBool(true, for: SettingsKey.voiceEnhanceEnabled)

        NotificationCenter.default.post(
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [
                AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue,
            ]
        )

        // handleRouteChange dispatches via `Task { @MainActor in ... }` off a
        // `queue: .main` notification observer, so there's no synchronous
        // guarantee it has run yet. Poll instead of guessing a fixed delay.
        try await pollUntil(timeout: 2) {
            AVAudioSession.sharedInstance().mode == .spokenAudio
        }

        XCTAssertEqual(
            AVAudioSession.sharedInstance().mode, .spokenAudio,
            "A route change must reapply the current voice-enhance setting, " +
            "not leave the session on whatever mode it had before the route changed"
        )
    }

    /// `.oldDeviceUnavailable` (headphones/Bluetooth unplugged) must both pause
    /// (so audio doesn't blast aloud on the speaker) AND still reapply the
    /// current voice-enhance setting — the pause must never be skipped just
    /// because enhancement reapplication also happens on this reason.
    func test_routeChange_oldDeviceUnavailable_pausesAndStillReappliesEnhancement() async throws {
        let ctx = TestStore.freshContext()
        let episode = makePodcastWithEpisode(ctx)
        let player = PlayerService()
        player.configure(context: ctx)
        AppSettingsStore(context: ctx).setBool(true, for: SettingsKey.voiceEnhanceEnabled)
        player.play(episode)
        XCTAssertTrue(player.isPlaying, "precondition: playing")

        NotificationCenter.default.post(
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [
                AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue,
            ]
        )

        try await pollUntil(timeout: 2) { !player.isPlaying }

        XCTAssertFalse(player.isPlaying, "Unplugging must still pause playback")
        XCTAssertEqual(
            AVAudioSession.sharedInstance().mode, .spokenAudio,
            "Unplugging must still reapply the current voice-enhance setting"
        )
    }

    /// Polls `condition` every 10ms until it's true or `timeout` seconds pass.
    /// Returns as soon as the condition is met instead of waiting a fixed delay.
    private func pollUntil(timeout: TimeInterval, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
