import Foundation

/// Pure inbox membership + cap rules, mirroring the Flutter `InboxLimitService`.
/// An episode is in the inbox when `status == .newEpisode && !inboxDismissed`
/// and its podcast isn't excluded. Caps hide overflow by *dismissing*
/// (one-directional — the repository never clears the flag, so caps can't fight
/// a Clear Inbox or an include/exclude restore).
enum InboxLogic {

    static let displayBatchSize = 100

    /// Expands a large Inbox without ever exceeding the available result count.
    static func nextDisplayLimit(current: Int, total: Int) -> Int {
        min(max(0, total), max(0, current) + displayBatchSize)
    }

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

    /// Resolves `inboxDismissed` after a played-state change (#546). Marking an
    /// episode played dismisses it from the inbox; marking it unplayed leaves any
    /// existing dismissal in place, so a triaged episode never jumps back into
    /// the inbox. `inboxDismissed` is therefore sticky once set here — the same
    /// one-directional contract the per-podcast caps rely on.
    static func inboxDismissedAfterPlayedChange(nowPlayed: Bool, wasDismissed: Bool) -> Bool {
        nowPlayed ? true : wasDismissed
    }

    /// Ids to dismiss for the count cap: everything beyond the newest `cap`.
    /// `itemsNewestFirst` is the inbox candidates ordered newest first.
    static func idsToDismissForCount<ID>(_ itemsNewestFirst: [ID], cap: Int) -> [ID] {
        guard cap >= 0, itemsNewestFirst.count > cap else { return [] }
        return Array(itemsNewestFirst.dropFirst(cap))
    }

    /// The visible navigation title for the inbox. Shows a compact parenthesized
    /// count when there's at least one item ("Inbox (12)") and never "(0)" — an
    /// empty inbox reads just "Inbox" so the empty state carries the message.
    static func inboxTitle(count: Int) -> String {
        count > 0 ? "Inbox (\(count))" : "Inbox"
    }

    /// The VoiceOver label for the inbox title. The visible "(12)" form is spoken
    /// awkwardly ("open paren, 12, close paren"), so we hand VoiceOver a natural
    /// sentence with correct singular/plural ("Inbox, 12 episodes" / "1 episode").
    /// Empty inbox reads just "Inbox".
    static func inboxTitleAccessibilityLabel(count: Int) -> String {
        guard count > 0 else { return "Inbox" }
        let noun = count == 1 ? "episode" : "episodes"
        return "Inbox, \(count) \(noun)"
    }
}
