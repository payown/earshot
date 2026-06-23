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

    /// Whether to self-heal an already-migrated install. Fires when the migration
    /// is marked complete and the Flutter database still holds recoverable data,
    /// and EITHER:
    ///   - the SwiftData store has zero podcasts — the first-launch import fired
    ///     but found nothing (or failed) and locked the user out of a library
    ///     still recoverable from `earshot.db`; or
    ///   - the per-episode state overlay never completed (`episodeStateRestored`
    ///     is false) — the shows imported but played / inbox / queue state is
    ///     missing (a prior build, or an overlay that failed after the shells
    ///     imported).
    /// The caller picks the remedy by `podcastCount`: a full re-import when zero,
    /// a cheap local state-only re-overlay when the shows are already present, so
    /// recovering missing state never forces a full feed re-refresh (#426).
    static func shouldSelfHeal(
        migrationComplete: Bool,
        podcastCount: Int,
        episodeStateRestored: Bool,
        flutterHasData: Bool
    ) -> Bool {
        guard migrationComplete, flutterHasData else { return false }
        return podcastCount == 0 || !episodeStateRestored
    }
}
