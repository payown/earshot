import SwiftUI

/// Helpers for respecting the user's Reduce Motion setting. Non-essential
/// animations must be skipped when Reduce Motion is on.
enum Motion {
    /// Whether the system Reduce Motion setting is currently enabled.
    @MainActor
    static var isReduced: Bool {
        UIAccessibility.isReduceMotionEnabled
    }

    /// Returns `animation` when motion is allowed, otherwise `nil` (no animation).
    @MainActor
    static func preferred(_ animation: Animation) -> Animation? {
        isReduced ? nil : animation
    }
}

extension View {
    /// Applies an animation only when Reduce Motion is off.
    @MainActor
    func motionAwareAnimation<V: Equatable>(_ animation: Animation, value: V) -> some View {
        self.animation(Motion.isReduced ? nil : animation, value: value)
    }
}
