import SwiftUI

/// Applies trailing `.swipeActions` only when VoiceOver is OFF. SwiftUI promotes
/// swipe actions into the VoiceOver Actions rotor, which would duplicate an
/// action already offered as a first-class Quick Action via
/// `.accessibilityActions`. Mirroring ``QueueScreen``'s `SightedRowActions`, the
/// swipe is the sighted affordance and the rotor Quick Action is the single
/// VoiceOver source (#528).
///
/// `voiceOverEnabled` is read from the environment (not
/// `UIAccessibility.isVoiceOverRunning` inside a body) so toggling VoiceOver
/// while the list is on screen re-evaluates and adds/removes the swipe live.
struct SightedSwipeActions<Buttons: View>: ViewModifier {
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    let allowsFullSwipe: Bool
    @ViewBuilder let buttons: () -> Buttons

    func body(content: Content) -> some View {
        if voiceOverEnabled {
            content
        } else {
            content.swipeActions(edge: .trailing, allowsFullSwipe: allowsFullSwipe, content: buttons)
        }
    }
}

extension View {
    /// Adds a trailing swipe action shown only to sighted users. VoiceOver users
    /// reach the same action through the row's Quick Action rotor, so exposing it
    /// as a swipe too would create a duplicate rotor entry.
    func sightedSwipeActions<Buttons: View>(
        allowsFullSwipe: Bool = false,
        @ViewBuilder _ buttons: @escaping () -> Buttons
    ) -> some View {
        modifier(SightedSwipeActions(allowsFullSwipe: allowsFullSwipe, buttons: buttons))
    }
}
