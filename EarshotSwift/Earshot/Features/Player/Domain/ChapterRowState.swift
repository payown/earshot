import Foundation

/// Pure presentation mapper for a single row in the chapter list (#509). Turns
/// the (now-playing / included / skipped) state of a chapter into the strings
/// and SF Symbols the row renders, so the mapping is unit-testable without a
/// live `PlayerService`.
///
/// Model: every chapter is "included" (plays) by default. Deselecting a chapter
/// marks it skipped, driving the existing in-memory skip engine (#373). The
/// checkmark therefore reads as "selected, deselect to skip", not "skip toggle".
struct ChapterRowState: Equatable {
    /// The chapter the playhead is currently inside.
    let isCurrent: Bool
    /// The chapter is deselected and will be auto-skipped during playback.
    let isSkipped: Bool

    /// Leading now-playing marker. A filled play badge while current, a hollow
    /// dot otherwise. Paired with the position number for sighted users; the
    /// state is also carried in words by ``accessibilityLabel`` so it is never
    /// color-only.
    var markerSystemImage: String {
        isCurrent ? "play.circle.fill" : "circle"
    }

    /// Trailing included/skipped indicator for sighted users. A filled checkmark
    /// when included (the default), a slashed circle when skipped. This control
    /// is `accessibilityHidden` in the row so it adds no second VoiceOver stop;
    /// VoiceOver toggles via the row's rotor action instead.
    var indicatorSystemImage: String {
        isSkipped ? "circle.slash" : "checkmark.circle.fill"
    }

    /// Word shown beneath the title so the row's state is not signalled by the
    /// trailing icon (color) alone. "Skipped" wins over "Now playing" when both
    /// are true — a deselected current chapter is about to be jumped over.
    var statusWord: String? {
        if isSkipped { return "Skipped" }
        if isCurrent { return "Now playing" }
        return nil
    }

    /// VoiceOver rotor action name; reflects the current state so activating it
    /// reads as the action it performs.
    var toggleActionName: String {
        isSkipped ? "Include this chapter" : "Skip this chapter"
    }

    /// One combined VoiceOver label for the row: position, title, start time,
    /// and the state as words. Title leads so it is never buried. Never empty
    /// (an empty accessibility value registers as a VoiceOver pause).
    func accessibilityLabel(number: Int, title: String, spokenTime: String) -> String {
        var parts = ["\(number). \(title)", spokenTime]
        if isCurrent { parts.append("now playing") }
        if isSkipped { parts.append("skipped") }
        return parts.joined(separator: ", ")
    }
}
