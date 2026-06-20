import XCTest
@testable import Earshot

/// Unit tests for the pure playback rules. No AVFoundation, no real files.
final class PlaybackLogicTests: XCTestCase {

    // MARK: Source resolution

    func testResolvesLocalFileWhenDownloadedAndPresent() {
        let url = PlaybackLogic.resolvePlaybackURL(
            downloadPath: "/var/mobile/episode.mp3",
            audioURL: "https://example.com/stream.mp3",
            fileExists: { _ in true }
        )
        XCTAssertNotNil(url)
        XCTAssertTrue(url!.isFileURL)
        XCTAssertEqual(url!.path, "/var/mobile/episode.mp3")
    }

    func testFallsBackToStreamWhenDownloadFileMissing() {
        let url = PlaybackLogic.resolvePlaybackURL(
            downloadPath: "/var/mobile/missing.mp3",
            audioURL: "https://example.com/stream.mp3",
            fileExists: { _ in false }
        )
        XCTAssertNotNil(url)
        XCTAssertFalse(url!.isFileURL)
        XCTAssertEqual(url!.absoluteString, "https://example.com/stream.mp3")
    }

    func testStreamsWhenNoDownloadPath() {
        let url = PlaybackLogic.resolvePlaybackURL(
            downloadPath: nil,
            audioURL: "https://example.com/stream.mp3",
            fileExists: { _ in false }
        )
        XCTAssertEqual(url?.absoluteString, "https://example.com/stream.mp3")
    }

    func testReturnsNilForInvalidStreamURL() {
        // Empty string and a scheme-less fragment are both unusable.
        XCTAssertNil(PlaybackLogic.resolvePlaybackURL(
            downloadPath: nil, audioURL: "", fileExists: { _ in false }
        ))
        XCTAssertNil(PlaybackLogic.resolvePlaybackURL(
            downloadPath: nil, audioURL: "   ", fileExists: { _ in false }
        ))
        XCTAssertNil(PlaybackLogic.resolvePlaybackURL(
            downloadPath: nil, audioURL: "not a url", fileExists: { _ in false }
        ))
    }

    func testEmptyDownloadPathFallsBackToStream() {
        let url = PlaybackLogic.resolvePlaybackURL(
            downloadPath: "",
            audioURL: "https://example.com/stream.mp3",
            fileExists: { _ in true }
        )
        XCTAssertEqual(url?.absoluteString, "https://example.com/stream.mp3")
    }

    // MARK: Completion / resume logic

    func testBelowThresholdResumesAtPosition() {
        // 50 of 100 seconds -> resume at 50, not played.
        let decision = PlaybackLogic.completionDecision(position: 50, duration: 100)
        XCTAssertFalse(decision.shouldMarkPlayed)
        XCTAssertEqual(decision.resumePosition, 50)
    }

    func testAtThresholdMarksPlayedAndRestarts() {
        // Exactly 95% -> played, restart from 0.
        let decision = PlaybackLogic.completionDecision(position: 95, duration: 100)
        XCTAssertTrue(decision.shouldMarkPlayed)
        XCTAssertEqual(decision.resumePosition, 0)
    }

    func testPastThresholdMarksPlayedAndRestarts() {
        let decision = PlaybackLogic.completionDecision(position: 99, duration: 100)
        XCTAssertTrue(decision.shouldMarkPlayed)
        XCTAssertEqual(decision.resumePosition, 0)
    }

    func testUnknownDurationNeverMarksPlayed() {
        let decision = PlaybackLogic.completionDecision(position: 500, duration: nil)
        XCTAssertFalse(decision.shouldMarkPlayed)
        XCTAssertEqual(decision.resumePosition, 500)
    }

    func testZeroDurationNeverMarksPlayed() {
        let decision = PlaybackLogic.completionDecision(position: 10, duration: 0)
        XCTAssertFalse(decision.shouldMarkPlayed)
        XCTAssertEqual(decision.resumePosition, 10)
    }

    func testNegativePositionClampsToZero() {
        let decision = PlaybackLogic.completionDecision(position: -5, duration: 100)
        XCTAssertFalse(decision.shouldMarkPlayed)
        XCTAssertEqual(decision.resumePosition, 0)
    }

    // MARK: Speed resolution

    func testPodcastOverrideWins() {
        let rate = PlaybackLogic.effectivePlaybackRate(podcastSpeedOverride: 1.75, globalSpeed: 1.0)
        XCTAssertEqual(rate, 1.75)
    }

    func testFallsBackToGlobalWhenNoOverride() {
        let rate = PlaybackLogic.effectivePlaybackRate(podcastSpeedOverride: nil, globalSpeed: 1.5)
        XCTAssertEqual(rate, 1.5)
    }

    func testFallsBackToOneWhenNothingSet() {
        let rate = PlaybackLogic.effectivePlaybackRate(podcastSpeedOverride: nil, globalSpeed: 0)
        XCTAssertEqual(rate, 1.0)
    }

    func testNonPositiveOverrideIgnored() {
        let rate = PlaybackLogic.effectivePlaybackRate(podcastSpeedOverride: 0, globalSpeed: 1.25)
        XCTAssertEqual(rate, 1.25)
    }
}
