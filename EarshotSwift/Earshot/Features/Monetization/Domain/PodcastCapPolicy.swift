import Foundation
import SwiftData

/// Pure decision logic for the free-tier podcast subscription cap (#635). Takes
/// primitives + `[Podcast]` arrays (never a `ModelContext` or StoreKit type) so
/// it's trivially unit-testable with in-memory `@Model` fixtures — matching how
/// `InboxRepository.inbox(from:)` / `QueueRepository.displayedCount(from:)`
/// already take model arrays directly in this codebase.
///
/// See "Issue #635" in SWIFTUI_PLAN.md's Data Decisions for the full reasoning
/// behind `effectiveFreeLimit`/grandfathering.
enum PodcastCapPolicy {
    /// The free-tier podcast subscription limit (PRD rule 5 / issue #635).
    static let freeTierLimit = 10

    /// The effective free limit for THIS install: normally `freeTierLimit`,
    /// but never less than `grandfatheredCount` — a TestFlight tester who
    /// already had more than 10 podcasts before this gating shipped keeps
    /// all of them fully read-write forever ("keep everything they have"),
    /// they just get no MORE free slots than they already had.
    static func effectiveFreeLimit(grandfatheredCount: Int) -> Int {
        max(freeTierLimit, grandfatheredCount)
    }

    /// Whether a non-Plus (or Plus) user may add one more subscription right now.
    static func canAddSubscription(currentCount: Int, isEntitled: Bool, grandfatheredCount: Int) -> Bool {
        isEntitled || currentCount < effectiveFreeLimit(grandfatheredCount: grandfatheredCount)
    }

    /// For bulk OPML import: how many of `requested` new feed URLs can actually
    /// be subscribed right now, given `currentCount` already-subscribed podcasts.
    /// Plus users get all of them; free-tier users get however many free slots
    /// remain (clamped >= 0).
    static func allowedNewSubscriptions(currentCount: Int, requested: Int, isEntitled: Bool, grandfatheredCount: Int) -> Int {
        guard requested > 0 else { return 0 }
        guard !isEntitled else { return requested }
        let remaining = max(0, effectiveFreeLimit(grandfatheredCount: grandfatheredCount) - currentCount)
        return min(requested, remaining)
    }

    /// Whether the podcast at zero-based `rank` (in the stable ascending order
    /// below) is read-only right now.
    static func isReadOnly(rank: Int, isEntitled: Bool, grandfatheredCount: Int) -> Bool {
        !isEntitled && rank >= effectiveFreeLimit(grandfatheredCount: grandfatheredCount)
    }

    /// Stable ascending rank order for cap purposes: oldest `createdAt` first
    /// (so pre-existing/grandfathered podcasts always rank first and are never
    /// read-only), ties broken by `feedURL` for full determinism — a bulk OPML
    /// import can insert several podcasts with the same `Date.now` instant.
    static func ranked(_ podcasts: [Podcast]) -> [Podcast] {
        podcasts.sorted { a, b in
            if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
            return a.feedURL < b.feedURL
        }
    }

    /// The `persistentModelID`s of every podcast that is read-only right now,
    /// given the full podcast list, current entitlement, and grandfathered
    /// count. Used by both auto-download (skip downloading for these) and the
    /// Library UI (badge these rows).
    static func readOnlyPodcastIDs(in podcasts: [Podcast], isEntitled: Bool, grandfatheredCount: Int) -> Set<PersistentIdentifier> {
        guard !isEntitled else { return [] }
        let limit = effectiveFreeLimit(grandfatheredCount: grandfatheredCount)
        guard podcasts.count > limit else { return [] }
        let orderedIDs = ranked(podcasts).map(\.persistentModelID)
        return Set(orderedIDs.dropFirst(limit))
    }
}
