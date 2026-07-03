import SwiftUI

/// Settings → Appearance (#461): manual theme override, accent color, and
/// layout density. Three native inline Pickers — SwiftUI's built-in selection
/// semantics announce each option's selected state to VoiceOver, so no custom
/// Semantics work is needed here. Every accent row pairs a color chip with a
/// text label and the picker's native checkmark, so color is never the only
/// signal. Changes persist through ``SettingsStore`` and apply live:
/// RootView observes the store and re-applies ``AppearanceApplier`` at the app
/// root — no relaunch.
struct AppearanceSettingsView: View {
    @Environment(SettingsStore.self) private var settings
    /// Decorative accent chip size, scaled with Dynamic Type so it grows for
    /// low-vision users alongside the label (house pattern; the chip itself is
    /// hidden from VoiceOver).
    @ScaledMetric private var chipSize: CGFloat = Spacing.xl

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker("Theme", selection: $settings.themeOverride) {
                    ForEach(ThemeOverride.allCases) { theme in
                        Text(theme.displayName).tag(theme)
                    }
                }
                .pickerStyle(.inline)
            } footer: {
                Text("High Contrast Light and Dark use bolder text and stronger accent colors on top of the fixed appearance.")
            }

            Section {
                Picker("Accent color", selection: $settings.accentColor) {
                    ForEach(AccentChoice.allCases) { accent in
                        // Chip + text label: the label and the picker's native
                        // selection state carry the meaning; the chip is a
                        // visual aid, never the only signal.
                        HStack(spacing: Spacing.md) {
                            Circle()
                                .fill(accent.swatchColor)
                                .frame(width: chipSize, height: chipSize)
                                .accessibilityHidden(true)
                            Text(accent.displayName)
                        }
                        .tag(accent)
                    }
                }
                .pickerStyle(.inline)
            } footer: {
                Text("Colors buttons, links, and controls throughout the app.")
            }

            Section {
                Picker("Layout density", selection: $settings.layoutDensity) {
                    ForEach(LayoutDensity.allCases) { density in
                        Text(density.displayName).tag(density)
                    }
                }
                .pickerStyle(.inline)
            } footer: {
                Text("Compact tightens list spacing. Buttons and rows always stay large enough to tap easily.")
            }
        }
        .navigationTitle("Appearance")
    }
}
