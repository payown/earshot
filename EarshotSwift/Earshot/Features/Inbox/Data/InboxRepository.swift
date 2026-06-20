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
    func inboxEpisodes() -> [Episode] {
        let optInOnly = settings.bool(SettingsKey.inboxOptInOnly, default: SettingsDefault.inboxOptInOnly)
        let all = (try? context.fetch(FetchDescriptor<Episode>())) ?? []
        return all
            .filter { $0.status == .newEpisode && !$0.inboxDismissed && !isExcluded($0.podcast, optInOnly: optInOnly) }
            .sorted { ($0.pubDate ?? .distantPast) > ($1.pubDate ?? .distantPast) }
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
