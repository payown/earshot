import SwiftUI

// Appearance preferences (#461): theme override, accent color, layout density.
// Pure value types with raw-value persistence (via AppSettingsStore) and
// side-effect-free mapping helpers so every mapping is unit-testable.

/// The user's manual theme override. ``followSystem`` (the default) leaves both
/// appearance and contrast entirely to iOS.
///
/// High Contrast approach: SwiftUI cannot force the system's increased-contrast
/// trait from inside an app, so the two High Contrast themes approximate it
/// with three visible changes on top of the forced light/dark scheme:
/// bold legibility weight (`\.legibilityWeight`), and the accent palette
/// resolved through UIKit's `accessibilityContrast(.high)` trait (see
/// ``AccentChoice/tint(for:)``) so tinted controls use the system's own
/// higher-contrast palette variants. They are visibly distinct from plain
/// Light/Dark, not no-ops.
enum ThemeOverride: String, Codable, CaseIterable, Identifiable {
    case followSystem = "follow_system"
    case light
    case dark
    case highContrastLight = "high_contrast_light"
    case highContrastDark = "high_contrast_dark"

    var id: String { rawValue }

    /// User-facing label for the theme picker.
    var displayName: String {
        switch self {
        case .followSystem: return "Follow System"
        case .light: return "Light"
        case .dark: return "Dark"
        case .highContrastLight: return "High Contrast Light"
        case .highContrastDark: return "High Contrast Dark"
        }
    }

    /// The scheme forced app-wide via `.preferredColorScheme`, or nil to follow
    /// the system.
    var colorScheme: ColorScheme? {
        switch self {
        case .followSystem: return nil
        case .light, .highContrastLight: return .light
        case .dark, .highContrastDark: return .dark
        }
    }

    var isHighContrast: Bool {
        self == .highContrastLight || self == .highContrastDark
    }

    /// Bold legibility for the High Contrast themes; nil means "don't touch",
    /// so a user's system Bold Text setting is never stripped (the applier uses
    /// `transformEnvironment` and only writes when this is non-nil).
    var legibilityWeight: LegibilityWeight? {
        isHighContrast ? .bold : nil
    }
}

/// The user's accent color override. ``systemDefault`` (the default) keeps the
/// app's asset-catalog accent; every other case maps to a semantic system
/// palette color (never a hardcoded hex) so it adapts to light/dark and, under
/// a High Contrast theme, to the system's increased-contrast variant.
enum AccentChoice: String, Codable, CaseIterable, Identifiable {
    case systemDefault = "system_default"
    case blue
    case green
    case orange
    case purple
    case red

    var id: String { rawValue }

    /// User-facing label for the accent picker. Always shown next to the color
    /// chip so color is never the only signal.
    var displayName: String {
        switch self {
        case .systemDefault: return "System Default"
        case .blue: return "Blue"
        case .green: return "Green"
        case .orange: return "Orange"
        case .purple: return "Purple"
        case .red: return "Red"
        }
    }

    /// The dynamic system palette color behind this choice; nil for
    /// ``systemDefault`` (no override).
    var baseUIColor: UIColor? {
        switch self {
        case .systemDefault: return nil
        case .blue: return .systemBlue
        case .green: return .systemGreen
        case .orange: return .systemOrange
        case .purple: return .systemPurple
        case .red: return .systemRed
        }
    }

    /// The app-wide tint for this choice under the given theme, or nil to leave
    /// the app's default accent in place (`.tint(nil)` is a documented no-op).
    ///
    /// Under a High Contrast theme the palette color is resolved through
    /// UIKit's `accessibilityContrast(.high)` trait, giving the system's own
    /// increased-contrast variant (e.g. system blue's darker light-mode HC
    /// shade) rather than an invented color. Resolving freezes the color, which
    /// is safe because a High Contrast theme also forces a fixed scheme.
    func tint(for theme: ThemeOverride) -> Color? {
        guard let base = baseUIColor else { return nil }
        guard theme.isHighContrast else { return Color(uiColor: base) }
        return Color(uiColor: Self.highContrastResolved(base, darkMode: theme.colorScheme == .dark))
    }

    /// Resolves a dynamic palette color against the increased-contrast trait in
    /// the given style. Internal (not private) so the mapping is unit-testable.
    static func highContrastResolved(_ color: UIColor, darkMode: Bool) -> UIColor {
        // iOS 17 trait-builder API; init(traitsFrom:) is deprecated on our target.
        let traits = UITraitCollection { traits in
            traits.userInterfaceStyle = darkMode ? .dark : .light
            traits.accessibilityContrast = .high
        }
        return color.resolvedColor(with: traits)
    }

    /// Chip color shown beside the label in the accent picker. System Default
    /// shows the app's current accent so every row has a chip; the text label
    /// and the picker's native selection state carry the meaning, never the
    /// color alone.
    var swatchColor: Color {
        if let base = baseUIColor { return Color(uiColor: base) }
        return .accentColor
    }
}

/// How tightly lists are packed. ``comfortable`` (the default) leaves the
/// system metrics untouched; ``compact`` tightens rows and section spacing but
/// never takes an interactive row below the 44pt touch-target floor.
enum LayoutDensity: String, Codable, CaseIterable, Identifiable {
    case comfortable
    case compact

    var id: String { rawValue }

    /// User-facing label for the density picker.
    var displayName: String {
        switch self {
        case .comfortable: return "Comfortable"
        case .compact: return "Compact"
        }
    }

    /// Explicit minimum list row height, or nil to leave the system default
    /// untouched (Comfortable = current behavior, unchanged). Compact clamps
    /// short rows down to — and never below — ``Spacing/minTouchTarget`` (44pt).
    /// Content taller than the minimum still sizes itself, so nothing clips at
    /// large Dynamic Type sizes.
    var minListRowHeight: CGFloat? {
        switch self {
        case .comfortable: return nil
        case .compact: return Spacing.minTouchTarget
        }
    }

    /// Spacing between list sections. `.default` is the system's standard value
    /// (Comfortable stays as today); `.compact` is the system's tightened value.
    var sectionSpacing: ListSectionSpacing {
        switch self {
        case .comfortable: return .default
        case .compact: return .compact
        }
    }
}
