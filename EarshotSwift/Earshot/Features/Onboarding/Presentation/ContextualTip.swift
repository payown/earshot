import SwiftUI

/// A dismissable contextual tip banner. Shows once per category the first time
/// its screen appears, announces itself politely to VoiceOver, and is remembered
/// as dismissed so it never returns. Apply with `.contextualTip(.inbox)`.
private struct ContextualTipModifier: ViewModifier {
    @Environment(TipsStore.self) private var tips
    let category: TipCategory

    @State private var visible = false

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .top) {
            if visible {
                banner
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onAppear {
            guard tips.shouldShow(category) else { return }
            tips.markShown(category)
            withAnimation { visible = true }
            // Polite live-region announcement of the tip text, delayed so it
            // isn't swallowed by the screen-change utterance as the tab appears.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                Announcer.announce(category.message)
            }
        }
    }

    private var banner: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            Image(systemName: "lightbulb")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(category.message)
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                withAnimation { visible = false }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .frame(minWidth: Spacing.minTouchTarget, minHeight: Spacing.minTouchTarget)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Dismiss tip")
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
        .background(.regularMaterial)
        // Group the icon + text as one element; the dismiss button stays separate.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tip: \(category.message)")
    }
}

extension View {
    /// Shows a one-time contextual tip for `category` at the top of this screen.
    func contextualTip(_ category: TipCategory) -> some View {
        modifier(ContextualTipModifier(category: category))
    }
}
