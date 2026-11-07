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
}
