import Foundation

/// Pure, view-runtime-free logic for the per-podcast "Notify on new episodes"
/// toggle's permission flow (#421).
///
/// `PodcastSettingsView` drives the same two operations from its toggle binding
/// (`apply`) and its `.task(id:)` (`requestAuthorizationIfNeeded`). Extracted so
/// the behavior is unit-testable without standing up a SwiftUI host: the bug in
/// #421 was that the prompt never fired when the toggle went ON, so the part
/// worth a test is "ON transition ⇒ requestAuthorization() is invoked".
///
/// `requestAuthorization()` is itself idempotent (never re-prompts once the user
/// has decided), so this only needs to ensure the call is REACHED on each ON
/// transition — iOS shows the system prompt at most once.
enum NotificationPermissionTrigger {

    /// Result of applying a new toggle value: the value to persist on the model
    /// and whether an authorization request should be triggered.
    struct Decision: Equatable {
        /// The value to write back to `Podcast.notificationEnabled`.
        let persistedValue: Bool
        /// True when the toggle transitioned to ON and a permission request
        /// should run.
        let shouldRequestAuthorization: Bool
    }

    /// Decides what happens when the toggle is set to `newValue`. Turning ON
    /// triggers an authorization request; turning OFF only persists the value.
    static func apply(newValue: Bool) -> Decision {
        Decision(persistedValue: newValue, shouldRequestAuthorization: newValue)
    }
}
