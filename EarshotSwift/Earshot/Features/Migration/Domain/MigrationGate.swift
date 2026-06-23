import Foundation

/// Pure decision logic for the one-time Flutter→SwiftUI subscription import.
/// Kept free of SwiftData and UIKit so it is trivially unit-testable.
enum MigrationGate {
    /// How many launches we let the import retry when the Flutter database
    /// yields no subscriptions before giving up and marking the migration
    /// complete. Covers a transient first-launch miss (`earshot.db` not yet
    /// readable on a cold launch) without looping forever for a genuinely empty
    /// install (#426).
    static let maxAttempts = 3

    /// Whether the one-time import should run on launch. It runs while the
    /// migration is not yet marked complete, and never again after it completes.
    static func shouldImport(migrationComplete: Bool) -> Bool {
        !migrationComplete
    }

    /// After a launch where the Flutter database yielded no subscriptions,
    /// whether we have exhausted the retry budget and should give up (mark the
    /// migration complete). `attempts` is the running count *including* this
    /// launch. Below the budget we leave the gate open so the next launch
    /// retries; a transient miss recovers, a real empty install stops after
    /// `maxAttempts` (#426).
    static func shouldGiveUp(attempts: Int, maxAttempts: Int = maxAttempts) -> Bool {
        attempts >= maxAttempts
    }

    /// Whether to self-heal an already-migrated install: the migration is marked
    /// complete, yet the SwiftData store has zero podcasts while the Flutter
    /// database still holds data. That means the first-launch import fired but
    /// found nothing (or failed) and locked the user out of a library that is
    /// still recoverable from `earshot.db`. Reset the flag and re-import (#426).
    static func shouldSelfHeal(
        migrationComplete: Bool,
        podcastCount: Int,
        flutterHasData: Bool
    ) -> Bool {
        migrationComplete && podcastCount == 0 && flutterHasData
    }
}
