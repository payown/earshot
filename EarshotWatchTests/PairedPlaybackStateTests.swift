import XCTest
@testable import EarshotWatch

final class PairedPlaybackStateTests: XCTestCase {
    private func phone(position: Double = 120, playing: Bool = true,
                       time: TimeInterval = 1_000) -> PairedPlaybackState {
        PairedPlaybackState(owner: .phone, feedURL: "https://example.com/feed",
                            guid: "episode", title: "Episode", podcastTitle: "Show",
                            audioURL: "https://example.com/audio.mp3", position: position,
                            rate: 1.25, playing: playing, observedAt: time)
    }

    func testOpeningWatchCanDecodeCurrentPhoneSessionWithoutPhoneStore() {
        let sent = phone()
        let received = PairedPlaybackState.decode(sent.encoded())
        XCTAssertEqual(received, sent)
        XCTAssertTrue(received?.hasEpisode == true)
        XCTAssertTrue(received?.isCurrent(at: 1_005) == true)
        XCTAssertEqual(received?.owner, .phone)
    }

    func testPlayingPauseSeekAndSpeedChangesPublishWithoutPositionPolling() {
        let playing = phone()
        XCTAssertTrue(playing.needsPublication(after: nil))
        XCTAssertTrue(phone(playing: false, time: 1_001).needsPublication(after: playing))
        XCTAssertTrue(phone(position: 600, time: 1_001).needsPublication(after: playing))
        let speed = PairedPlaybackState(owner: .phone, feedURL: playing.feedURL, guid: playing.guid,
                                        title: playing.title, podcastTitle: playing.podcastTitle,
                                        audioURL: playing.audioURL, position: 121, rate: 2,
                                        playing: true, observedAt: 1_001)
        XCTAssertTrue(speed.needsPublication(after: playing))
        XCTAssertFalse(phone(position: 125, time: 1_004).needsPublication(after: playing))
        XCTAssertTrue(phone(position: 145, time: 1_020).needsPublication(after: playing))
    }

    func testDelayedContextCannotReplaceNewerMessageAfterReconnection() {
        let newer = phone(position: 300, time: 1_100)
        XCTAssertFalse(phone(position: 120, time: 1_000).supersedes(newer))
        XCTAssertTrue(newer.supersedes(phone()))
        XCTAssertFalse(phone(time: 1_100).supersedes(newer))
        XCTAssertFalse(PairedPlaybackState(owner: .watch).supersedes(newer))
    }

    func testUnavailablePhoneStateIsNotRepresentedAsLivePlayback() {
        XCTAssertFalse(phone(time: 1_000).isCurrent(at: 1_100))
        XCTAssertFalse(phone(time: 1_100).isCurrent(at: 1_000))
    }

    func testHandoffRequiresMatchingSourcePauseAcknowledgment() {
        let reply: [String: Any] = ["accepted": true, "owner": "phone", "playing": false,
                                     "feedURL": "https://example.com/feed", "guid": "episode"]
        XCTAssertTrue(PairedPlaybackHandoffDecision.sourcePaused(reply, owner: .phone,
                                                                  feedURL: "https://example.com/feed", guid: "episode"))
        var failed = reply
        failed["accepted"] = false
        XCTAssertFalse(PairedPlaybackHandoffDecision.sourcePaused(failed, owner: .phone,
                                                                   feedURL: "https://example.com/feed", guid: "episode"))
        failed = reply
        failed["guid"] = "another"
        XCTAssertFalse(PairedPlaybackHandoffDecision.sourcePaused(failed, owner: .phone,
                                                                   feedURL: "https://example.com/feed", guid: "episode"))
    }

    func testHandoffUsesPositionAtConfirmedPauseAfterReceiverStartup() {
        let reply: [String: Any] = ["accepted": true, "owner": "phone", "playing": false,
                                     "feedURL": "https://example.com/feed", "guid": "episode",
                                     "position": 151.75]
        // The earlier snapshot was at 120 seconds; the phone kept playing
        // while the watch opened its stream.
        XCTAssertEqual(PairedPlaybackHandoffDecision.pausedSourcePosition(
            reply, owner: .phone, feedURL: "https://example.com/feed", guid: "episode"), 151.75)
        var invalid = reply
        invalid["position"] = Double.infinity
        XCTAssertNil(PairedPlaybackHandoffDecision.pausedSourcePosition(
            invalid, owner: .phone, feedURL: "https://example.com/feed", guid: "episode"))
        invalid = reply
        invalid["guid"] = "different"
        XCTAssertNil(PairedPlaybackHandoffDecision.pausedSourcePosition(
            invalid, owner: .phone, feedURL: "https://example.com/feed", guid: "episode"))
    }
}
