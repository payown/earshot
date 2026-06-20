import SwiftUI

/// Semantic colors sourced from the system so the app follows the user's theme,
/// contrast, and appearance settings (never hardcoded hex). Add app-specific
/// named colors to the asset catalog and surface them here.
enum AppColor {
    static let primaryText = Color(uiColor: .label)
    static let secondaryText = Color(uiColor: .secondaryLabel)
    static let background = Color(uiColor: .systemBackground)
    static let groupedBackground = Color(uiColor: .systemGroupedBackground)
    static let separator = Color(uiColor: .separator)
    static let accent = Color.accentColor

    /// State colors — always paired with an icon and text, never used as the
    /// sole signal for a state (see the accessibility rules).
    static let played = Color(uiColor: .systemGreen)
    static let error = Color(uiColor: .systemRed)
}
