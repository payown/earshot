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
    // filter to `.newEpisode` directly. But a played episode always carries a
    // non-nil `playedAt` (see `Episode.isPlayed`'s setter), and played episodes
    // are the bucket that grows without bound: `markCurrentEpisodePlayed` never
    // dismisses them, so every episode ever finished stays `inboxDismissed ==
    // false` forever and bloats ``normal``/``optInOnly``. Adding `playedAt ==
    // nil` (a plain optional-`Date` comparison the store executes correctly)
    // trims that unbounded played history out of the fetch. The result is a small
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
        return ((try? context.fetch(descriptor)) ?? []).filter { $0.status == .newEpisode }
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
    /// 10k rows, ~3s at 100k) because finished episodes are never dismissed, so
    /// the non-dismissed set grows without bound over listening history. Once
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
        return candidates.filter { $0.status == .newEpisode }.count
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
            !isExcluded($0.podcast, optInOnly: optInOnly)
        }
    }

    /// Applies per-podcast age + count caps across all included podcasts. Safe to
    /// call after a refresh or an include/exclude change.
    func applyLimits(now: Date = .now) {
        let optInOnly = settings.bool(SettingsKey.inboxOptInOnly, default: SettingsDefault.inboxOptInOnly)
        let podcasts = (try? context.fetch(FetchDescriptor<Podcast>())) ?? []
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
        for episode in episodes { episode.inboxDismissed = true }
        save()
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
        save()
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

    private func save() {
        guard context.hasChanges else { return }
        do {
            try context.save()
            // Inbox membership changed (dismiss / clear / caps) — refresh the
            // tab badge without it having to poll on every save (#736).
            NotificationCenter.default.post(name: .earshotInboxDidChange, object: nil)
        } catch {
            AppLog.data.error("Inbox save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
