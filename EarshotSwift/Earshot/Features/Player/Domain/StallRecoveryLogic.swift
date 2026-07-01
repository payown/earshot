import AVFoundation

/// Pure decision for streaming stall recovery (#522). Factored out of
/// ``PlayerService`` so the "should we re-issue `play()`?" rule is unit-tested
/// without a live `AVPlayer`, a network, or real rebuffering.
///
/// Background: when a streamed item's buffer empties, `AVPlayer` stops feeding
/// audio. With `automaticallyWaitsToMinimizeStalling` it usually resumes itself
/// (the player sits in `.waitingToPlayAtSpecifiedRate` and recovers when the
/// buffer refills). But when the player settles into `.paused` after a stall and
/// nothing re-issues `play()`, the user is stuck — they have to manually resume.
/// This logic decides exactly when an observer should call `play()` again.
enum StallRecoveryLogic {

    /// Whether the engine should re-issue `play()` to recover from a stall.
    ///
    /// Returns `true` only when ALL of the following hold:
    /// - the user actually intends playback (so a deliberate pause is never
    ///   overridden),
    /// - the player has settled into `.paused` (not `.playing`, and not
    ///   `.waitingToPlayAtSpecifiedRate` — in the waiting case `AVPlayer` resumes
    ///   on its own, so re-issuing `play()` would be redundant churn), and
    /// - the buffer can sustain playback again (`isLikelyToKeepUp`), so we don't
    ///   hammer `play()` into an empty buffer and thrash the radio.
    ///
    /// Because the gate requires `.paused`, a single recovery flips the player to
    /// `.playing`/`.waiting`, and further observer callbacks no-op — there is no
    /// busy-loop.
    ///
    /// - Parameters:
    ///   - intendedToPlay: The user's intent — `true` after play/resume, `false`
    ///     after a deliberate or interruption pause.
    ///   - isLikelyToKeepUp: The current item's `isPlaybackLikelyToKeepUp`.
    ///   - timeControlStatus: The player's current `timeControlStatus`.
    static func shouldResume(
        intendedToPlay: Bool,
        isLikelyToKeepUp: Bool,
        timeControlStatus: AVPlayer.TimeControlStatus
    ) -> Bool {
        guard intendedToPlay else { return false }
        guard timeControlStatus == .paused else { return false }
        return isLikelyToKeepUp
    }
}
