import SwiftUI

/// Applies the user's Appearance preferences (#461) at the app root. Attached
/// to RootView's TabView so every tab, pushed screen, and presented sheet
/// follows the choice live — SettingsStore is @Observable, so a change in
/// Settings → Appearance re-evaluates RootView's body and re-applies this
/// modifier with no relaunch.
///
/// Every branch is value-driven (nil / no-op values for the defaults), never a
/// structural `if` around `content`, so changing appearance can't reset view
/// identity (tab selection, navigation paths).
struct AppearanceApplier: ViewModifier {
    let theme: ThemeOverride
    let accent: AccentChoice
    let density: LayoutDensity

    func body(content: Content) -> some View {
        content
            // nil = follow the system; a concrete scheme overrides the whole
            // window presentation, sheets included.
            .preferredColorScheme(theme.colorScheme)
            // nil = keep the app's default accent. Under a High Contrast theme
            // this is the system's increased-contrast palette variant (see
            // AccentChoice.tint(for:)).
            .tint(accent.tint(for: theme))
            // High Contrast: bold legibility. transformEnvironment writes only
            // when the theme asks for it, so a user's system Bold Text setting
            // is never stripped by the follow-system / plain themes.
            .transformEnvironment(\.legibilityWeight) { weight in
                if let boldWeight = theme.legibilityWeight {
                    weight = boldWeight
                }
            }
            // Density: Compact clamps short rows down to the 44pt touch-target
            // floor; Comfortable leaves the system default untouched. Content
            // taller than the minimum still sizes itself, so nothing clips at
            // large Dynamic Type sizes.
            .transformEnvironment(\.defaultMinListRowHeight) { height in
                if let minHeight = density.minListRowHeight {
                    height = max(minHeight, Spacing.minTouchTarget)
                }
            }
            // Density: section spacing for descendant lists. `.default` is the
            // system value, so Comfortable stays exactly as today.
            .listSectionSpacing(density.sectionSpacing)
    }
}

extension View {
    /// RootView entry point: `content.appearance(theme:accent:density:)`.
    func appearance(theme: ThemeOverride, accent: AccentChoice, density: LayoutDensity) -> some View {
        modifier(AppearanceApplier(theme: theme, accent: accent, density: density))
    }
}
