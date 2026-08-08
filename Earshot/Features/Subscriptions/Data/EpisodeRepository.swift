import Foundation
import SwiftData

/// Bulk episode operations that span a whole podcast's episode list rather than
/// a single episode. Currently just "Mark all as played" (#640), backing the
/// podcast episode list's batch action for shows with hundreds or thousands of
/// episodes.
@MainActor
final class EpisodeRepository {
    private let context: ModelContext

    /// Test-only hook, invoked exactly once right after a successful batched
    /// `context.save()` -- never invoked when a save is skipped because nothing
    /// changed. Lets tests assert "one save, not N" directly instead of only
    /// inferring it from end state, mirroring
    /// `SubscriptionRepository`'s `onMerge` hook (see
    /// `OPMLBulkImportTests.testBulkImportReconcilesMainContextExactlyOnce`).
    /// Production call sites omit it.
    private let onSave: (() -> Void)?

    init(context: ModelContext, onSave: (() -> Void)? = nil) {
        self.context = context
        self.onSave = onSave
    }

    /// Marks every currently-unplayed episode of `podcast` as played and returns
    /// how many were actually changed (#640). Large lists (1000+ episodes) must
    /// not mutate-and-save one row at a time on the main actor -- every episode
    /// is mutated in memory first, then `context.save()` runs exactly once for
    /// the whole operation (skipped entirely when there's nothing to change, so
    /// a fully-played podcast never dirties the context for a no-op).
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
    func markAllPlayed(in podcast: Podcast) -> Int {
        let unplayed = (podcast.episodes ?? []).filter { !$0.isPlayed }
        guard !unplayed.isEmpty else { return 0 }

        // Gate the "delete downloads after played" setting once for the whole
        // batch rather than refetching it per episode.
        let deleteAfterPlayed = DownloadCleanup.deleteAfterPlayedEnabled(context)
        for episode in unplayed {
            episode.isPlayed = true
            episode.inboxDismissed = InboxLogic.inboxDismissedAfterPlayedChange(
                nowPlayed: true, wasDismissed: episode.inboxDismissed
            )
            if deleteAfterPlayed {
                DownloadCleanup.removeDownloadFileAndState(episode, in: context)
            }
        }
        save(changedEpisodes: unplayed)
        return unplayed.count
    }

    private func save(changedEpisodes: [Episode]) {
        guard context.hasChanges else { return }
        do {
            try context.save()
            onSave?()
            // Marking episodes played/unplayed changes inbox membership — nudge
            // the tab badge to recompute (#736).
            NotificationCenter.default.post(name: .earshotInboxDidChange, object: nil)
            postEpisodeUserStateChanges(
                changedEpisodes,
                playedChangedExplicitly: true
            )
        } catch {
            AppLog.data.error("Episode bulk save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
