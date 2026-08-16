import XCTest
@testable import Earshot

/// Unit tests for the pure playback rules. No AVFoundation, no real files.
final class PlaybackLogicTests: XCTestCase {

    func testProjectedPositionFollowsForwardProgressWhilePaused() {
        XCTAssertEqual(
            PlaybackLogic.projectedPlaybackPosition(
                current: 274, projected: 379, isActivelyPlaying: false
            ),
            379
        )
    }

    func testProjectedPositionFollowsExplicitRewindWhilePaused() {
        XCTAssertEqual(
            PlaybackLogic.projectedPlaybackPosition(
                current: 379, projected: 80, isActivelyPlaying: false
            ),
            80
        )
    }

    func testProjectedPositionCannotMoveActivePlaybackBackward() {
        XCTAssertEqual(
            PlaybackLogic.projectedPlaybackPosition(
                current: 379, projected: 274, isActivelyPlaying: true
            ),
            379
        )
    }

    func testProjectedPositionCanAdvanceActivePlayback() {
        XCTAssertEqual(
            PlaybackLogic.projectedPlaybackPosition(
                current: 274, projected: 379, isActivelyPlaying: true
            ),
            379
        )
    }

    // MARK: Folder playback origin

    func testFolderStartSetsOrigin() {
        let folder = PodcastFolder(name: "News")
        let expected = PlaybackOrigin.folder(folder.persistentModelID)

        XCTAssertEqual(
            PlaybackLogic.playbackOrigin(after: .started(expected), current: nil),
            expected
        )
    }

    func testFolderOriginLabelUsesOneConciseFullPath() {
        XCTAssertEqual(
            PlaybackOriginLabel.playingFrom(folderPath: "News › Daily"),
            "Playing from News › Daily"
        )
    }

    func testStartingFromAnotherFolderReplacesOrigin() {
        let first = PlaybackOrigin.folder(PodcastFolder(name: "News").persistentModelID)
        let second = PlaybackOrigin.folder(PodcastFolder(name: "Comedy").persistentModelID)

        XCTAssertEqual(
            PlaybackLogic.playbackOrigin(after: .started(second), current: first),
            second
        )
    }

    func testOrdinaryManualStartClearsFolderOrigin() {
        let current = PlaybackOrigin.folder(PodcastFolder(name: "News").persistentModelID)

        XCTAssertNil(PlaybackLogic.playbackOrigin(after: .started(nil), current: current))
    }

    func testAdvanceWithinFolderSubtreeRetainsOrigin() {
        let current = PlaybackOrigin.folder(PodcastFolder(name: "News").persistentModelID)

        XCTAssertEqual(
            PlaybackLogic.playbackOrigin(
                after: .advanced(nextEpisodeBelongsToOrigin: true),
                current: current
            ),
            current
        )
    }

    func testAdvanceOutsideFolderSubtreeClearsOrigin() {
        let current = PlaybackOrigin.folder(PodcastFolder(name: "News").persistentModelID)

        XCTAssertNil(
            PlaybackLogic.playbackOrigin(
                after: .advanced(nextEpisodeBelongsToOrigin: false),
                current: current
            )
        )
    }

    func testContinuingCurrentEpisodeRetainsOrigin() {
        let current = PlaybackOrigin.folder(PodcastFolder(name: "News").persistentModelID)

        XCTAssertEqual(
            PlaybackLogic.playbackOrigin(after: .continuedCurrentEpisode, current: current),
            current
        )
    }

    func testStoppingClearsOrigin() {
        let current = PlaybackOrigin.folder(PodcastFolder(name: "News").persistentModelID)

        XCTAssertNil(PlaybackLogic.playbackOrigin(after: .stopped, current: current))
    }

    func testRelaunchRestoreDoesNotRestoreOrigin() {
        let stale = PlaybackOrigin.folder(PodcastFolder(name: "News").persistentModelID)

        XCTAssertNil(
            PlaybackLogic.playbackOrigin(after: .restoredAfterRelaunch, current: stale)
        )
    }

    func testDeletingActiveFolderClearsOrigin() {
        let activeFolder = PodcastFolder(name: "News")
        let current = PlaybackOrigin.folder(activeFolder.persistentModelID)

        XCTAssertNil(
            PlaybackLogic.playbackOrigin(
                after: .foldersDeleted([activeFolder.persistentModelID]),
                current: current
            )
        )
    }

    func testDeletingUnrelatedFolderRetainsOrigin() {
        let activeFolder = PodcastFolder(name: "News")
        let unrelatedFolder = PodcastFolder(name: "Comedy")
        let current = PlaybackOrigin.folder(activeFolder.persistentModelID)

        XCTAssertEqual(
            PlaybackLogic.playbackOrigin(
                after: .foldersDeleted([unrelatedFolder.persistentModelID]),
                current: current
            ),
            current
        )
    }

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

    // MARK: Playback start position

    func testSavedPositionResumesExactly() {
        XCTAssertEqual(PlaybackLogic.playbackStartPosition(position: 50, duration: 100), 50)
    }

    func testPositionAtNinetyFivePercentStillResumes() {
        XCTAssertEqual(
            PlaybackLogic.playbackStartPosition(position: 95, duration: 100),
            95,
            "Near-end progress must remain reachable so listeners can skip outro ads"
        )
    }

    func testPositionPastNinetyFivePercentStillResumes() {
        XCTAssertEqual(
            PlaybackLogic.playbackStartPosition(position: 99, duration: 100),
            99,
            "Only actual end-of-item or an explicit action marks an episode played"
        )
    }

    func testUnknownDurationResumesAtSavedPosition() {
        XCTAssertEqual(PlaybackLogic.playbackStartPosition(position: 500, duration: nil), 500)
    }

    func testZeroDurationResumesAtSavedPosition() {
        XCTAssertEqual(PlaybackLogic.playbackStartPosition(position: 10, duration: 0), 10)
    }

    func testNegativePositionClampsToZero() {
        XCTAssertEqual(PlaybackLogic.playbackStartPosition(position: -5, duration: 100), 0)
    }

    // MARK: Intro skip (#456)

    func testFreshStart_withIntroSkip_resumesPastIntro() {
        let position = PlaybackLogic.playbackStartPosition(
            position: 0, duration: 1800, introSkipSeconds: 45
        )
        XCTAssertEqual(position, 45)
    }

    func testFreshStart_noIntroSkip_resumesAtZero() {
        let position = PlaybackLogic.playbackStartPosition(
            position: 0, duration: 1800, introSkipSeconds: nil
        )
        XCTAssertEqual(position, 0)
    }

    func testFreshStart_zeroIntroSkip_resumesAtZero() {
        let position = PlaybackLogic.playbackStartPosition(
            position: 0, duration: 1800, introSkipSeconds: 0
        )
        XCTAssertEqual(position, 0)
    }

    func testAlreadyInProgress_introSkipDoesNotReapply() {
        let position = PlaybackLogic.playbackStartPosition(
            position: 200, duration: 1800, introSkipSeconds: 45
        )
        XCTAssertEqual(position, 200)
    }

    func testIntroSkip_clampedToLeavePlayableTail() {
        let position = PlaybackLogic.playbackStartPosition(
            position: 0, duration: 30, introSkipSeconds: 999
        )
        XCTAssertEqual(position, 28, "An oversized intro skip must leave two playable seconds")
    }

    func testIntroSkip_unknownDuration_appliesAsIs() {
        let position = PlaybackLogic.playbackStartPosition(
            position: 0, duration: nil, introSkipSeconds: 45
        )
        XCTAssertEqual(position, 45)
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

    // MARK: Post-played stale-tick guard (#653)

    func testDoesNotPersistStaleTickAfterEpisodeMarkedPlayed() {
        // Reproduces the race: `markCurrentEpisodePlayed()` zeros the position
        // but never resets `lastPersistedSecond`, so a later tick still satisfies
        // the plain interval-elapsed condition below. Once `isPlayed` is true the
        // tick must be refused outright so it can't clobber the zeroed position
        // with this stale, still-climbing `currentSecond`.
        XCTAssertTrue(
            PlaybackLogic.shouldPersistTick(currentSecond: 300, lastPersistedSecond: 200),
            "sanity check: without the isPlayed guard this tick would persist"
        )
        XCTAssertFalse(
            PlaybackLogic.shouldPersistTick(currentSecond: 300, lastPersistedSecond: 200, isPlayed: true)
        )
    }

    func testDoesNotPersistFirstTickWhenAlreadyPlayed() {
        // Even the "no prior write" case (normally always persists) must be
        // refused once played — there's nothing left to persist for it.
        XCTAssertFalse(
            PlaybackLogic.shouldPersistTick(currentSecond: 0, lastPersistedSecond: nil, isPlayed: true)
        )
    }

    func testDoesNotPersistBackwardJumpWhenAlreadyPlayed() {
        // A backward jump normally forces an immediate persist; isPlayed still
        // wins because a played episode has no meaningful position to save.
        XCTAssertFalse(
            PlaybackLogic.shouldPersistTick(currentSecond: 10, lastPersistedSecond: 40, isPlayed: true)
        )
    }

    func testUnplayedTicksUnaffectedByIsPlayedGuard() {
        // Existing non-played behavior is unchanged, whether isPlayed is passed
        // explicitly as false or omitted (default).
        XCTAssertTrue(PlaybackLogic.shouldPersistTick(currentSecond: 0, lastPersistedSecond: nil, isPlayed: false))
        XCTAssertFalse(PlaybackLogic.shouldPersistTick(currentSecond: 3, lastPersistedSecond: 0, isPlayed: false))
        XCTAssertTrue(PlaybackLogic.shouldPersistTick(currentSecond: 5, lastPersistedSecond: 0, isPlayed: false))
    }

    func testDefaultIntervalIsCoarserThanOneSecond() {
        // Guards against regressing back to a per-second save.
        XCTAssertGreaterThan(PlaybackLogic.positionPersistInterval, 1)
    }

    func testMediaIntervalScalesWithAcceleratedPlayback() {
        XCTAssertEqual(PlaybackLogic.mediaSeconds(forWallClockSeconds: 1, playbackRate: 1), 1)
        XCTAssertEqual(PlaybackLogic.mediaSeconds(forWallClockSeconds: 1, playbackRate: 1.5), 1.5)
        XCTAssertEqual(PlaybackLogic.mediaSeconds(forWallClockSeconds: 1, playbackRate: 2), 2)
        XCTAssertEqual(PlaybackLogic.mediaSeconds(forWallClockSeconds: 5, playbackRate: 2), 10)
    }

    func testMediaIntervalDoesNotAccelerateAtSlowOrInvalidRates() {
        XCTAssertEqual(PlaybackLogic.mediaSeconds(forWallClockSeconds: 1, playbackRate: 0.5), 1)
        XCTAssertEqual(PlaybackLogic.mediaSeconds(forWallClockSeconds: 1, playbackRate: .nan), 1)
        XCTAssertEqual(PlaybackLogic.mediaSeconds(forWallClockSeconds: 0, playbackRate: 2), 2)
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
        XCTAssertTrue(PlaybackLogic.shouldSyncNowPlayingElapsed(currentSecond: 15, lastSyncedSecond: 0))
        XCTAssertTrue(PlaybackLogic.shouldSyncNowPlayingElapsed(currentSecond: 65, lastSyncedSecond: 50))
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

    func testNowPlayingSyncUsesFifteenSecondWallClockBaseline() {
        XCTAssertEqual(PlaybackLogic.nowPlayingElapsedSyncInterval, 15)
        let intervalAt2x = Int(PlaybackLogic.mediaSeconds(
            forWallClockSeconds: Double(PlaybackLogic.nowPlayingElapsedSyncInterval),
            playbackRate: 2
        ))
        XCTAssertFalse(PlaybackLogic.shouldSyncNowPlayingElapsed(
            currentSecond: 29,
            lastSyncedSecond: 0,
            interval: intervalAt2x
        ))
        XCTAssertTrue(PlaybackLogic.shouldSyncNowPlayingElapsed(
            currentSecond: 30,
            lastSyncedSecond: 0,
            interval: intervalAt2x
        ))
    }

    // MARK: Up-next resolution (gapless advance)

    func testNextUpIsFirstQueueItemAfterCurrent() {
        XCTAssertEqual(PlaybackLogic.nextUpID(queue: [1, 2, 3], after: 1), 2)
    }

    func testNextUpIsThePositionalSuccessorWhenCurrentSitsMidQueue() {
        // #627: the finished episode (1) sits at index 1, not the head -- "next"
        // must be the item positionally AFTER it (3), not the queue's head (2).
        // Playing an episode that isn't at the top (leaving earlier items
        // untouched) must continue from where the listener actually was.
        XCTAssertEqual(PlaybackLogic.nextUpID(queue: [2, 1, 3], after: 1), 3)
    }

    func testNextUpFallsBackToHeadWhenCurrentNotInQueueAtAll() {
        // No position to reference -- fall back to the head, same as auto-advance
        // for content that was never queued in the first place.
        XCTAssertEqual(PlaybackLogic.nextUpID(queue: [2, 3], after: 99), 2)
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
        // #627: the finished episode (id 1) is not at the head -- "next" is the
        // item positionally AFTER it in the queue (id 3, group "B"), not the
        // queue's head (id 2). Group-off must still advance since this is the
        // real next item, regardless of what group it belongs to.
        XCTAssertEqual(PlaybackLogic.nextUpHonoringBoundaries(
            queue: [(id: 2, groupKey: "A"), (id: 1, groupKey: "A"), (id: 3, groupKey: "B")],
            after: 1,
            currentGroupKey: "A",
            continueAfterEpisode: true,
            continueAfterGroupEnds: true
        ), 3)
    }

    func testBoundaryGroupOffStopsAtDifferentGroupWhenCurrentSitsMidQueue() {
        // Same layout, but group-continuation off: the positional successor (id
        // 3) is a different group ("B") than the finished episode's group ("A"),
        // so this must stop at the boundary -- not silently advance to the head
        // (id 2, same group) the way the old "first that isn't current" logic did.
        XCTAssertNil(PlaybackLogic.nextUpHonoringBoundaries(
            queue: [(id: 2, groupKey: "A"), (id: 1, groupKey: "A"), (id: 3, groupKey: "B")],
            after: 1,
            currentGroupKey: "A",
            continueAfterEpisode: true,
            continueAfterGroupEnds: false
        ))
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

    // MARK: continueAfterGroupEnds override (#487 — explicit Play next)

    func testGroupEndSettingOnPassesThroughRegardlessOfOverrides() {
        // Setting already on: result is on, overrides irrelevant.
        XCTAssertTrue(PlaybackLogic.continueAfterGroupEnds(
            setting: true, nextCandidate: 3, playNextOverrides: []
        ))
    }

    func testGroupEndSettingOffStaysOffWhenNextNotPlayNexted() {
        // Setting off and the next item wasn't Play-next-ed: stays off (stop).
        XCTAssertFalse(PlaybackLogic.continueAfterGroupEnds(
            setting: false, nextCandidate: 3, playNextOverrides: [9]
        ))
    }

    func testGroupEndSettingOffBypassedWhenNextWasPlayNexted() {
        // Setting off but the immediate next item was explicitly Play-next-ed:
        // its explicit intent wins, so the group boundary is bypassed.
        XCTAssertTrue(PlaybackLogic.continueAfterGroupEnds(
            setting: false, nextCandidate: 3, playNextOverrides: [3]
        ))
    }

    func testGroupEndSettingOffStaysOffWhenNoNextCandidate() {
        XCTAssertFalse(PlaybackLogic.continueAfterGroupEnds(
            setting: false, nextCandidate: Int?.none, playNextOverrides: [3]
        ))
    }

    // MARK: Scrubber VoiceOver step (#610)

    func testScrubberStepIsFlatThirtySecondsAtOrUnderThirtyMinutes() {
        // Preserves Flutter-parity granularity for typical episode lengths.
        XCTAssertEqual(PlaybackLogic.scrubberStepSeconds(duration: 60), 30)
        XCTAssertEqual(PlaybackLogic.scrubberStepSeconds(duration: 600), 30)
        XCTAssertEqual(PlaybackLogic.scrubberStepSeconds(duration: 1800), 30, accuracy: 0.001)
    }

    func testScrubberStepScalesUpForLongerEpisodes() {
        // 1 hour: 3600s / 60 flicks = 60s/flick.
        XCTAssertEqual(PlaybackLogic.scrubberStepSeconds(duration: 3600), 60, accuracy: 0.001)
        // 2 hours: 7200s / 60 flicks = 120s/flick.
        XCTAssertEqual(PlaybackLogic.scrubberStepSeconds(duration: 7200), 120, accuracy: 0.001)
    }

    func testScrubberStepClampsAtFiveMinutesForVeryLongEpisodes() {
        // Well past the 5-hour breakeven point, the step must not keep growing.
        XCTAssertEqual(PlaybackLogic.scrubberStepSeconds(duration: 36000), 300, accuracy: 0.001)
        XCTAssertEqual(PlaybackLogic.scrubberStepSeconds(duration: 100_000), 300, accuracy: 0.001)
    }

    func testScrubberStepFallsBackToFlatStepForUnknownDuration() {
        XCTAssertEqual(PlaybackLogic.scrubberStepSeconds(duration: 0), 30)
        XCTAssertEqual(PlaybackLogic.scrubberStepSeconds(duration: -1), 30)
    }

    func testScrubberStepNeverExceedsSixtyFlicksWithinTheClampedRange() {
        // Regression guard on the original bug: below the 5-hour breakeven point
        // (maxScrubberStepSeconds * targetScrubberFlicks), the target formula alone
        // governs and no episode should require more than roughly 60 flicks (plus
        // rounding slack) to cross start-to-end.
        for duration in [600.0, 1800.0, 3600.0, 7200.0, 14400.0] {
            let step = PlaybackLogic.scrubberStepSeconds(duration: duration)
            let flicksNeeded = duration / step
            XCTAssertLessThanOrEqual(flicksNeeded, 61,
                "\(duration)s episode needs \(flicksNeeded) flicks, expected <= ~60")
        }
    }

    func testScrubberStepPerFlickNeverExceedsCapEvenForVeryLongEpisodes() {
        // Beyond the 5-hour breakeven, the step clamp intentionally takes priority
        // over the flick-count target: flick count can exceed 60 for such rare,
        // very long content, but no single flick may ever jump more than
        // maxScrubberStepSeconds -- an unbounded per-flick jump (which the raw
        // duration/60 formula would produce) would be a worse regression than
        // needing extra flicks to cross a multi-hour episode.
        for duration in [36000.0, 100_000.0, 500_000.0] {
            XCTAssertLessThanOrEqual(
                PlaybackLogic.scrubberStepSeconds(duration: duration),
                PlaybackLogic.maxScrubberStepSeconds
            )
        }
    }

    // MARK: Remote toggle action (Bluetooth pause fix)

    func testTogglePausesWhenActivelyPlaying() {
        XCTAssertEqual(
            PlaybackLogic.remoteToggleAction(intendsToPlay: true, playerIsPlaying: true),
            .pause
        )
    }

    func testToggleResumesWhenGenuinelyStopped() {
        XCTAssertEqual(
            PlaybackLogic.remoteToggleAction(intendsToPlay: false, playerIsPlaying: false),
            .resume
        )
    }

    func testTogglePausesFromIntentEvenWhenPlayerFlagIsStaleFalse() {
        // The Shokz two-press / Bose "pause does nothing" case: audio is intended
        // (and rendering) but the live transport flag reads false, e.g. still in
        // .waitingToPlayAtSpecifiedRate. A single press must still pause.
        XCTAssertEqual(
            PlaybackLogic.remoteToggleAction(intendsToPlay: true, playerIsPlaying: false),
            .pause
        )
    }

    func testTogglePausesWhenPlayingEvenIfIntentFlagLags() {
        // Defensive symmetry: if the player is demonstrably playing, pause,
        // regardless of the intent flag.
        XCTAssertEqual(
            PlaybackLogic.remoteToggleAction(intendsToPlay: false, playerIsPlaying: true),
            .pause
        )
    }

    // MARK: Now-playing reported rate (Bluetooth pause fix)

    func testNowPlayingRateIsZeroWhenNotIntendingPlayback() {
        XCTAssertEqual(
            PlaybackLogic.nowPlayingRate(
                intendsToPlay: false,
                effectiveRate: 1.5,
                isFastForwarding: false,
                fastForwardRate: 4.0
            ),
            0
        )
    }

    func testNowPlayingRateReportsEffectiveRateWhilePlaying() {
        // Reports the INTENDED rate even mid-buffer (when live player.rate is 0),
        // so accessories mirroring system play state don't believe we're paused.
        XCTAssertEqual(
            PlaybackLogic.nowPlayingRate(
                intendsToPlay: true,
                effectiveRate: 1.5,
                isFastForwarding: false,
                fastForwardRate: 4.0
            ),
            1.5
        )
    }

    func testNowPlayingRateReportsFastForwardScanRate() {
        XCTAssertEqual(
            PlaybackLogic.nowPlayingRate(
                intendsToPlay: true,
                effectiveRate: 1.5,
                isFastForwarding: true,
                fastForwardRate: 4.0
            ),
            4.0
        )
    }

    func testNowPlayingRateStaysZeroWhenPausedDuringFastForwardFlag() {
        // Intent gate wins: a stale fast-forward flag can't report motion once the
        // user has paused.
        XCTAssertEqual(
            PlaybackLogic.nowPlayingRate(
                intendsToPlay: false,
                effectiveRate: 1.5,
                isFastForwarding: true,
                fastForwardRate: 4.0
            ),
            0
        )
    }

    // MARK: isPlaying sync on timeControlStatus transition (stall-recovery drift)

    func testMarksPlayingWhenPlayerReachesPlayingWhileFlagIsStale() {
        // Stall recovery re-issues play() without setting isPlaying; the transition
        // to .playing while the user still intends playback must flip the flag.
        XCTAssertTrue(
            PlaybackLogic.shouldMarkPlayingOnTransition(
                playerIsPlaying: true,
                intendsToPlay: true,
                currentlyMarkedPlaying: false
            )
        )
    }

    func testDoesNotReMarkPlayingWhenFlagAlreadyTrue() {
        // Avoids a redundant now-playing rewrite when nothing changed.
        XCTAssertFalse(
            PlaybackLogic.shouldMarkPlayingOnTransition(
                playerIsPlaying: true,
                intendsToPlay: true,
                currentlyMarkedPlaying: true
            )
        )
    }

    func testDoesNotMarkPlayingOnPostPausePlayingBlipWithoutIntent() {
        // A momentary .playing report after the user paused must not revive the UI.
        XCTAssertFalse(
            PlaybackLogic.shouldMarkPlayingOnTransition(
                playerIsPlaying: true,
                intendsToPlay: false,
                currentlyMarkedPlaying: false
            )
        )
    }

    func testDoesNotMarkPlayingWhenPlayerNotYetPlaying() {
        // Still buffering (.waitingToPlayAtSpecifiedRate): don't claim .playing.
        XCTAssertFalse(
            PlaybackLogic.shouldMarkPlayingOnTransition(
                playerIsPlaying: false,
                intendsToPlay: true,
                currentlyMarkedPlaying: false
            )
        )
    }
}
