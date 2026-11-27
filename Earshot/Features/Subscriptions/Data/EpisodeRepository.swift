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
    /// not materialize the podcast's complete inverse relationship. Take a
    /// stable snapshot of the store's identifiers away from the main actor,
    /// then resolve and save at most 100 current models at a time. New rows
    /// inserted after the snapshot are not part of this operation.
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
        // Temporary IDs can change after the first save. Preserve the existing
        // pending-edit behavior rather than adding such IDs to the snapshot.
        if context.hasChanges {
            return await markAllPlayedFromLivePages(podcastID, deleteAfterPlayed: deleteAfterPlayed)
        }
        let identifiers: [PersistentIdentifier]
        do {
            identifiers = try await Self.markAllIdentifiers(in: context.container, podcastID: podcastID)
        } catch {
            AppLog.data.error("Episode bulk identifier snapshot failed: \(error.localizedDescription, privacy: .public)")
            return await markAllPlayedFromLivePages(podcastID, deleteAfterPlayed: deleteAfterPlayed)
        }

        var changedCount = 0
        for start in stride(from: 0, to: identifiers.count, by: Self.batchSize) {
            let end = min(start + Self.batchSize, identifiers.count)
            let ids = Array(identifiers[start..<end])
            let candidates: [Episode]
            do {
                candidates = try markAllBatch(ids, podcastID: podcastID)
            } catch {
                AppLog.data.error("Episode bulk fetch failed: \(error.localizedDescription, privacy: .public)")
                break
            }
            // Work on current models rather than trusting an earlier played
            // bit. Missing or reassigned IDs are not touched.
            guard let changed = saveMarkAllBatch(candidates, deleteAfterPlayed: deleteAfterPlayed) else { break }
            changedCount += changed
            // An entirely played page still used the main actor for a fetch.
            await Task.yield()
        }
        return finishMarkAll(changedCount)
    }

    private nonisolated static func markAllIdentifiers(
        in container: ModelContainer, podcastID: PersistentIdentifier
    ) async throws -> [PersistentIdentifier] {
        try await Task.detached(priority: .userInitiated) {
            let readContext = ModelContext(container)
            var descriptor = FetchDescriptor<Episode>(
                predicate: #Predicate { $0.podcast?.persistentModelID == podcastID },
                sortBy: [SortDescriptor(\.guid)]
            )
            descriptor.includePendingChanges = false
            return try readContext.fetchIdentifiers(descriptor)
        }.value
    }

    private func markAllBatch(_ ids: [PersistentIdentifier], podcastID: PersistentIdentifier) throws -> [Episode] {
        let descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate { ids.contains($0.persistentModelID) && $0.podcast?.persistentModelID == podcastID },
            sortBy: [SortDescriptor(\.guid)]
        )
        do {
            return try context.fetch(descriptor)
        } catch {
            // Preserve progress on SwiftData releases that cannot translate a
            // list of identifiers. Resolve exact rows; never fault a stale ID.
            return try ids.compactMap { id in
                var single = FetchDescriptor<Episode>(predicate: #Predicate {
                    $0.persistentModelID == id && $0.podcast?.persistentModelID == podcastID
                })
                single.fetchLimit = 1
                return try context.fetch(single).first
            }
        }
    }

    private func markAllPlayedFromLivePages(
        _ podcastID: PersistentIdentifier, deleteAfterPlayed: Bool
    ) async -> Int {
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

            guard let changed = saveMarkAllBatch(candidates, deleteAfterPlayed: deleteAfterPlayed) else { break }
            if changed == 0 {
                if candidates.count < Self.batchSize { break }
                continue
            }

            changedCount += changed
            // The repository is main-context-bound, but yielding between small
            // durable batches lets VoiceOver and UI events run during a very
            // large podcast operation instead of monopolizing the main actor.
            await Task.yield()
        }

        return finishMarkAll(changedCount)
    }

    private func saveMarkAllBatch(_ candidates: [Episode], deleteAfterPlayed: Bool) -> Int? {
        let unplayed = candidates.filter { !$0.isPlayed }
        guard !unplayed.isEmpty else { return 0 }
        let queueChanged: Bool
        do {
            queueChanged = try QueueRepository(context: context).stageManualPlayedQueuePolicy(for: unplayed)
        } catch {
            AppLog.data.error("Episode bulk Queue lookup failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let ownership = deleteAfterPlayed ? DownloadCleanup.bulkOwnership(for: unplayed, in: context) : nil
        for episode in unplayed {
            episode.isPlayed = true
            episode.inboxDismissed = InboxLogic.inboxDismissedAfterPlayedChange(
                nowPlayed: true, wasDismissed: episode.inboxDismissed
            )
            if deleteAfterPlayed {
                DownloadCleanup.removeDownloadFileAndState(episode, in: context, ownership: ownership)
            }
        }
        return save(changedEpisodes: unplayed, notifyInbox: false, notifyQueue: queueChanged)
            ? unplayed.count : nil
    }

    private func finishMarkAll(_ changedCount: Int) -> Int {
        if changedCount > 0 {
            NotificationCenter.default.post(name: .earshotInboxDidChange, object: nil)
        }
        return changedCount
    }

    /// Marks only the selected episodes from this podcast. The caller can
    /// select identities from unloaded pages, then exempt individual episodes
    /// before confirming. Already-played rows keep their original timestamps.
    @discardableResult
    func markSelectedPlayed(in podcast: Podcast, ids: Set<PersistentIdentifier>) async -> Int {
        await setSelectedPlayed(in: podcast, ids: ids, played: true)
    }

    /// Restores selected played episodes to unplayed without returning them to
    /// the Inbox after they were already dismissed there.
    @discardableResult
    func markSelectedUnplayed(in podcast: Podcast, ids: Set<PersistentIdentifier>) async -> Int {
        await setSelectedPlayed(in: podcast, ids: ids, played: false)
    }

    private func setSelectedPlayed(
        in podcast: Podcast, ids: Set<PersistentIdentifier>, played: Bool
    ) async -> Int {
        let podcastID = podcast.persistentModelID
        let deleteAfterPlayed = played && DownloadCleanup.deleteAfterPlayedEnabled(context)
        let identifiers = Array(ids)
        var changedCount = 0

        for start in stride(from: 0, to: identifiers.count, by: Self.batchSize) {
            let end = min(start + Self.batchSize, identifiers.count)
            let selected = identifiers[start..<end].compactMap { context.model(for: $0) as? Episode }
                .filter { !$0.isDeleted && $0.modelContext == context &&
                    $0.podcast?.persistentModelID == podcastID && $0.isPlayed != played }
            guard !selected.isEmpty else {
                await Task.yield()
                continue
            }
            let ownership = deleteAfterPlayed ? DownloadCleanup.bulkOwnership(for: selected, in: context) : nil
            let priorCompletions = played ? [] : selected.map { ($0, $0.playedAt) }
            let queueChanged: Bool
            do {
                queueChanged = played
                    ? try QueueRepository(context: context).stageManualPlayedQueuePolicy(for: selected) : false
            } catch {
                AppLog.data.error("Selected episode Queue lookup failed: \(error.localizedDescription, privacy: .public)")
                break
            }
            for episode in selected {
                episode.isPlayed = played
                episode.inboxDismissed = InboxLogic.inboxDismissedAfterPlayedChange(
                    nowPlayed: played, wasDismissed: episode.inboxDismissed
                )
                if deleteAfterPlayed {
                    DownloadCleanup.removeDownloadFileAndState(episode, in: context, ownership: ownership)
                }
            }
            guard save(changedEpisodes: selected, notifyInbox: false, notifyQueue: queueChanged) else { break }
            for (episode, completedAt) in priorCompletions {
                PlayerService.discardStaleLivePositionAfterMarkUnplayed(
                    episode, completedAt: completedAt
                )
            }
            changedCount += selected.count
            await Task.yield()
        }

        if changedCount > 0 {
            NotificationCenter.default.post(name: .earshotInboxDidChange, object: nil)
        }
        return changedCount
    }

    @discardableResult
    private func save(
        changedEpisodes: [Episode], notifyInbox: Bool = true, notifyQueue: Bool = false
    ) -> Bool {
        guard context.hasChanges else { return false }
        PendingCloudPlayedMutation.stage(changedEpisodes, in: context)
        do {
            try ListeningPlacesEventJournal.stageCurrentLocalMutationsBeforeSave(in: context)
            try context.save()
            onSave?()
            if notifyQueue {
                QueueRepository(context: context).postCommittedCatalogQueueChange()
            }
            if notifyInbox {
                NotificationCenter.default.post(name: .earshotInboxDidChange, object: nil)
            }
            postEpisodeUserStateChanges(
                changedEpisodes,
                playedChangedExplicitly: true
            )
            return true
        } catch {
            context.rollback()
            AppLog.data.error("Episode bulk save failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
