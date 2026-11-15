import XCTest
@testable import Earshot

final class PairedPlaybackStateTests: XCTestCase {
    func testWatchStateIsRecognizedOnlyFromWatchOwner() {
        let state = PairedPlaybackState(owner: .watch, feedURL: "https://example.com/feed",
                                        guid: "one", title: "One", podcastTitle: "Show",
                                        audioURL: "https://example.com/one.mp3", position: 80,
                                        rate: 1.5, playing: true, observedAt: 1_000)
        XCTAssertEqual(PairedPlaybackState.decode(state.encoded()), state)
        XCTAssertTrue(state.matches(feedURL: "https://example.com/feed", guid: "one"))
        XCTAssertFalse(state.matches(feedURL: "https://example.com/feed", guid: "two"))
        XCTAssertFalse(state.isCurrent(at: 1_100))
    }

    func testPhoneDoesNotClaimHandoffWithoutMatchingWatchPause() {
        let reply: [String: Any] = ["accepted": true, "owner": "watch", "playing": false,
                                     "feedURL": "https://example.com/feed", "guid": "one"]
        XCTAssertTrue(PairedPlaybackHandoffDecision.sourcePaused(reply, owner: .watch,
                                                                  feedURL: "https://example.com/feed", guid: "one"))
        var wrongOwner = reply
        wrongOwner["owner"] = "phone"
        XCTAssertFalse(PairedPlaybackHandoffDecision.sourcePaused(wrongOwner, owner: .watch,
                                                                   feedURL: "https://example.com/feed", guid: "one"))
        var stillPlaying = reply
        stillPlaying["playing"] = true
        XCTAssertFalse(PairedPlaybackHandoffDecision.sourcePaused(stillPlaying, owner: .watch,
                                                                   feedURL: "https://example.com/feed", guid: "one"))
    }

    func testPhonePlaybackCheckpointIsDistinctFromTransportObservation() {
        let initial = PairedPlaybackState(owner: .phone, feedURL: "https://example.com/feed",
                                           guid: "one", title: "One", audioURL: "https://example.com/one.mp3",
                                           position: 48, playing: false, observedAt: 1_000,
                                           playbackChangedAt: 990)
        let refreshed = PairedPlaybackState(owner: .phone, feedURL: initial.feedURL,
                                             guid: initial.guid, title: initial.title,
                                             audioURL: initial.audioURL, position: initial.position,
                                             playing: false, observedAt: 1_030,
                                             playbackChangedAt: 990)
        XCTAssertEqual(PairedPlaybackState.decode(refreshed.encoded())?.playbackChangedAt, 990)
        XCTAssertFalse(refreshed.hasPlaybackChange(comparedWith: initial))
        let rewind = PairedPlaybackState(owner: .phone, feedURL: initial.feedURL,
                                          guid: initial.guid, title: initial.title,
                                          audioURL: initial.audioURL, position: 0,
                                          playing: false, observedAt: 1_031,
                                          playbackChangedAt: 1_031)
        XCTAssertTrue(rewind.hasPlaybackChange(comparedWith: refreshed))
        XCTAssertEqual(PairedPlaybackState.decode(rewind.encoded())?.position, 0)
    }
}
