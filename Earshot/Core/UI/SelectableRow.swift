import SwiftUI

/// A list row rendered in selection mode: a leading checkmark plus the caller's
/// visual content, as one VoiceOver element that toggles selection on activation
/// (folders phase 2, #757). Reusable for any multi-select list — the podcast
/// lists here and episode lists in #758 supply their own `label` and spoken
/// name.
///
/// A screen swaps its normal `NavigationLink` row for this while
/// ``MultiSelectState/isSelecting`` is on, so tapping selects instead of
/// navigating. Selection is conveyed three ways, never by color alone: a filled
/// vs. empty circle **glyph**, the `.isSelected` **trait** VoiceOver speaks, and
/// the accent **color** — satisfying the "icon + label + color" rule.
struct SelectableRow<Label: View>: View {
    /// Whether this row is currently selected.
    let isSelected: Bool
    /// The row's spoken name (e.g. the podcast title and author). "Selected" is
    /// NOT appended here — the `.isSelected` trait below conveys it, so the word
    /// is never duplicated.
    let accessibilityLabel: String
    var accessibilityValue: String? = nil
    /// Toggles this row's membership in the selection.
    let onToggle: () -> Void
    /// The row's visual content, reused unchanged from the non-selecting row.
    @ViewBuilder var label: () -> Label

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: Spacing.md) {
                // Icon shape (filled vs. hollow) carries the state independently of
                // color; hidden from VoiceOver because the `.isSelected` trait
                // below is the spoken signal.
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .imageScale(.large)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .accessibilityHidden(true)
                label()
                Spacer(minLength: 0)
            }
            // ≥44pt target across every Dynamic Type size; the full row width is
            // tappable, not just the checkmark + content's intrinsic width.
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // One coherent element: the explicit label is the whole name, so the
        // decorative child text isn't read twice, and the row carries the
        // selection trait rather than fragmenting into checkmark + title.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .modifier(OptionalSpokenValue(value: accessibilityValue))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(isSelected ? "Double tap to deselect" : "Double tap to select")
    }
}

struct OptionalSpokenValue: ViewModifier {
    let value: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let value, !value.isEmpty { content.accessibilityValue(value) } else { content }
    }
}
