import Foundation
import SwiftData

/// Bulk episode operations that span a whole podcast's episode list rather than
/// a single episode. Currently just "Mark all as played" (#640), backing the
/// podcast episode list's batch action for shows with hundreds or thousands of
/// episodes.
@MainActor
final class EpisodeRepository {
    static let batchSize = 100

    private let context: ModelContext

    /// Test-only hook, invoked after each successful bounded-batch
    /// `context.save()` -- never invoked when a save is skipped because nothing
    /// changed. Lets tests verify save frequency without inferring it only from
    /// final model state. Production call sites omit it.
    private let onSave: (() -> Void)?

    init(context: ModelContext, onSave: (() -> Void)? = nil) {
        self.context = context
        self.onSave = onSave
    }

    /// Marks every currently-unplayed episode of `podcast` as played and returns
    /// how many were actually changed (#640). Large lists (1000+ episodes) must
    /// not materialize the podcast's complete inverse relationship. The store is
    /// queried in 100-row podcast-scoped batches and each bounded mutation is
    /// saved before the next page is fetched.
    ///
    /// Already-played episodes are left untouched so their `playedAt` is never
    /// overwritten with `.now`, which also keeps the returned count meaningful:
    /// it's the number of episodes that actually flipped from unplayed to
    /// played, not the podcast's total episode count.
    ///
    /// Inbox dismissal mirrors the single-episode mark-played path
    /// (`InboxLogic.inboxDismissedAfterPlayedChange`, also used by
    /// `EpisodeActionsBuilder`'s Quick Action / rotor runner), so a bulk mark
    /// played dismisses episodes from the inbox exactly like marking each one
    /// played individually would.
    @discardableResult
    func markAllPlayed(in podcast: Podcast) async -> Int {
        let podcastID = podcast.persistentModelID
        let deleteAfterPlayed = DownloadCleanup.deleteAfterPlayedEnabled(context)
        var changedCount = 0
        var offset = 0

        while true {
            var descriptor = FetchDescriptor<Episode>(predicate: #Predicate {
                $0.podcast?.persistentModelID == podcastID
            })
            descriptor.sortBy = [SortDescriptor(\Episode.guid, order: .forward)]
            descriptor.fetchOffset = offset
            descriptor.fetchLimit = Self.batchSize

            let candidates: [Episode]
            do {
                candidates = try context.fetch(descriptor)
            } catch {
                AppLog.data.error("Episode bulk fetch failed: \(error.localizedDescription, privacy: .public)")
                break
            }
            guard !candidates.isEmpty else { break }
            offset += candidates.count

            let unplayed = candidates.filter { !$0.isPlayed }
            guard !unplayed.isEmpty else {
                if candidates.count < Self.batchSize { break }
                continue
            }

            for episode in unplayed {
                episode.isPlayed = true
                episode.inboxDismissed = InboxLogic.inboxDismissedAfterPlayedChange(
                    nowPlayed: true, wasDismissed: episode.inboxDismissed
                )
                if deleteAfterPlayed {
                    DownloadCleanup.removeDownloadFileAndState(episode, in: context)
                }
            }
            guard save(changedEpisodes: unplayed, notifyInbox: false) else { break }
            changedCount += unplayed.count
            // The repository is main-context-bound, but yielding between small
            // durable batches lets VoiceOver and UI events run during a very
            // large podcast operation instead of monopolizing the main actor.
            await Task.yield()
        }

        if changedCount > 0 {
            NotificationCenter.default.post(name: .earshotInboxDidChange, object: nil)
        }
        return changedCount
    }

    @discardableResult
    private func save(changedEpisodes: [Episode], notifyInbox: Bool = true) -> Bool {
        guard context.hasChanges else { return false }
        do {
            try context.save()
            onSave?()
            if notifyInbox {
                NotificationCenter.default.post(name: .earshotInboxDidChange, object: nil)
            }
            postEpisodeUserStateChanges(
                changedEpisodes,
                playedChangedExplicitly: true
            )
            return true
        } catch {
            AppLog.data.error("Episode bulk save failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
