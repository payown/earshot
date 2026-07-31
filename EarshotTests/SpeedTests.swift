import XCTest
@testable import Earshot

/// Unit tests for speed selection logic: per-podcast override vs global
/// fallback, clamping, spoken rate formatting, and the speed shortcuts list.
/// No AVFoundation, no real audio.
final class SpeedTests: XCTestCase {

    // MARK: effectivePlaybackRate

    func testPodcastOverrideWinsOverGlobal() {
        XCTAssertEqual(
            PlaybackLogic.effectivePlaybackRate(podcastSpeedOverride: 2.0, globalSpeed: 1.0),
            2.0
        )
    }

    func testGlobalUsedWhenNoOverride() {
        XCTAssertEqual(
            PlaybackLogic.effectivePlaybackRate(podcastSpeedOverride: nil, globalSpeed: 1.5),
            1.5
        )
    }

    func testNilAndZeroOverrideFallThroughToGlobal() {
        XCTAssertEqual(
            PlaybackLogic.effectivePlaybackRate(podcastSpeedOverride: 0.0, globalSpeed: 1.25),
            1.25
        )
        XCTAssertEqual(
            PlaybackLogic.effectivePlaybackRate(podcastSpeedOverride: nil, globalSpeed: 1.25),
            1.25
        )
    }

    func testNegativeOverrideIgnored() {
        XCTAssertEqual(
            PlaybackLogic.effectivePlaybackRate(podcastSpeedOverride: -1.0, globalSpeed: 1.0),
            1.0
        )
    }

    func testFallsBackToOneWhenBothMissing() {
        XCTAssertEqual(
            PlaybackLogic.effectivePlaybackRate(podcastSpeedOverride: nil, globalSpeed: 0.0),
            1.0
        )
    }

    // MARK: clampedSpeed

    func testClampedSpeedAtMinimum() {
        XCTAssertEqual(PlaybackLogic.clampedSpeed(0.5), 0.5)
    }

    func testClampedSpeedAtMaximum() {
        XCTAssertEqual(PlaybackLogic.clampedSpeed(5.0), 5.0)
    }

    func testClampedSpeedBelowMinClampsToMin() {
        XCTAssertEqual(PlaybackLogic.clampedSpeed(0.1), 0.5)
        XCTAssertEqual(PlaybackLogic.clampedSpeed(-1.0), 0.5)
    }

    func testClampedSpeedAboveMaxClampsToMax() {
        XCTAssertEqual(PlaybackLogic.clampedSpeed(10.0), 5.0)
        XCTAssertEqual(PlaybackLogic.clampedSpeed(5.1), 5.0)
    }

    func testClampedSpeedRoundsFloatingPointNearMiss() {
        // 1.5 + 0.1 in floating-point arithmetic may produce 1.5999999... or
        // 1.6000000...01. clampedSpeed should produce exactly 1.6.
        let sum = 1.5 + 0.1  // may not be exactly 1.6
        XCTAssertEqual(PlaybackLogic.clampedSpeed(sum), 1.6, accuracy: 0.0001)
    }

    func testClampedSpeedMidRange() {
        // Values that are on the 0.1 grid must come back unchanged.
        XCTAssertEqual(PlaybackLogic.clampedSpeed(1.5), 1.5)
        XCTAssertEqual(PlaybackLogic.clampedSpeed(2.0), 2.0)
        XCTAssertEqual(PlaybackLogic.clampedSpeed(0.8), 0.8)
        XCTAssertEqual(PlaybackLogic.clampedSpeed(3.5), 3.5)
    }

    // MARK: spokenRate

    func testSpokenRateWholeNumber() {
        XCTAssertEqual(PlaybackLogic.spokenRate(1.0), "1 times")
        XCTAssertEqual(PlaybackLogic.spokenRate(2.0), "2 times")
        XCTAssertEqual(PlaybackLogic.spokenRate(3.0), "3 times")
    }

    func testSpokenRateFractional() {
        XCTAssertEqual(PlaybackLogic.spokenRate(1.5), "1.5 times")
        XCTAssertEqual(PlaybackLogic.spokenRate(0.8), "0.8 times")
        XCTAssertEqual(PlaybackLogic.spokenRate(1.25), "1.25 times")
    }

    func testSpokenRateAtBoundaries() {
        XCTAssertEqual(PlaybackLogic.spokenRate(0.5), "0.5 times")
        XCTAssertEqual(PlaybackLogic.spokenRate(5.0), "5 times")
    }

    // MARK: Speed range constants

    func testMinMaxSpeedRange() {
        XCTAssertEqual(PlaybackLogic.minSpeed, 0.5)
        XCTAssertEqual(PlaybackLogic.maxSpeed, 5.0)
    }

    func testSpeedStepIsOneTenth() {
        XCTAssertEqual(PlaybackLogic.speedStep, 0.1, accuracy: 0.0001)
    }

    // MARK: speedShortcuts

    func testSpeedShortcutsAreNonEmpty() {
        XCTAssertFalse(PlaybackLogic.speedShortcuts.isEmpty)
    }

    func testSpeedShortcutsAreWithinRange() {
        for speed in PlaybackLogic.speedShortcuts {
            XCTAssertGreaterThanOrEqual(speed, PlaybackLogic.minSpeed,
                "\(speed)x is below min \(PlaybackLogic.minSpeed)x")
            XCTAssertLessThanOrEqual(speed, PlaybackLogic.maxSpeed,
                "\(speed)x is above max \(PlaybackLogic.maxSpeed)x")
        }
    }

    func testSpeedShortcutsIncludeOneX() {
        // 1.0x (no speed change) must be a reachable shortcut.
        XCTAssertTrue(PlaybackLogic.speedShortcuts.contains(1.0))
    }

    func testSpeedShortcutsInclude15x() {
        // 1.5x is the most common shortcut from the Flutter version.
        XCTAssertTrue(PlaybackLogic.speedShortcuts.contains(1.5))
    }

    func testSpeedShortcutsAreAscending() {
        let sorted = PlaybackLogic.speedShortcuts.sorted()
        XCTAssertEqual(PlaybackLogic.speedShortcuts, sorted,
            "Shortcuts should be in ascending order for display")
    }

    // MARK: Full speed range coverage

    func testRangeContainsAtLeast45Steps() {
        // 0.5 to 5.0 in 0.1 steps gives at least 45 steps within the range.
        var count = 0
        var speed = PlaybackLogic.minSpeed
        while speed < PlaybackLogic.maxSpeed {
            count += 1
            speed = PlaybackLogic.clampedSpeed(speed + PlaybackLogic.speedStep)
        }
        XCTAssertGreaterThanOrEqual(count, 45)
    }

    func testRangeBoundariesIncludeMinAndMax() {
        // Verify the stepper can reach both endpoints.
        XCTAssertEqual(PlaybackLogic.clampedSpeed(PlaybackLogic.minSpeed), PlaybackLogic.minSpeed)
        XCTAssertEqual(PlaybackLogic.clampedSpeed(PlaybackLogic.maxSpeed), PlaybackLogic.maxSpeed)
    }
}
