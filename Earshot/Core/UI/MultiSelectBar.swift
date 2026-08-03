import SwiftUI

/// One batch action in a ``MultiSelectBar`` — a resolved title (the caller
/// interpolates the live count), a leading SF Symbol, whether it's destructive,
/// and its handler. Generic on purpose: podcast multi-select (#757) supplies
/// Add / Move / Remove-to-folder, and episode multi-select (#758) can supply its
/// own set unchanged.
struct MultiSelectAction: Identifiable {
    /// A STABLE identity for the button (e.g. "move", "remove") — deliberately
    /// NOT the count-carrying `title`, so the bar's `ForEach` keeps each button's
    /// identity as the live count changes and never tears down / rebuilds them on
    /// every selection tap.
    let id: String
    /// The button's fully-resolved name, carrying the live count
    /// ("Add 3 podcasts to folder"). This label is the accessibility source of
    /// truth for the count.
    let title: String
    /// A leading icon shown on every action — required for destructive actions
    /// so their nature isn't signalled by color alone, and used for all so the
    /// bar reads consistently.
    let systemImage: String
    /// Destructive actions (e.g. Remove from folder) tint red and carry the
    /// `.isButton` + destructive affordance; the leading icon is mandatory.
    var isDestructive: Bool = false
    let handler: () -> Void
}

/// A persistent bottom action bar shown while a list is in selection mode
/// (folders phase 2, #757). The primary button's label carries the live
/// selection count and its action ("Add 3 podcasts to folder"); secondary
/// actions follow. Entirely generic — the owning screen supplies the resolved
/// titles and handlers — so episode multi-select (#758) drops it in unchanged.
///
/// Laid out as a vertical stack of full-width buttons so it reflows cleanly at
/// the largest Dynamic Type sizes without clipping and every button keeps a
/// ≥44pt target. When nothing is selected the actions are disabled (and say so),
/// but their names still read cleanly.
struct MultiSelectBar: View {
    /// The live selection count — the value the caller has already interpolated
    /// into `primary.title`. Drives the disabled state and the debounced
    /// "N selected" announcement.
    let count: Int
    /// The primary, non-destructive batch action, filled and first.
    let primary: MultiSelectAction
    /// Secondary batch actions (e.g. Move, Remove), in order.
    var secondary: [MultiSelectAction] = []
    /// The singular item noun for the debounced count announcement
    /// ("podcast" → "3 podcasts selected"). Empty disables the announcement.
    var announcementNoun: String = ""

    private var hasSelection: Bool { count > 0 }

    var body: some View {
        VStack(spacing: Spacing.sm) {
            button(for: primary, prominent: true)
            ForEach(secondary) { action in
                button(for: action, prominent: false)
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
        .frame(maxWidth: .infinity)
        // Semantic surface + hairline separator so the bar reads as chrome above
        // the list, never a hardcoded color.
        .background(Color(.secondarySystemBackground))
        .overlay(alignment: .top) {
            Divider()
        }
        // Debounced, polite "N selected": `.task(id:)` cancels the pending
        // announcement whenever the count changes, so rapid toggling never
        // interrupts — only the settled count is spoken, and never assertively.
        .task(id: count) {
            guard hasSelection, !announcementNoun.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            Announcer.announce(MultiSelectActionLabel.selectedCount(count, itemSingular: announcementNoun))
        }
    }

    @ViewBuilder
    private func button(for action: MultiSelectAction, prominent: Bool) -> some View {
        let button = Button(role: action.isDestructive ? .destructive : nil) {
            action.handler()
        } label: {
            Label(action.title, systemImage: action.systemImage)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .disabled(!hasSelection)

        // Style, then add the "select something first" hint ONLY while disabled —
        // no empty hint in the enabled state.
        let styled = Group {
            if prominent {
                button.buttonStyle(.borderedProminent)
            } else if action.isDestructive {
                button.buttonStyle(.bordered).tint(.red)
            } else {
                button.buttonStyle(.bordered)
            }
        }
        if hasSelection {
            styled
        } else {
            styled.accessibilityHint("Select at least one item first")
        }
    }
}
