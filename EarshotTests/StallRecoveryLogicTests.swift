import XCTest
import AVFoundation
@testable import Earshot

/// Tests the pure stall-recovery decision (#522) across the cases that matter:
/// a real stall the user wants recovered, a deliberate pause that must stay
/// paused, a buffer that hasn't recovered yet, and normal playback.
final class StallRecoveryLogicTests: XCTestCase {

    // Stalled (player settled into .paused), user wants playback, and the buffer
    // has recovered -> re-issue play().
    func testStalledIntendedAndLikelyToKeepUpResumes() {
        XCTAssertTrue(StallRecoveryLogic.shouldResume(
            intendedToPlay: true,
            isLikelyToKeepUp: true,
            timeControlStatus: .paused
        ))
    }

    // The user deliberately paused (intent is false) -> never auto-resume, even
    // once the buffer is healthy.
    func testUserPausedDoesNotResume() {
        XCTAssertFalse(StallRecoveryLogic.shouldResume(
            intendedToPlay: false,
            isLikelyToKeepUp: true,
            timeControlStatus: .paused
        ))
    }

    // Buffer emptied and hasn't refilled yet -> wait, don't hammer play().
    func testBufferNotYetLikelyToKeepUpWaits() {
        XCTAssertFalse(StallRecoveryLogic.shouldResume(
            intendedToPlay: true,
            isLikelyToKeepUp: false,
            timeControlStatus: .paused
        ))
    }

    // Already playing normally -> no-op (nothing to recover).
    func testAlreadyPlayingIsNoOp() {
        XCTAssertFalse(StallRecoveryLogic.shouldResume(
            intendedToPlay: true,
            isLikelyToKeepUp: true,
            timeControlStatus: .playing
        ))
    }

    // AVPlayer is already waiting to resume on its own -> don't pile on a
    // redundant play() while it recovers.
    func testWaitingToPlayIsLeftToAVPlayer() {
        XCTAssertFalse(StallRecoveryLogic.shouldResume(
            intendedToPlay: true,
            isLikelyToKeepUp: true,
            timeControlStatus: .waitingToPlayAtSpecifiedRate
        ))
    }

    // Defensive: no intent + still buffering + paused -> false.
    func testNoIntentAndNotLikelyDoesNotResume() {
        XCTAssertFalse(StallRecoveryLogic.shouldResume(
            intendedToPlay: false,
            isLikelyToKeepUp: false,
            timeControlStatus: .paused
        ))
    }
}
