import CoreGraphics

/// Spacing scale used across the app. Use these tokens instead of magic numbers
/// so layout stays consistent and easy to tune.
enum Spacing {
    /// 4pt
    static let xs: CGFloat = 4
    /// 8pt
    static let sm: CGFloat = 8
    /// 12pt
    static let md: CGFloat = 12
    /// 16pt
    static let lg: CGFloat = 16
    /// 24pt
    static let xl: CGFloat = 24
    /// 32pt
    static let xxl: CGFloat = 32

    /// Minimum interactive touch target (HIG: 44pt).
    static let minTouchTarget: CGFloat = 44
}
