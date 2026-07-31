import Foundation

/// Pure index-stepping for VoiceOver-adjustable option pickers
/// (``AdjustableOptionPicker``). Clamped at both ends — no wraparound — so a
/// flick past the first or last option is a no-op the caller detects (the
/// returned index equals `current`) and skips, avoiding a phantom value write
/// and a doubled VoiceOver announcement.
enum OptionStepLogic {
    /// The next index after a VoiceOver adjust step. `delta` is `+1` for an
    /// increment (flick up) and `-1` for a decrement (flick down). The result is
    /// clamped into `0..<count`; at a boundary it returns the clamped `current`
    /// unchanged. An out-of-range `current` is clamped into range first.
    static func steppedIndex(count: Int, current: Int, delta: Int) -> Int {
        guard count > 0 else { return 0 }
        let safeCurrent = min(max(current, 0), count - 1)
        return min(max(safeCurrent + delta, 0), count - 1)
    }
}
