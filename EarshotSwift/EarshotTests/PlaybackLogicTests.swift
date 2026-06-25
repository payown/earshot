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

    // MARK: Up-next resolution honoring auto-advance boundaries (#446)

    /// A small queue of (episode id, podcast group key) pairs for boundary tests.
    /// Episode 1 / 2 belong to podcast "A"; episode 3 belongs to podcast "B".
    private let boundaryQueue: [(id: Int, groupKey: String)] = [
        (id: 1, groupKey: "A"),
        (id: 2, groupKey: "A"),
        (id: 3, groupKey: "B"),
    ]

    func testBoundaryEpisodeOffStopsEvenWithSamePodcastNext() {
        // Tightest boundary: episode-continuation off stops after every episode,
        // even when the next item is the same podcast (group setting is moot).
        XCTAssertNil(PlaybackLogic.nextUpHonoringBoundaries(
            queue: boundaryQueue,
            after: 1,
            currentGroupKey: "A",
            continueAfterEpisode: false,
            continueAfterGroupEnds: true
        ))
    }

    func testBoundaryGroupOffStopsAtDifferentPodcastNext() {
        // Episode on, group off: finishing the last item of group "A" (id 2),
        // the next item (id 3) is group "B" -> stop at the group boundary.
        XCTAssertNil(PlaybackLogic.nextUpHonoringBoundaries(
            queue: [(id: 2, groupKey: "A"), (id: 3, groupKey: "B")],
            after: 2,
            currentGroupKey: "A",
            continueAfterEpisode: true,
            continueAfterGroupEnds: false
        ))
    }

    func testBoundaryGroupOffAdvancesWhenNextIsSamePodcast() {
        // Episode on, group off: the next item (id 2) is the same group "A" as the
        // finished item (id 1) -> advance.
        XCTAssertEqual(PlaybackLogic.nextUpHonoringBoundaries(
            queue: boundaryQueue,
            after: 1,
            currentGroupKey: "A",
            continueAfterEpisode: true,
            continueAfterGroupEnds: false
        ), 2)
    }

    func testBoundaryBothOnAdvancesWithinGroup() {
        XCTAssertEqual(PlaybackLogic.nextUpHonoringBoundaries(
            queue: boundaryQueue,
            after: 1,
            currentGroupKey: "A",
            continueAfterEpisode: true,
            continueAfterGroupEnds: true
        ), 2)
    }

    func testBoundaryBothOnAdvancesAcrossGroup() {
        // Both on: advancing into a different podcast is allowed.
        XCTAssertEqual(PlaybackLogic.nextUpHonoringBoundaries(
            queue: [(id: 2, groupKey: "A"), (id: 3, groupKey: "B")],
            after: 2,
            currentGroupKey: "A",
            continueAfterEpisode: true,
            continueAfterGroupEnds: true
        ), 3)
    }

    func testBoundaryReturnsNilAtQueueEnd() {
        XCTAssertNil(PlaybackLogic.nextUpHonoringBoundaries(
            queue: [(id: 1, groupKey: "A")],
            after: 1,
            currentGroupKey: "A",
            continueAfterEpisode: true,
            continueAfterGroupEnds: true
        ))
    }

    func testBoundaryReturnsNilWhenQueueEmpty() {
        XCTAssertNil(PlaybackLogic.nextUpHonoringBoundaries(
            queue: [],
            after: 1,
            currentGroupKey: "A",
            continueAfterEpisode: true,
            continueAfterGroupEnds: true
        ))
    }

    func testBoundaryGroupOffWithNilCurrentGroupAdvances() {
        // A nil current group key cannot define a boundary; advance normally even
        // with group-continuation off.
        XCTAssertEqual(PlaybackLogic.nextUpHonoringBoundaries(
            queue: [(id: 1, groupKey: "A"), (id: 2, groupKey: "B")],
            after: nil,
            currentGroupKey: nil,
            continueAfterEpisode: true,
            continueAfterGroupEnds: false
        ), 1)
    }

    func testBoundaryEpisodeOffWinsWhenGroupAlsoOff() {
        // Both boundaries off: episode-continuation is the tightest, so it must
        // short-circuit to nil before the group check runs -- proven here by a next
        // item in the SAME group, which the group rule alone would have advanced to.
        XCTAssertNil(PlaybackLogic.nextUpHonoringBoundaries(
            queue: boundaryQueue,
            after: 1,
            currentGroupKey: "A",
            continueAfterEpisode: false,
            continueAfterGroupEnds: false
        ))
    }

    func testBoundaryGroupOffAdvancesWhenCurrentSitsMidQueue() {
        // The finished episode (id 1) is not at the head; "next" is the first item
        // whose id differs from current (id 2, same group "A"), not queue.first.
        // Group-off must still advance because that next item shares the group.
        XCTAssertEqual(PlaybackLogic.nextUpHonoringBoundaries(
            queue: [(id: 2, groupKey: "A"), (id: 1, groupKey: "A"), (id: 3, groupKey: "B")],
            after: 1,
            currentGroupKey: "A",
            continueAfterEpisode: true,
            continueAfterGroupEnds: false
        ), 2)
    }

    func testBoundaryGroupOffWithNonNilCurrentButUnknownGroupAdvances() {
        // A real finished episode whose group key we couldn't resolve (nil) cannot
        // define a group boundary, so group-off still advances to the next item even
        // though it is a different podcast.
        XCTAssertEqual(PlaybackLogic.nextUpHonoringBoundaries(
            queue: [(id: 1, groupKey: "A"), (id: 2, groupKey: "B")],
            after: 9,
            currentGroupKey: nil,
            continueAfterEpisode: true,
            continueAfterGroupEnds: false
        ), 1)
    }

    func testBoundaryBothOnAdvancesToImmediateNextAcrossMultipleGroups() {
        // Ordering guard: with three distinct groups and both boundaries on, the
        // result is the immediate next queue item (id 2, group "B"), never a later
        // group skipped over.
        XCTAssertEqual(PlaybackLogic.nextUpHonoringBoundaries(
            queue: [(id: 1, groupKey: "A"), (id: 2, groupKey: "B"), (id: 3, groupKey: "C")],
            after: 1,
            currentGroupKey: "A",
            continueAfterEpisode: true,
            continueAfterGroupEnds: true
        ), 2)
    }
}
