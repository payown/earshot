import Foundation

/// Pure queue-expiration + Recently-Expired retention rules, mirroring the
/// Flutter `QueueExpirationService`.
enum ExpirationLogic {

    /// How long an auto-expired episode stays restorable before its files are
    /// deleted.
    static let recentlyExpiredRetentionDays = 7

    /// A queue item expires once it has sat in the queue longer than the
    /// per-podcast age limit (`addedAt` older than `now - ageLimitDays`).
    static func isExpired(addedAt: Date, ageLimitDays: Int, now: Date) -> Bool {
        addedAt < now.addingTimeInterval(-Double(ageLimitDays) * 86_400)
    }

    /// A Recently-Expired row should be purged once it's older than the
    /// retention window.
    static func shouldPurge(
        expiredAt: Date,
        now: Date,
        retentionDays: Int = recentlyExpiredRetentionDays
    ) -> Bool {
        expiredAt < now.addingTimeInterval(-Double(retentionDays) * 86_400)
    }
}
