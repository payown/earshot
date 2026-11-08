import XCTest
@testable import Earshot

@MainActor
final class PhonePlaybackAcknowledgementTests: XCTestCase {
    func testAcknowledgementRequiresActualPlaybackAndMatchingEpisode() {
        let podcast = Podcast(feedURL: "https://example.com/feed", title: "Show")
        let episode = Episode(guid: "one", title: "One", audioURL: "https://example.com/one.mp3")
        episode.podcast = podcast

        XCTAssertFalse(PhonePlaybackAckPolicy.confirmed(episode, feedURL: podcast.feedURL,
                                                        guid: episode.guid, actuallyPlaying: false))
        XCTAssertFalse(PhonePlaybackAckPolicy.confirmed(episode, feedURL: podcast.feedURL,
                                                        guid: "another", actuallyPlaying: true))
        XCTAssertTrue(PhonePlaybackAckPolicy.confirmed(episode, feedURL: podcast.feedURL,
                                                       guid: episode.guid, actuallyPlaying: true))

        let player = PlayerService()
        player.isPlaying = true // A request can set this before AVPlayer is ready.
        XCTAssertFalse(player.isActuallyPlaying)
    }

    func testPauseButtonUsesIdempotentPauseCommand() {
        XCTAssertEqual(PhoneWatchControlView.playbackCommand(isPlaying: true), "pause")
        XCTAssertEqual(PhoneWatchControlView.playbackCommand(isPlaying: false), "toggle")
    }

    func testProvisionalHandoffMayOnlyStopMatchingPhoneEpisode() {
        let podcast = Podcast(feedURL: "https://example.com/feed", title: "Show")
        let episode = Episode(guid: "two", title: "Two", audioURL: "https://example.com/two.mp3")
        episode.podcast = podcast
        XCTAssertFalse(PhonePlaybackAckPolicy.matches(episode, feedURL: podcast.feedURL, guid: "one"))
        XCTAssertTrue(PhonePlaybackAckPolicy.matches(episode, feedURL: podcast.feedURL, guid: "two"))
    }
}
