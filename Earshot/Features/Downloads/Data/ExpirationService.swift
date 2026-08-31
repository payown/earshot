import Foundation
import SwiftData

/// Moves stale queue items to Recently Expired and purges Recently Expired rows
/// past the retention window, deleting their downloaded files. Rules live in
/// ``ExpirationLogic``. Run on launch and after queue changes.
@MainActor
final class ExpirationService {
    private let context: ModelContext
    private let saveOperation: (ModelContext) throws -> Void

    init(
        context: ModelContext,
        saveOperation: @escaping (ModelContext) throws -> Void = { try $0.save() }
    ) {
        self.context = context
        self.saveOperation = saveOperation
    }

    func runExpiration(now: Date = .now) {
        expireStale(now: now)
        purgeOld(now: now)
        save()
    }

    /// Recently-expired episodes, most recently expired first (restorable).
    func recentlyExpired() -> [RecentlyExpired] {
        let descriptor = FetchDescriptor<RecentlyExpired>(
            sortBy: [SortDescriptor(\.expiredAt, order: .reverse)]
        )
        return ((try? context.fetch(descriptor)) ?? []).filter { $0.episode != nil }
    }

    /// Restores an expired episode to the back of the queue and removes its
    /// Recently-Expired row.
    func restore(_ episode: Episode) {
        if let row = episode.recentlyExpired {
            context.delete(row)
        }
        QueueRepository(context: context).add(episode)
        save()
    }

    // MARK: Internals

    private func expireStale(now: Date) {
        let items = (try? context.fetch(FetchDescriptor<QueueItem>())) ?? []
        var stagedFollowedRemoval = false
        for item in items {
            // A projection/repair save can invalidate a fetched relationship.
            // Never ask SwiftData for persisted values after its backing model
            // has been deleted or detached from this context.
            guard !item.isDeleted,
                  item.modelContext == context,
                  let episode = item.episode,
                  !episode.isDeleted,
                  episode.modelContext == context,
                  let podcast = episode.podcast,
                  !podcast.isDeleted,
                  podcast.modelContext == context,
                  let limit = podcast.queueAgeLimitDays,
                  ExpirationLogic.isExpired(addedAt: item.addedAt, ageLimitDays: limit, now: now)
            else { continue }

            // Queue and Recently Expired are independently synchronized. An
            // interrupted or older write can therefore leave both one-to-one
            // relationships attached to the same Episode. Creating a second
            // RecentlyExpired row makes SwiftData update that occupied inverse
            // relationship and assert. Reuse the live row as a repair instead.
            if let existing = episode.recentlyExpired {
                // An occupied inverse must never fall through to insertion,
                // even if its destination was invalidated underneath this
                // context. Leave that item untouched for the next clean fetch.
                guard !existing.isDeleted, existing.modelContext == context else {
                    AppLog.data.error("Skipped expiration with an invalid existing relationship")
                    continue
                }
                existing.expiredAt = now
            } else {
                context.insert(RecentlyExpired(episode: episode, expiredAt: now))
            }
            stagedFollowedRemoval = PendingCloudQueueMutation.stageMembership(
                episode: episode,
                isQueued: false,
                eventDate: now,
                in: context
            ) || stagedFollowedRemoval
            episode.status = .expired
            context.delete(item)
        }
        if stagedFollowedRemoval {
            PendingCloudQueueMutation.stageOrdering(eventDate: now, in: context)
        }
    }

    private func purgeOld(now: Date) {
        let rows = (try? context.fetch(FetchDescriptor<RecentlyExpired>())) ?? []
        for row in rows where ExpirationLogic.shouldPurge(expiredAt: row.expiredAt, now: now) {
            if let episode = row.episode { deleteDownloadedFile(episode) }
            context.delete(row)
        }
    }

    private func deleteDownloadedFile(_ episode: Episode) {
        // Delete via the RESOLVED URL so a legacy absolute downloadPath from
        // before an app update still removes the real file (#575).
        if let url = episode.localAudioURL {
            try? FileManager.default.removeItem(at: url)
        }
        episode.downloadPath = nil
        // Drops any ActiveDownload row in the same save (#701): .none is
        // terminal, so an expired episode must not stay visible to download
        // reconciliation.
        ActiveDownload.setDownloadStatus(.none, on: episode, in: context)
    }

    private func save() {
        guard context.hasChanges else { return }
        do {
            try saveOperation(context)
        } catch {
            context.rollback()
            AppLog.data.error("Expiration save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
