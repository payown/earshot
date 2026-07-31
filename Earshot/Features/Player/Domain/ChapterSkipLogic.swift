import Foundation

/// Pure decision logic for chapter auto-skip and the hold-to-fast-forward scan.
///
/// Kept free of `AVPlayer`, settings, and SwiftData so every boundary can be
/// unit-tested: last chapter skipped, all skipped, consecutive skipped runs,
/// no chapters, and the loop-guard that stops the same boundary re-triggering.
///
/// Mirrors the Flutter behaviour in `chapter_providers.dart`
/// (`SkippedChaptersNotifier` + `_lastAutoSkipFromChapterIndex`) and the
/// `_startVoFastForward` / `_stopVoFastForward` rate swap in `player_screen.dart`.
enum ChapterSkipLogic {

    /// The scan rate applied while the user holds fast-forward.
    static let fastForwardRate: Double = 4.0

    /// The outcome of evaluating an auto-skip at the current position.
    enum SkipDecision: Equatable {
        /// Stay put — the active chapter is not skipped (or there's nothing to do).
        case none
        /// Seek to the start of the chapter at `targetIndex`, whose title is
        /// `targetTitle` (for the announcement).
        case seek(targetIndex: Int, startTime: Double, targetTitle: String)
        /// Every remaining chapter from the active one onward is skipped; there's
        /// no non-skipped chapter to land on, so playback should end / advance.
        case endOfEpisode
    }

    /// Given the chapter list, the set of skipped indices, and the active chapter
    /// index, decide what (if anything) to do.
    ///
    /// - Returns `.none` when the active chapter isn't skipped, when there are no
    ///   chapters, or when the position is before the first chapter starts.
    /// - Returns `.seek` to the first non-skipped chapter at or after the active
    ///   one (skipping over consecutive skipped chapters).
    /// - Returns `.endOfEpisode` when the active chapter and all chapters after it
    ///   are skipped.
    static func decision(
        chapters: [Chapter],
        skipped: Set<Int>,
        activeIndex: Int?
    ) -> SkipDecision {
        guard let activeIndex,
              chapters.indices.contains(activeIndex),
              skipped.contains(activeIndex) else {
            return .none
        }

        // Walk forward to the first chapter not in the skipped set.
        var next = activeIndex + 1
        while chapters.indices.contains(next), skipped.contains(next) {
            next += 1
        }

        guard chapters.indices.contains(next) else {
            return .endOfEpisode
        }

        let target = chapters[next]
        return .seek(targetIndex: next, startTime: target.startTime, targetTitle: target.title)
    }

    /// Whether an auto-skip should fire for this tick. The loop guard records the
    /// chapter index we last auto-skipped *from*; we only fire again once the
    /// active chapter has changed away from that index. This prevents the seek's
    /// own position update (which can momentarily report the same chapter again)
    /// from re-triggering an endless skip loop.
    static func shouldAutoSkip(
        activeIndex: Int?,
        skipped: Set<Int>,
        lastAutoSkipFromIndex: Int?
    ) -> Bool {
        guard let activeIndex, skipped.contains(activeIndex) else { return false }
        return activeIndex != lastAutoSkipFromIndex
    }
}
