import XCTest
@testable import Earshot

/// Unit tests for the pure remaining-plus-total length logic shown on episode
/// rows (#493/#552). No SwiftData, no UI.
final class EpisodeTimeLogicTests: XCTestCase {

    // MARK: display decision

    func testInProgressIsRemaining() {
        // 30 min episode, 10 min in -> 20 min remaining.
        let d = EpisodeTimeLogic.display(positionSeconds: 600, durationSeconds: 1800, isPlayed: false)
        XCTAssertEqual(d, .remaining(1200, total: 1800))
    }

    func testNotStartedIsTotal() {
        let d = EpisodeTimeLogic.display(positionSeconds: 0, durationSeconds: 1800, isPlayed: false)
        XCTAssertEqual(d, .total(1800))
    }

    func testPlayedIsNone() {
        let d = EpisodeTimeLogic.display(positionSeconds: 600, durationSeconds: 1800, isPlayed: true)
        XCTAssertEqual(d, .none)
    }

    func testUnknownDurationIsNone() {
        XCTAssertEqual(
            EpisodeTimeLogic.display(positionSeconds: 600, durationSeconds: nil, isPlayed: false),
            .none
        )
    }

    func testZeroDurationIsNone() {
        XCTAssertEqual(
            EpisodeTimeLogic.display(positionSeconds: 0, durationSeconds: 0, isPlayed: false),
            .none
        )
    }

    func testFinishedButUnmarkedIsNone() {
        // Position at/over duration but not flagged played -> no "0 min left".
        XCTAssertEqual(
            EpisodeTimeLogic.display(positionSeconds: 1800, durationSeconds: 1800, isPlayed: false),
            .none
        )
        XCTAssertEqual(
            EpisodeTimeLogic.display(positionSeconds: 2000, durationSeconds: 1800, isPlayed: false),
            .none
        )
    }

    func testNegativePositionClampsToTotal() {
        XCTAssertEqual(
            EpisodeTimeLogic.display(positionSeconds: -50, durationSeconds: 1800, isPlayed: false),
            .total(1800)
        )
    }

    // MARK: visible text

    func testVisibleRemainingMinutes() {
        XCTAssertEqual(
            EpisodeTimeLogic.visibleText(positionSeconds: 600, durationSeconds: 1800, isPlayed: false),
            "20 min left · 30 min total"
        )
    }

    func testVisibleTotalMinutes() {
        XCTAssertEqual(
            EpisodeTimeLogic.visibleText(positionSeconds: 0, durationSeconds: 2520, isPlayed: false),
            "42 min"
        )
    }

    func testVisibleHoursAndMinutes() {
        // 1h 5m total.
        XCTAssertEqual(
            EpisodeTimeLogic.visibleText(positionSeconds: 0, durationSeconds: 3900, isPlayed: false),
            "1 hr 5 min"
        )
    }

    func testVisibleExactHour() {
        XCTAssertEqual(
            EpisodeTimeLogic.visibleText(positionSeconds: 0, durationSeconds: 3600, isPlayed: false),
            "1 hr"
        )
    }

    func testVisibleSubMinuteRemainderFloorsToOne() {
        // 20 seconds left should read as "1 min left", never "0 min left".
        XCTAssertEqual(
            EpisodeTimeLogic.visibleText(positionSeconds: 1780, durationSeconds: 1800, isPlayed: false),
            "1 min left · 30 min total"
        )
    }

    func testVisibleNilWhenPlayed() {
        XCTAssertNil(
            EpisodeTimeLogic.visibleText(positionSeconds: 600, durationSeconds: 1800, isPlayed: true)
        )
    }

    func testVisibleNilWhenUnknownDuration() {
        XCTAssertNil(
            EpisodeTimeLogic.visibleText(positionSeconds: 0, durationSeconds: nil, isPlayed: false)
        )
    }

    // MARK: spoken text

    func testSpokenRemainingReadsNaturally() {
        XCTAssertEqual(
            EpisodeTimeLogic.spokenText(positionSeconds: 600, durationSeconds: 1800, isPlayed: false),
            "20 minutes left, 30 minutes total"
        )
    }

    func testSpokenTotalReadsNaturally() {
        XCTAssertEqual(
            EpisodeTimeLogic.spokenText(positionSeconds: 0, durationSeconds: 2520, isPlayed: false),
            "42 minutes"
        )
    }

    func testSpokenHoursAndMinutes() {
        XCTAssertEqual(
            EpisodeTimeLogic.spokenText(positionSeconds: 0, durationSeconds: 3900, isPlayed: false),
            "1 hour 5 minutes"
        )
    }

    func testSpokenExactHourOmitsZeroMinutes() {
        XCTAssertEqual(
            EpisodeTimeLogic.spokenText(positionSeconds: 0, durationSeconds: 3600, isPlayed: false),
            "1 hour"
        )
    }

    func testSpokenSingularMinute() {
        XCTAssertEqual(
            EpisodeTimeLogic.spokenText(positionSeconds: 0, durationSeconds: 60, isPlayed: false),
            "1 minute"
        )
    }

    func testSpokenNilWhenPlayed() {
        XCTAssertNil(
            EpisodeTimeLogic.spokenText(positionSeconds: 600, durationSeconds: 1800, isPlayed: true)
        )
    }

    // MARK: wholeMinutes rounding

    func testWholeMinutesRoundsToNearest() {
        XCTAssertEqual(EpisodeTimeLogic.wholeMinutes(89), 1)   // 1.48 -> 1
        XCTAssertEqual(EpisodeTimeLogic.wholeMinutes(90), 2)   // 1.5 -> 2
        XCTAssertEqual(EpisodeTimeLogic.wholeMinutes(0), 0)
        XCTAssertEqual(EpisodeTimeLogic.wholeMinutes(1), 1)    // floor of 1
    }
}
