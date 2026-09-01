import Foundation
import SwiftData

extension Notification.Name {
    /// Posted when something that can change the Inbox unread count changes —
    /// episodes ingested, played/unplayed, dismissed, cap-hidden, or a podcast
    /// included/excluded. The Inbox tab badge listens for this (plus queue
    /// changes and app-foreground) and recomputes ONLY then, so it never does
    /// store work on the ~5-second playback-position save that heated the phone
    /// on large libraries (#736).
    static let earshotInboxDidChange = Notification.Name("earshotInboxDidChange")
}

/// Store-queryable Inbox membership. Keeping the podcast rules in these
/// predicates is important: reading `episode.podcast` in an in-memory filter
/// faults the Podcast's inverse `episodes` relationship and can enumerate an
/// entire large library on the main actor.
enum InboxQuery {
    static let normal = #Predicate<Episode> { episode in
        episode.inboxDismissed == false &&
        (episode.podcast == nil || episode.podcast?.inboxExcluded == false || episode.podcast?.inboxIncluded == true)
    }

    static let optInOnly = #Predicate<Episode> { episode in
        episode.inboxDismissed == false &&
        episode.podcast?.inboxIncluded == true
    }

    static func predicate(optInOnly: Bool) -> Predicate<Episode> {
        optInOnly ? self.optInOnly : normal
    }

    // The same membership rules, but ALSO restricted to unplayed episodes
    // (`playedAt == nil`). Inbox membership is `status == .newEpisode`, and
    // `status` cannot be expressed in a `#Predicate` — comparing the stored enum
    // to a case degenerates to an unsupported `\.newEpisode` key path, and even
    // when coaxed to compile it silently matches zero rows. So the store cannot
    // filter to `.newEpisode` directly. A played episode always carries a non-nil
    // `playedAt` (see `Episode.isPlayed`'s setter). Current completion paths also
    // dismiss it, while ``InboxHistoryMaintenance`` repairs rows left by older
    // builds. Keeping `playedAt == nil` here remains defense-in-depth during that
    // bounded cleanup and trims played history out of the fetch. The result is a small
    // superset of the inbox — unplayed, non-dismissed episodes — over which the
    // exact `.newEpisode` check is a cheap in-memory pass. This keeps the badge's
    // per-save cost proportional to the (bounded) unplayed set instead of the
    // whole library, which is what the `cpu_resource_fatal` termination needed.
    static let normalUnplayed = #Predicate<Episode> { episode in
        episode.playedAt == nil &&
        episode.inboxDismissed == false &&
        (episode.podcast == nil || episode.podcast?.inboxExcluded == false || episode.podcast?.inboxIncluded == true)
    }

    static let optInOnlyUnplayed = #Predicate<Episode> { episode in
        episode.playedAt == nil &&
        episode.inboxDismissed == false &&
        episode.podcast?.inboxIncluded == true
    }

    static func unplayedPredicate(optInOnly: Bool) -> Predicate<Episode> {
        optInOnly ? optInOnlyUnplayed : normalUnplayed
    }

    /// Store-queryable predicate for one podcast in a folder subtree (#763).
    /// ``InboxRepository/inboxEpisodes(in:)`` executes this once per
    /// de-duplicated subtree podcast and merges the small results. SwiftData's
    /// generated SQL does not support a captured array `contains` across the
    /// optional Episode→Podcast relationship (it raises an Objective-C exception
    /// at fetch time), while scalar relationship equality is fully supported.
    /// This form therefore keeps the global library out of memory safely and
    /// still removes played + dismissed history in the store.
    static func folderUnplayedPredicate(podcastID: PersistentIdentifier) -> Predicate<Episode> {
        return #Predicate<Episode> { episode in
            episode.podcast?.persistentModelID == podcastID &&
            episode.playedAt == nil &&
            episode.inboxDismissed == false
        }
    }
}

/// A stable Inbox scope that can cross from SwiftUI's main context to the
/// background page loader without carrying SwiftData models between actors.
enum InboxPageScope: Sendable, Equatable, Hashable {
    case all
    case folder(PersistentIdentifier)
}

/// One bounded presentation page. `inboxCount` preserves the existing title and
/// Clear-Inbox wording while `matchingCount` drives search announcements and the
/// explicit Show-more boundary.
struct InboxIdentifierPage: Sendable, Equatable {
    let ids: [PersistentIdentifier]
    let downloadIDs: [PersistentIdentifier]
    let inboxCount: Int
    let matchingCount: Int
    let candidateCount: Int
    let downloadEligibleCount: Int
    let downloadSkippedCount: Int

    var hasMore: Bool { ids.count < matchingCount }
}

private struct InboxSortableIdentifier: Sendable {
    let id: PersistentIdentifier
    let pubDate: Date?
    let createdAt: Date
    let guid: String
}

/// Background, fixed-memory Inbox scan. SwiftData cannot predicate on the
/// stored `EpisodeStatus` enum, so the actor scans the already store-bounded
/// unplayed/non-dismissed candidate set in small pages and retains only scalar
/// identities for publication.
@ModelActor
actor InboxPageLoader {
    static let storeBatchSize = 128

    func page(
        scope: InboxPageScope,
        optInOnly: Bool,
        searchText: String,
        limit requestedLimit: Int
    ) throws -> InboxIdentifierPage {
        let limit = max(InboxLogic.displayBatchSize, requestedLimit)
        let podcastIDs = try scopePodcastIDs(scope)
        var candidateCount = 0
        var inboxCount = 0
        var matchingCount = 0
        var matches: [InboxSortableIdentifier] = []
        var downloadEligibleCount = 0
        var downloadSkippedCount = 0
        var downloadMatches: [InboxSortableIdentifier] = []

        switch scope {
        case .all:
            var offset = 0
            while true {
                try Task.checkCancellation()
                var descriptor = FetchDescriptor<Episode>(
                    predicate: InboxQuery.unplayedPredicate(optInOnly: optInOnly),
                    sortBy: [
                        SortDescriptor(\Episode.pubDate, order: .reverse),
                        SortDescriptor(\Episode.createdAt, order: .reverse),
                        SortDescriptor(\Episode.guid, order: .forward),
                    ]
                )
                descriptor.fetchOffset = offset
                descriptor.fetchLimit = Self.storeBatchSize
                let batch = try modelContext.fetch(descriptor)
                guard !batch.isEmpty else { break }
                candidateCount += batch.count
                collect(
                    batch,
                    optInOnly: optInOnly,
                    searchText: searchText,
                    limit: limit,
                    inboxCount: &inboxCount,
                    matchingCount: &matchingCount,
                    matches: &matches,
                    downloadEligibleCount: &downloadEligibleCount,
                    downloadSkippedCount: &downloadSkippedCount,
                    downloadMatches: &downloadMatches
                )
                if batch.count < Self.storeBatchSize { break }
                offset += batch.count
            }

        case .folder:
            for podcastID in podcastIDs {
                var offset = 0
                while true {
                    try Task.checkCancellation()
                    var descriptor = FetchDescriptor<Episode>(
                        predicate: InboxQuery.folderUnplayedPredicate(podcastID: podcastID),
                        sortBy: [
                            SortDescriptor(\Episode.pubDate, order: .reverse),
                            SortDescriptor(\Episode.createdAt, order: .reverse),
                            SortDescriptor(\Episode.guid, order: .forward),
                        ]
                    )
                    descriptor.fetchOffset = offset
                    descriptor.fetchLimit = Self.storeBatchSize
                    let batch = try modelContext.fetch(descriptor)
                    guard !batch.isEmpty else { break }
                    candidateCount += batch.count
                    collect(
                        batch,
                        optInOnly: optInOnly,
                        searchText: searchText,
                        limit: limit,
                        inboxCount: &inboxCount,
                        matchingCount: &matchingCount,
                        matches: &matches,
                        downloadEligibleCount: &downloadEligibleCount,
                        downloadSkippedCount: &downloadSkippedCount,
                        downloadMatches: &downloadMatches
                    )
                    if batch.count < Self.storeBatchSize { break }
                    offset += batch.count
                }
            }
        }

        matches.sort(by: Self.precedes)
        return InboxIdentifierPage(
            ids: matches.prefix(limit).map(\.id),
            downloadIDs: downloadMatches.map(\.id),
            inboxCount: inboxCount,
            matchingCount: matchingCount,
            candidateCount: candidateCount,
            downloadEligibleCount: downloadEligibleCount,
            downloadSkippedCount: downloadSkippedCount
        )
    }

    private func collect(
        _ episodes: [Episode],
        optInOnly: Bool,
        searchText: String,
        limit: Int,
        inboxCount: inout Int,
        matchingCount: inout Int,
        matches: inout [InboxSortableIdentifier],
        downloadEligibleCount: inout Int,
        downloadSkippedCount: inout Int,
        downloadMatches: inout [InboxSortableIdentifier]
    ) {
        for episode in episodes where isInboxEpisode(episode, optInOnly: optInOnly) {
            inboxCount += 1
            guard Self.matches(episode, query: searchText) else { continue }
            matchingCount += 1
            let candidate = InboxSortableIdentifier(
                id: episode.persistentModelID,
                pubDate: episode.pubDate,
                createdAt: episode.createdAt,
                guid: episode.guid
            )
            Self.retain(candidate, limit: limit, in: &matches)
            if episode.downloadStatus == .none || episode.downloadStatus == .failed {
                downloadEligibleCount += 1
                Self.retain(
                    candidate,
                    limit: ManualDownloadBatchPlan.maximumEpisodeCount,
                    in: &downloadMatches
                )
            } else {
                downloadSkippedCount += 1
            }
        }
    }

    private static func retain(
        _ candidate: InboxSortableIdentifier,
        limit: Int,
        in matches: inout [InboxSortableIdentifier]
    ) {
        if matches.count < limit {
            matches.append(candidate)
            matches.sort(by: Self.precedes)
        } else if let last = matches.last, Self.precedes(candidate, last) {
            matches[matches.count - 1] = candidate
            matches.sort(by: Self.precedes)
        }
    }

    private func isInboxEpisode(_ episode: Episode, optInOnly: Bool) -> Bool {
        guard episode.status == .newEpisode,
              !episode.inboxDismissed,
              episode.podcast?.isCatalogOnly != true else { return false }
        if optInOnly { return episode.podcast?.inboxIncluded == true }
        return episode.podcast.map {
            !InboxLogic.isExcluded(
                inboxExcluded: $0.inboxExcluded,
                inboxIncluded: $0.inboxIncluded
            )
        } ?? true
    }

    private static func matches(_ episode: Episode, query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        if episode.title.localizedStandardContains(query) { return true }
        if episode.podcast?.title.localizedStandardContains(query) == true { return true }
        return EpisodeSummary.plainText(episode.episodeDescription)
            .localizedStandardContains(query)
    }

    private func scopePodcastIDs(_ scope: InboxPageScope) throws -> [PersistentIdentifier] {
        guard case .folder(let rootID) = scope else { return [] }
        var pending = [rootID]
        var visited = Set<PersistentIdentifier>()
        var podcastIDs = Set<PersistentIdentifier>()
        while let folderID = pending.popLast(), visited.insert(folderID).inserted {
            try Task.checkCancellation()
            let memberships = try modelContext.fetch(FetchDescriptor<FolderMembership>(
                predicate: #Predicate { $0.folder?.persistentModelID == folderID }
            ))
            podcastIDs.formUnion(memberships.compactMap { membership in
                guard membership.podcast?.isFollowed == true else { return nil }
                return membership.podcast?.persistentModelID
            })
            let children = try modelContext.fetch(FetchDescriptor<PodcastFolder>(
                predicate: #Predicate { $0.parent?.persistentModelID == folderID }
            ))
            pending.append(contentsOf: children.map(\.persistentModelID))
        }
        return Array(podcastIDs)
    }

    private static func precedes(
        _ lhs: InboxSortableIdentifier,
        _ rhs: InboxSortableIdentifier
    ) -> Bool {
        if lhs.pubDate != rhs.pubDate {
            return FolderLogic.byPubDateDescending(lhs.pubDate, rhs.pubDate)
        }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        return lhs.guid < rhs.guid
    }
}

/// The inbox is a view over episodes: `status == .newEpisode && !inboxDismissed`
/// from non-excluded podcasts. Per-podcast caps (count / age) hide overflow by
/// setting `inboxDismissed` — one-directional, so caps never fight Clear Inbox
/// or an include/exclude restore. Rules live in ``InboxLogic``.
@MainActor
final class InboxRepository {
    private let context: ModelContext
    private let settings: AppSettingsStore

    init(context: ModelContext) {
        self.context = context
        self.settings = AppSettingsStore(context: context)
    }

    func identifierPage(
        scope: InboxPageScope,
        optInOnly: Bool,
        searchText: String,
        limit: Int
    ) async throws -> InboxIdentifierPage {
        try await InboxPageLoader(modelContainer: context.container).page(
            scope: scope,
            optInOnly: optInOnly,
            searchText: searchText,
            limit: limit
        )
    }

    func resolve(_ ids: [PersistentIdentifier]) -> [Episode] {
        guard !ids.isEmpty else { return [] }
        let requestedIDs = ids
        let descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate { requestedIDs.contains($0.persistentModelID) }
        )
        let fetched = (try? context.fetch(descriptor)) ?? []
        let byID = Dictionary(uniqueKeysWithValues: fetched.map {
            ($0.persistentModelID, $0)
        })
        return ids.compactMap { byID[$0] }
    }

    /// Clears the complete selected Inbox scope in bounded, durable batches.
    /// Each pass asks the background actor for the first remaining page, so
    /// deleting or syncing rows between passes cannot invalidate an offset.
    @discardableResult
    func clearInbox(scope: InboxPageScope, optInOnly: Bool) async -> Int {
        var cleared = 0
        while !Task.isCancelled {
            let page: InboxIdentifierPage
            do {
                page = try await identifierPage(
                    scope: scope,
                    optInOnly: optInOnly,
                    searchText: "",
                    limit: InboxLogic.displayBatchSize
                )
            } catch {
                AppLog.data.error("Inbox clear page failed: \(error.localizedDescription, privacy: .public)")
                break
            }
            let batch = resolve(page.ids)
            guard !batch.isEmpty else { break }
            clearInbox(batch)
            cleared += batch.count
            await Task.yield()
        }
        return cleared
    }

    /// Removes models that SwiftData invalidated after an event-driven Inbox
    /// snapshot was fetched. Refresh identity repair and CloudKit projection can
    /// delete an Episode before the matching Inbox notification replaces the
    /// view's cached array. Persisted-property access on that stale model traps
    /// inside SwiftData, so callers must perform this backing-data-only guard
    /// before reading status, title, or any relationship.
    static func liveEpisodes(_ candidates: [Episode], in context: ModelContext) -> [Episode] {
        candidates.filter { !$0.isDeleted && $0.modelContext == context }
    }

    /// Revalidates an event-driven Inbox snapshot against mutable episode state.
    ///
    /// A snapshot can remain alive while a navigation destination covers its
    /// view. If an episode is marked played from that destination, the cached
    /// array can miss the notification even though its `Episode` reference now
    /// exposes the saved played state. Filtering immediately before rendering
    /// prevents that stale reference from lingering under "New episodes."
    /// Podcast inclusion/exclusion remains store-filtered when the snapshot is
    /// loaded; this cheap pass owns only the episode-local membership fields.
    static func currentEpisodes(_ candidates: [Episode], in context: ModelContext) -> [Episode] {
        liveEpisodes(candidates, in: context).filter {
            $0.status == .newEpisode && !$0.inboxDismissed
                && $0.podcast?.isCatalogOnly != true
        }
    }

    /// Inbox episodes, newest first.
    ///
    /// Relationship-based membership rules are translated to SQL. In
    /// particular, podcast inclusion must not be evaluated by faulting
    /// `Episode.podcast` in Swift: SwiftData can then populate the inverse
    /// `Podcast.episodes` relationship, turning a 2,000-row Inbox into hundreds
    /// of thousands of relationship rows. The Codable status enum remains a
    /// bounded scalar check after the fetch.
    func inboxEpisodes() -> [Episode] {
        let optInOnly = settings.bool(SettingsKey.inboxOptInOnly, default: SettingsDefault.inboxOptInOnly)
        let descriptor = FetchDescriptor<Episode>(
            predicate: InboxQuery.predicate(optInOnly: optInOnly),
            sortBy: [SortDescriptor(\.pubDate, order: .reverse)]
        )
        return ((try? context.fetch(descriptor)) ?? []).filter {
            $0.status == .newEpisode && $0.podcast?.isCatalogOnly != true
        }
    }

    /// The folder's own Inbox, subtree-aware and newest first (#763). Each
    /// de-duplicated podcast is fetched through
    /// ``InboxQuery/folderUnplayedPredicate(podcastID:)`` so the store applies
    /// relationship scope + played/dismissed bounds without materializing the
    /// global library or faulting a podcast's full inverse episode collection.
    /// The normal/opt-in inclusion policy and exact status check are then applied
    /// over the already-bounded candidate set.
    func inboxEpisodes(in folder: PodcastFolder) -> [Episode] {
        let podcasts = FolderRepository(context: context).subtreeSubscriptions(of: folder)
        var seen = Set<PersistentIdentifier>()
        var candidates: [Episode] = []
        for podcast in podcasts {
            let descriptor = FetchDescriptor<Episode>(
                predicate: InboxQuery.folderUnplayedPredicate(
                    podcastID: podcast.persistentModelID
                ),
                sortBy: [SortDescriptor(\.pubDate, order: .reverse)]
            )
            for episode in (try? context.fetch(descriptor)) ?? []
            where seen.insert(episode.persistentModelID).inserted {
                candidates.append(episode)
            }
        }
        return inbox(from: candidates).sorted { lhs, rhs in
            if lhs.pubDate != rhs.pubDate {
                return FolderLogic.byPubDateDescending(lhs.pubDate, rhs.pubDate)
            }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.guid < rhs.guid
        }
    }

    /// The inbox membership COUNT, backing the always-mounted tab badge
    /// (`RootView.InboxTabBadge`).
    ///
    /// The badge previously counted by materializing the *whole* non-dismissed
    /// library and filtering `status` in Swift. That re-runs on every `Episode`
    /// save — including the 5-second playback-position save — and on a large
    /// library each pass costs hundreds of ms to seconds (measured: ~320ms at
    /// 10k rows, ~3s at 100k) when older builds left finished episodes
    /// non-dismissed and the set grew without bound over listening history. Once
    /// that per-save cost exceeds the save cadence the main thread saturates and
    /// iOS force-terminates the app under `cpu_resource_fatal` (~93% CPU / 60s).
    ///
    /// Fetching ``InboxQuery/unplayedPredicate(optInOnly:)`` restricts the store
    /// work to unplayed, non-dismissed episodes — a bounded superset of the
    /// inbox that excludes the unbounded played-history bucket — and the exact
    /// `.newEpisode` check is then a cheap in-memory pass. `status` can't be
    /// pushed into the predicate (SwiftData silently matches zero rows for a
    /// stored-enum comparison), so this in-memory filter stays authoritative.
    func inboxCount(optInOnly: Bool) -> Int {
        let descriptor = FetchDescriptor<Episode>(predicate: InboxQuery.unplayedPredicate(optInOnly: optInOnly))
        let candidates = (try? context.fetch(descriptor)) ?? []
        return candidates.filter {
            $0.status == .newEpisode && $0.podcast?.isCatalogOnly != true
        }.count
    }


    /// Applies the in-memory inbox membership rules (status + per-podcast
    /// exclusion) to an already-fetched, already-sorted candidate set — the
    /// non-dismissed episodes, newest first.
    ///
    /// This lets a view drive its list and counts off a predicate-filtered
    /// `@Query` (whose result SwiftData maintains and keeps current) and pay only
    /// this cheap in-memory pass per render, instead of a fresh `context.fetch`
    /// on every body evaluation. Previously every `Episode` save — including the
    /// 5-second playback-position save — re-rendered RootView and InboxScreen,
    /// and each re-ran `inboxEpisodes()` (InboxScreen ~6x per body), so the
    /// per-position save fanned out into repeated synchronous fetches on the main
    /// thread that starved VoiceOver. Order is preserved (`filter` keeps the
    /// candidate sort), so contents and ordering are identical to
    /// `inboxEpisodes()`.
    func inbox(from candidates: [Episode]) -> [Episode] {
        let optInOnly = settings.bool(SettingsKey.inboxOptInOnly, default: SettingsDefault.inboxOptInOnly)
        return candidates.filter {
            $0.status == .newEpisode &&
            !$0.inboxDismissed &&
            $0.podcast?.isCatalogOnly != true &&
            !isExcluded($0.podcast, optInOnly: optInOnly)
        }
    }

    /// Applies per-podcast age + count caps across all included podcasts. Safe to
    /// call after a refresh or an include/exclude change.
    func applyLimits(now: Date = .now) {
        let optInOnly = settings.bool(SettingsKey.inboxOptInOnly, default: SettingsDefault.inboxOptInOnly)
        let podcasts = (try? context.fetch(PodcastQuery.followedDescriptor())) ?? []
        for podcast in podcasts where !isExcluded(podcast, optInOnly: optInOnly) {
            applyForPodcast(podcast, now: now)
        }
        save()
    }

    /// Hides every current inbox episode.
    func clearInbox() {
        clearInbox(inboxEpisodes())
    }

    /// Hides exactly `episodes`, used by a folder-filtered Inbox so "Clear
    /// inbox" never dismisses episodes outside the visible scope (#763).
    func clearInbox(_ episodes: [Episode]) {
        let shouldDeleteDownloads = DownloadCleanup.deleteAfterPlayedEnabled(context)
        for episode in episodes {
            episode.inboxDismissed = true
            if shouldDeleteDownloads {
                DownloadCleanup.removeDownloadFileAndState(episode, in: context)
            }
        }
        save(changedEpisodes: episodes, inboxDismissedChangedExplicitly: true)
    }

    /// Removes one episode from Inbox without changing played state. This is an
    /// explicit user-authored dismissal, so it receives its own projection clock
    /// and remains independent from played-state synchronization (#824).
    func dismiss(_ episode: Episode) {
        guard !episode.inboxDismissed else { return }
        episode.inboxDismissed = true
        save(changedEpisodes: [episode], inboxDismissedChangedExplicitly: true)
    }

    /// Marks `episode` played and dismisses it from the inbox durably (#546).
    /// Backs the inbox "Mark as played" swipe: setting `.played` alone already
    /// drops it from the membership filter, but also setting `inboxDismissed`
    /// makes the removal sticky, so later marking it unplayed can't resurface a
    /// finished episode. Idempotent.
    func markPlayed(_ episode: Episode) {
        episode.isPlayed = true
        episode.inboxDismissed = true
        // Auto-delete the download once played, when the user opted in (#downloads).
        DownloadCleanup.removeDownloadAfterPlayedIfEnabled(episode, in: context)
        save(
            changedEpisodes: [episode],
            playedChangedExplicitly: true,
            inboxDismissedChangedExplicitly: true
        )
    }

    // MARK: Internals

    private func applyForPodcast(_ podcast: Podcast, now: Date) {
        let candidates = (podcast.episodes ?? [])
            .filter { $0.status == .newEpisode && !$0.inboxDismissed }
            .sorted { ($0.pubDate ?? .distantPast) > ($1.pubDate ?? .distantPast) }

        if let ageHours = podcast.inboxAgeLimitHours {
            let items = candidates.map {
                (id: $0.persistentModelID, pubDate: $0.pubDate, positionSeconds: $0.positionSeconds)
            }
            let dismiss = Set(InboxLogic.idsToDismissForAge(items, ageLimitHours: ageHours, now: now))
            for episode in candidates where dismiss.contains(episode.persistentModelID) {
                episode.inboxDismissed = true
            }
        }

        if let cap = podcast.inboxMaxEpisodes {
            let remaining = candidates.filter { !$0.inboxDismissed }
            let dismiss = Set(InboxLogic.idsToDismissForCount(remaining.map(\.persistentModelID), cap: cap))
            for episode in remaining where dismiss.contains(episode.persistentModelID) {
                episode.inboxDismissed = true
            }
        }
    }

    private func isExcluded(_ podcast: Podcast?, optInOnly: Bool) -> Bool {
        guard let podcast else { return false }
        if optInOnly { return !podcast.inboxIncluded }
        return InboxLogic.isExcluded(inboxExcluded: podcast.inboxExcluded, inboxIncluded: podcast.inboxIncluded)
    }

    private func save(
        changedEpisodes: [Episode] = [],
        playedChangedExplicitly: Bool = false,
        inboxDismissedChangedExplicitly: Bool = false
    ) {
        guard context.hasChanges else { return }
        do {
            try context.save()
            // Inbox membership changed (dismiss / clear / caps) — refresh the
            // tab badge without it having to poll on every save (#736).
            NotificationCenter.default.post(name: .earshotInboxDidChange, object: nil)
            postEpisodeUserStateChanges(
                changedEpisodes,
                playedChangedExplicitly: playedChangedExplicitly,
                inboxDismissedChangedExplicitly: inboxDismissedChangedExplicitly
            )
        } catch {
            AppLog.data.error("Inbox save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
