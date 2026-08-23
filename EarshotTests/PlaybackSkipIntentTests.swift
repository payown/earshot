import XCTest
@testable import Earshot

final class PlaybackSkipIntentTests: XCTestCase {
    func testRequestedIntervalWinsOverConfiguredValue() {
        XCTAssertEqual(
            PlaybackSkipIntentLogic.interval(requested: 45, configured: 30),
            45
        )
    }

    func testMissingIntervalUsesConfiguredDirectionValue() {
        XCTAssertEqual(
            PlaybackSkipIntentLogic.interval(requested: nil, configured: 30),
            30
        )
        XCTAssertEqual(
            PlaybackSkipIntentLogic.interval(requested: nil, configured: 15),
            15
        )
    }

    func testIntervalsAreBoundedFromOneSecondThroughTenMinutes() {
        XCTAssertEqual(
            PlaybackSkipIntentLogic.interval(requested: -10, configured: 30),
            1
        )
        XCTAssertEqual(
            PlaybackSkipIntentLogic.interval(requested: 900, configured: 30),
            600
        )
    }

    func testSuccessDialogHandlesDirectionAndPluralization() {
        XCTAssertEqual(
            PlaybackSkipIntentLogic.successDialog(direction: .forward, seconds: 1),
            "Skipped forward 1 second."
        )
        XCTAssertEqual(
            PlaybackSkipIntentLogic.successDialog(direction: .backward, seconds: 45),
            "Skipped back 45 seconds."
        )
    }

    @MainActor
    func testPlayerRejectsCustomSkipsWithoutLoadedEpisode() {
        let player = PlayerService()

        XCTAssertFalse(player.skipForward(seconds: 45))
        XCTAssertFalse(player.skipBack(seconds: 20))
    }
}
