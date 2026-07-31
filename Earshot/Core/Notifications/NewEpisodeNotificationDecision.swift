import Foundation

/// Pure rules for deciding whether a refreshed podcast should fire a "new
/// episodes" notification. No SwiftData, no UNUserNotificationCenter — kept
/// separate so the decision is unit-testable in isolation (#72).
///
/// A notification is warranted only when ALL of:
///   - the podcast has `notificationEnabled == true`, AND
///   - the refresh detected at least one genuinely-new episode (`addedCount > 0`),
///     AND
///   - the refresh was NOT a backfill pass.
///
/// The backfill paths (first-subscribe pre-dismiss, and freshly-migrated-shell
/// catalog backfill) intentionally insert episodes but represent pre-existing
/// catalog, not new episodes the user should be pinged about (#72).
enum NewEpisodeNotificationDecision {

    /// Whether a refresh result should produce a notification.
    static func shouldNotify(
        notificationEnabled: Bool,
        addedCount: Int,
        wasBackfill: Bool
    ) -> Bool {
        guard notificationEnabled else { return false }
        guard !wasBackfill else { return false }
        return addedCount > 0
    }
}
