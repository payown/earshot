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
    @concurrent
    static func run(
        modelContainer: ModelContainer,
        now: Date = .now
    ) async -> ExpirationMaintenanceReport {
        guard !Task.isCancelled else {
            return ExpirationMaintenanceReport(
                expired: 0,
                purged: 0,
                executedStoreWorkOnMainThread: false
            )
        }
        let context = ModelContext(modelContainer)
        return ExpirationWork.run(
            context: context,
            now: now,
            saveOperation: { try $0.save() }
        )
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

        var rows = ((try? context.fetch(FetchDescriptor<RecentlyExpired>())) ?? [])
            .filter { ExpirationLogic.shouldPurge(expiredAt: $0.expiredAt, now: now) }
        executedOnMain = executedOnMain || Thread.isMainThread
        // Episode download values are transient and may not be hydrated on a
        // refaulted model. Read the device-local rows once, before modifying
        // anything, so candidate files and rollback use the durable state.
        var localRows: [EpisodeLocalKey: [LocalEpisodeState]] = [:]
        if !rows.isEmpty {
            do {
                localRows = Dictionary(grouping: try context.fetch(FetchDescriptor<LocalEpisodeState>())) {
                    EpisodeLocalKey(feedURL: $0.podcastFeedURL, guid: $0.episodeGUID)
                }
            } catch {
                AppLog.data.error("Expiration download ownership fetch failed: \(error.localizedDescription, privacy: .public)")
                rows = []
            }
        }
        let downloadSnapshots = rows.compactMap(\.episode).map { episode in
            let stored = LocalStateStore.key(for: episode).flatMap { localRows[$0]?.first }
            return (episode: episode, status: stored?.downloadStatus ?? episode.downloadStatus,
                    path: stored?.downloadPath ?? episode.downloadPath)
        }
        let purgedKeys = Set(downloadSnapshots.compactMap { LocalStateStore.key(for: $0.episode) })
        let storedFiles = purgedKeys.flatMap { localRows[$0] ?? [] }.compactMap {
            DownloadPaths.storedFileName($0.downloadPath)
        }
        let candidateFiles = Set(storedFiles + downloadSnapshots.compactMap { DownloadPaths.storedFileName($0.path) })
        for row in rows {
            if let episode = row.episode {
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
            if !candidateFiles.isEmpty,
               let retainedFiles = try? DownloadPaths.referencedFileNames(excluding: [], in: context) {
                for name in candidateFiles where !retainedFiles.contains(name) {
                    try? DownloadPaths.removeFile(named: name)
                }
            }
            return ExpirationMaintenanceReport(
                expired: expired,
                purged: purged,
                executedStoreWorkOnMainThread: executedOnMain || Thread.isMainThread
            )
        } catch {
            context.rollback()
            // Download state has a process-local projection as well as its
            // persisted row. Restore that projection after rollback so the UI
            // continues to show the saved download and its intact file.
            for snapshot in downloadSnapshots {
                snapshot.episode.downloadPath = snapshot.path
                snapshot.episode.downloadStatus = snapshot.status
            }
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
