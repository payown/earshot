import SwiftUI

/// A single-value picker that is a native `.menu` `Picker` for sighted and
/// low-vision (non-VoiceOver) users — tap to open the full option list — and a
/// single VoiceOver **Adjustable** element for VoiceOver users: flick up to move
/// to the next option, flick down to the previous one, with the new value spoken
/// automatically.
///
/// Supply `options` in the order they should step (typically ascending, so a
/// flick up means "more"). The control mirrors the player scrubber's
/// `.accessibilityRepresentation` + `.accessibilityAdjustableAction` idiom
/// (see `NowPlayingScreen`): the visual `Picker` keeps its tap/menu behaviour
/// because the representation rewrites only the accessibility subtree.
///
/// VoiceOver re-reads `accessibilityValue` after every adjust, so this view never
/// calls `Announcer` itself. Callers must NOT add their own announcement for the
/// same value change, or it is spoken twice.
struct AdjustableOptionPicker<Value: Hashable>: View {

    /// One selectable option. `title` is the visible menu label (e.g. "1.5×");
    /// `spoken` is the VoiceOver value (e.g. "1.5 times", "no limit").
    struct Option {
        let value: Value
        let title: String
        let spoken: String

        init(value: Value, title: String, spoken: String) {
            self.value = value
            self.title = title
            self.spoken = spoken
        }
    }

    private let label: String
    private let options: [Option]
    @Binding private var selection: Value
    private let hint: String?

    init(_ label: String, options: [Option], selection: Binding<Value>, hint: String? = nil) {
        self.label = label
        self.options = options
        self._selection = selection
        self.hint = hint
    }

    var body: some View {
        Picker(label, selection: $selection) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Text(option.title).tag(option.value)
            }
        }
        .pickerStyle(.menu)
        .accessibilityRepresentation { adjustableElement }
    }

    /// Index of the currently-selected option, or 0 when the bound value isn't in
    /// the list (e.g. an off-grid stored value the caller maps in via a binding).
    private var currentIndex: Int {
        options.firstIndex { $0.value == selection } ?? 0
    }

    private var adjustableElement: some View {
        Color.clear
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue(options.isEmpty ? "" : options[currentIndex].spoken)
            .accessibilityHint(hint ?? "")
            // Attaching the adjustable action is what makes VoiceOver treat this
            // as an adjustable control (flick up/down) — there is no `.isAdjustable`
            // trait to add directly.
            .accessibilityAdjustableAction { direction in
                let delta: Int
                switch direction {
                case .increment: delta = 1
                case .decrement: delta = -1
                @unknown default: return
                }
                let next = OptionStepLogic.steppedIndex(
                    count: options.count, current: currentIndex, delta: delta
                )
                // No-op at a boundary: don't write the binding (avoids a phantom
                // change); VoiceOver still re-speaks the current value as feedback.
                guard next != currentIndex else { return }
                selection = options[next].value
            }
    }
}
