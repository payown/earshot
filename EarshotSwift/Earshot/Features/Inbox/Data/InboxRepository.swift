import Foundation
import SwiftData

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
    /// Fetches only non-dismissed episodes via a `#Predicate` so the dismissed
    /// backlog never materializes — the query stays cheap even with thousands of
    /// episodes in the store, instead of fetching every row and filtering in
    /// memory on the main actor (which made episode-heavy operations jank and
    /// starve VoiceOver). Status and per-podcast exclusion are applied in-memory
    /// on the already-small candidate set. (#396)
    func inboxEpisodes() -> [Episode] {
        var descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate { $0.inboxDismissed == false },
            sortBy: [SortDescriptor(\.pubDate, order: .reverse)]
        )
        descriptor.relationshipKeyPathsForPrefetching = [\Episode.podcast]
        let candidates = (try? context.fetch(descriptor)) ?? []
        return inbox(from: candidates)
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
        return candidates.filter { $0.status == .newEpisode && !isExcluded($0.podcast, optInOnly: optInOnly) }
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
        for episode in inboxEpisodes() { episode.inboxDismissed = true }
        save()
    }

    // MARK: Internals

    private func applyForPodcast(_ podcast: Podcast, now: Date) {
        let candidates = podcast.episodes
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
        } catch {
            AppLog.data.error("Inbox save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
