import Foundation

/// Pure inbox membership + cap rules, mirroring the Flutter `InboxLimitService`.
/// An episode is in the inbox when `status == .newEpisode && !inboxDismissed`
/// and its podcast isn't excluded. Caps hide overflow by *dismissing*
/// (one-directional — the repository never clears the flag, so caps can't fight
/// a Clear Inbox or an include/exclude restore).
enum InboxLogic {

    /// A podcast is inbox-excluded when opted out, unless explicitly re-included.
    static func isExcluded(inboxExcluded: Bool, inboxIncluded: Bool) -> Bool {
        inboxExcluded && !inboxIncluded
    }

    /// Ids to dismiss for the per-podcast age limit: unplayed (`positionSeconds
    /// == 0`) inbox episodes whose `pubDate` is older than `now - ageLimitHours`.
    /// Missing pub dates are never dismissed. Caller passes only newEpisode,
    /// not-yet-dismissed candidates.
    static func idsToDismissForAge<ID>(
        _ items: [(id: ID, pubDate: Date?, positionSeconds: Int)],
        ageLimitHours: Int,
        now: Date
    ) -> [ID] {
        let cutoff = now.addingTimeInterval(-Double(ageLimitHours) * 3600)
        return items
            .filter { $0.positionSeconds == 0 && ($0.pubDate.map { $0 < cutoff } ?? false) }
            .map(\.id)
    }

    /// Ids to dismiss for the count cap: everything beyond the newest `cap`.
    /// `itemsNewestFirst` is the inbox candidates ordered newest first.
    static func idsToDismissForCount<ID>(_ itemsNewestFirst: [ID], cap: Int) -> [ID] {
        guard cap >= 0, itemsNewestFirst.count > cap else { return [] }
        return Array(itemsNewestFirst.dropFirst(cap))
    }
}
