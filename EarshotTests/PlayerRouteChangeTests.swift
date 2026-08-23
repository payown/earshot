import XCTest
import AVFoundation
import SwiftData
@testable import Earshot

/// Route changes must preserve transport safety without reconfiguring the live
/// audio session mid-render (#695).
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

    /// `.oldDeviceUnavailable` (headphones/Bluetooth unplugged) must pause so
    /// audio cannot unexpectedly continue through the device speaker.
    func test_routeChange_oldDeviceUnavailable_pauses() async throws {
        let ctx = TestStore.freshContext()
        let episode = makePodcastWithEpisode(ctx)
        let player = PlayerService()
        player.configure(context: ctx)
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
