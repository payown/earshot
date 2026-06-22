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

    // MARK: Position-persist cadence (#362)

    func testFirstTickAlwaysPersists() {
        // No prior write for this episode -> persist immediately.
        XCTAssertTrue(PlaybackLogic.shouldPersistTick(currentSecond: 0, lastPersistedSecond: nil))
        XCTAssertTrue(PlaybackLogic.shouldPersistTick(currentSecond: 42, lastPersistedSecond: nil))
    }

    func testDoesNotPersistBeforeIntervalElapses() {
        // Default interval is 5s; ticks 1..4 after a write at 0 should not save.
        for second in 1...4 {
            XCTAssertFalse(
                PlaybackLogic.shouldPersistTick(currentSecond: second, lastPersistedSecond: 0),
                "second \(second) should be throttled"
            )
        }
    }

    func testPersistsOnceIntervalElapses() {
        XCTAssertTrue(PlaybackLogic.shouldPersistTick(currentSecond: 5, lastPersistedSecond: 0))
        XCTAssertTrue(PlaybackLogic.shouldPersistTick(currentSecond: 6, lastPersistedSecond: 0))
        XCTAssertTrue(PlaybackLogic.shouldPersistTick(currentSecond: 30, lastPersistedSecond: 25))
    }

    func testBackwardJumpPersistsImmediately() {
        // A seek/skip-back lands behind the last write — reflect it promptly.
        XCTAssertTrue(PlaybackLogic.shouldPersistTick(currentSecond: 10, lastPersistedSecond: 40))
    }

    func testRespectsCustomInterval() {
        XCTAssertFalse(PlaybackLogic.shouldPersistTick(currentSecond: 9, lastPersistedSecond: 0, interval: 10))
        XCTAssertTrue(PlaybackLogic.shouldPersistTick(currentSecond: 10, lastPersistedSecond: 0, interval: 10))
    }

    func testDefaultIntervalIsCoarserThanOneSecond() {
        // Guards against regressing back to a per-second save.
        XCTAssertGreaterThan(PlaybackLogic.positionPersistInterval, 1)
    }

    // MARK: Now-playing elapsed-sync cadence (#412)

    func testFirstNowPlayingSyncAfterDiscontinuityAlwaysWrites() {
        // After every play / pause / seek / rate change, lastSyncedSecond is reset
        // to nil so the next tick re-anchors the lock-screen elapsed time exactly.
        XCTAssertTrue(PlaybackLogic.shouldSyncNowPlayingElapsed(currentSecond: 0, lastSyncedSecond: nil))
        XCTAssertTrue(PlaybackLogic.shouldSyncNowPlayingElapsed(currentSecond: 137, lastSyncedSecond: nil))
    }

    func testNowPlayingNotResyncedEverySecond() {
        // The fix's whole point: between syncs the system extrapolates elapsed time,
        // so ticks within the interval must NOT rewrite the cross-process dictionary.
        for second in 1...4 {
            XCTAssertFalse(
                PlaybackLogic.shouldSyncNowPlayingElapsed(currentSecond: second, lastSyncedSecond: 0),
                "second \(second) should be throttled, not a per-tick now-playing rewrite"
            )
        }
    }

    func testNowPlayingResyncsOnceIntervalElapses() {
        XCTAssertTrue(PlaybackLogic.shouldSyncNowPlayingElapsed(currentSecond: 5, lastSyncedSecond: 0))
        XCTAssertTrue(PlaybackLogic.shouldSyncNowPlayingElapsed(currentSecond: 60, lastSyncedSecond: 50))
    }

    func testNowPlayingBackwardJumpResyncsImmediately() {
        // A seek/skip-back the system can't have extrapolated — correct it at once.
        XCTAssertTrue(PlaybackLogic.shouldSyncNowPlayingElapsed(currentSecond: 12, lastSyncedSecond: 55))
    }

    func testNowPlayingSameSecondDuplicateTickDoesNotResync() {
        // The periodic observer can emit the same integer second twice in a row.
        // A repeat at the second we just synced is neither forward-interval nor a
        // backward jump, so it must NOT rewrite the cross-process dictionary.
        XCTAssertFalse(PlaybackLogic.shouldSyncNowPlayingElapsed(currentSecond: 0, lastSyncedSecond: 0))
        XCTAssertFalse(PlaybackLogic.shouldSyncNowPlayingElapsed(currentSecond: 50, lastSyncedSecond: 50))
    }

    func testNowPlayingRespectsCustomInterval() {
        XCTAssertFalse(PlaybackLogic.shouldSyncNowPlayingElapsed(currentSecond: 2, lastSyncedSecond: 0, interval: 3))
        XCTAssertTrue(PlaybackLogic.shouldSyncNowPlayingElapsed(currentSecond: 3, lastSyncedSecond: 0, interval: 3))
    }

    func testNowPlayingSyncIntervalIsCoarserThanOneSecond() {
        // Guards against regressing back to a per-second nowPlayingInfo rewrite,
        // which is the sustained-CPU / overheating cause in #412.
        XCTAssertGreaterThan(PlaybackLogic.nowPlayingElapsedSyncInterval, 1)
    }

    // MARK: Up-next resolution (gapless advance)

    func testNextUpIsFirstQueueItemAfterCurrent() {
        XCTAssertEqual(PlaybackLogic.nextUpID(queue: [1, 2, 3], after: 1), 2)
    }

    func testNextUpSkipsTheCurrentEpisodeWhereverItSits() {
        // The finished episode may still be in the list when we look ahead.
        XCTAssertEqual(PlaybackLogic.nextUpID(queue: [2, 1, 3], after: 1), 2)
    }

    func testNextUpIsHeadWhenNothingPlaying() {
        XCTAssertEqual(PlaybackLogic.nextUpID(queue: [5, 6], after: nil), 5)
    }

    func testNextUpIsNilWhenQueueEmptyOrOnlyCurrent() {
        XCTAssertNil(PlaybackLogic.nextUpID(queue: [], after: 1))
        XCTAssertNil(PlaybackLogic.nextUpID(queue: [1], after: 1))
    }
}
