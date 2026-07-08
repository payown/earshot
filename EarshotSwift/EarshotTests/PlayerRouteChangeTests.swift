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
        XCTAssertEqual(
            AVAudioSession.sharedInstance().mode, .default,
            "precondition: voice enhance is off at load time"
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

    /// Polls `condition` every 10ms until it's true or `timeout` seconds pass.
    /// Returns as soon as the condition is met instead of waiting a fixed delay.
    private func pollUntil(timeout: TimeInterval, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
