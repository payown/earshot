import Foundation
import SwiftData

struct ExpirationMaintenanceReport: Sendable, Equatable {
    let expired: Int
    let purged: Int
    let executedStoreWorkOnMainThread: Bool
}

/// Launch-time queue expiration on a private context. The synchronous service
/// remains available for main-context UI actions and focused tests, while root
/// activation uses this entry point so whole-queue scans and file deletion do
/// not compete with VoiceOver's first focus movement.
enum ExpirationMaintenance {
    static func run(
        modelContainer: ModelContainer,
        now: Date = .now
    ) async -> ExpirationMaintenanceReport {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let context = ModelContext(modelContainer)
                continuation.resume(returning: ExpirationWork.run(
                    context: context,
                    now: now,
                    saveOperation: { try $0.save() }
                ))
            }
        }
    }
}

private enum ExpirationWork {
    static func run(
        context: ModelContext,
        now: Date,
        saveOperation: (ModelContext) throws -> Void
    ) -> ExpirationMaintenanceReport {
        var executedOnMain = Thread.isMainThread
        var expired = 0
        var purged = 0
        var stagedFollowedRemoval = false

        let items = (try? context.fetch(FetchDescriptor<QueueItem>())) ?? []
        executedOnMain = executedOnMain || Thread.isMainThread
        for item in items {
            guard !item.isDeleted,
                  item.modelContext == context,
                  let episode = item.episode,
                  !episode.isDeleted,
                  episode.modelContext == context,
                  let podcast = episode.podcast,
                  !podcast.isDeleted,
                  podcast.modelContext == context,
                  let limit = podcast.queueAgeLimitDays,
                  ExpirationLogic.isExpired(
                    addedAt: item.addedAt,
                    ageLimitDays: limit,
                    now: now
                  )
            else { continue }

            if let existing = episode.recentlyExpired {
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
            expired += 1
        }
        if stagedFollowedRemoval {
            PendingCloudQueueMutation.stageOrdering(eventDate: now, in: context)
        }

        let rows = (try? context.fetch(FetchDescriptor<RecentlyExpired>())) ?? []
        executedOnMain = executedOnMain || Thread.isMainThread
        for row in rows where ExpirationLogic.shouldPurge(expiredAt: row.expiredAt, now: now) {
            if let episode = row.episode {
                if let url = episode.localAudioURL {
                    try? FileManager.default.removeItem(at: url)
                }
                episode.downloadPath = nil
                ActiveDownload.setDownloadStatus(.none, on: episode, in: context)
            }
            context.delete(row)
            purged += 1
        }

        guard context.hasChanges else {
            return ExpirationMaintenanceReport(
                expired: 0,
                purged: 0,
                executedStoreWorkOnMainThread: executedOnMain
            )
        }
        do {
            try saveOperation(context)
            return ExpirationMaintenanceReport(
                expired: expired,
                purged: purged,
                executedStoreWorkOnMainThread: executedOnMain || Thread.isMainThread
            )
        } catch {
            context.rollback()
            AppLog.data.error("Expiration save failed: \(error.localizedDescription, privacy: .public)")
            return ExpirationMaintenanceReport(
                expired: 0,
                purged: 0,
                executedStoreWorkOnMainThread: executedOnMain || Thread.isMainThread
            )
        }
    }
}

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
        _ = ExpirationWork.run(
            context: context,
            now: now,
            saveOperation: saveOperation
        )
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
