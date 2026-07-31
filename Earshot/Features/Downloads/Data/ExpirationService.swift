import Foundation
import SwiftData

/// Moves stale queue items to Recently Expired and purges Recently Expired rows
/// past the retention window, deleting their downloaded files. Rules live in
/// ``ExpirationLogic``. Run on launch and after queue changes.
@MainActor
final class ExpirationService {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
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
        for item in items {
            guard let episode = item.episode,
                  let limit = episode.podcast?.queueAgeLimitDays,
                  ExpirationLogic.isExpired(addedAt: item.addedAt, ageLimitDays: limit, now: now)
            else { continue }
            context.insert(RecentlyExpired(episode: episode, expiredAt: now))
            episode.status = .expired
            context.delete(item)
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
            try context.save()
        } catch {
            AppLog.data.error("Expiration save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
