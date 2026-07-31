import Foundation

/// Pure decision logic for MANUAL previous/next chapter navigation (#508).
///
/// Unlike ``ChapterSkipLogic`` (which honours the per-episode skipped set and
/// fires automatically), this is the user explicitly tapping Previous / Next
/// chapter: it always moves to the chapter adjacent by index, ignoring the skip
/// set. Kept free of `AVPlayer`, settings, and SwiftData so every boundary can
/// be unit-tested: before the first chapter, past the last chapter, the
/// previous-restart threshold, and the no-chapters case.
///
/// Returns a target chapter *index*; the caller maps that to a start time via
/// its loaded chapter list and seeks there.
enum ChapterNavLogic {

    /// How far (seconds) into the current chapter "Previous" restarts the current
    /// chapter rather than stepping to the prior one — the common podcast-player
    /// convention.
    static let previousRestartThreshold: Double = 3.0

    /// Target chapter index for "Next chapter", or `nil` for a no-op.
    ///
    /// - `nil` count: no chapters -> `nil`.
    /// - `nil` currentIndex (position before the first chapter starts): the first
    ///   chapter (index 0).
    /// - Otherwise the chapter after the active one, or `nil` when already in the
    ///   last chapter (clamped at the end).
    static func nextIndex(currentIndex: Int?, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let currentIndex else { return 0 }
        let next = currentIndex + 1
        guard next < count else { return nil }
        return next
    }

    /// Target chapter index for "Previous chapter", or `nil` for a no-op.
    ///
    /// - `nil` count: no chapters -> `nil`.
    /// - `nil` currentIndex (position before the first chapter starts): the first
    ///   chapter (index 0).
    /// - More than `threshold` seconds into the current chapter: restart the
    ///   current chapter (returns `currentIndex`).
    /// - Within `threshold`: the previous chapter, clamped so the first chapter
    ///   restarts itself (returns 0) rather than underflowing.
    static func previousIndex(
        currentIndex: Int?,
        count: Int,
        positionWithinChapter: Double,
        threshold: Double = previousRestartThreshold
    ) -> Int? {
        guard count > 0 else { return nil }
        guard let currentIndex else { return 0 }
        if positionWithinChapter > threshold { return currentIndex }
        let previous = currentIndex - 1
        return previous >= 0 ? previous : 0
    }

    /// Whether the visible Previous/Next chapter buttons that flank the chapter
    /// name in the player should be shown (#515).
    ///
    /// Shown only when the episode actually has chapters AND the user hasn't
    /// turned the buttons off in Settings. Hiding them never removes chapter
    /// navigation: the chapter-name button and the artwork VoiceOver rotor keep
    /// their own Previous/Next actions regardless of this setting.
    static func shouldShowNavButtons(chapterCount: Int, settingEnabled: Bool) -> Bool {
        chapterCount > 0 && settingEnabled
    }
}
