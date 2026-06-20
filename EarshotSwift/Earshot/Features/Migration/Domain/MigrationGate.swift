import Foundation

/// Pure decision logic for the Flutter→SwiftUI migration prompt. Kept free of
/// SwiftData and UIKit so it is trivially unit-testable. The compile-time
/// `IS_BETA_BUILD` gate is applied by the caller (``RootView``) — this type only
/// answers the data-driven questions.
enum MigrationGate {
    /// After this many "Remind me later" dismissals the prompt stops offering
    /// the reminder and the user must choose Import or Start fresh.
    static let maxReminders = 3

    /// Whether the migration prompt should be shown on launch. Onboarding must be
    /// finished first (we never stack two full-screen flows) and migration must
    /// not already be resolved.
    static func shouldPrompt(onboardingComplete: Bool, migrationComplete: Bool) -> Bool {
        onboardingComplete && !migrationComplete
    }

    /// Whether the "Remind me later" option is still offered.
    static func canRemindLater(reminderCount: Int) -> Bool {
        reminderCount < maxReminders
    }
}
