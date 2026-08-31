import Foundation
import SwiftData

struct ExistingEpisodeFilterReport: Sendable, Equatable {
    let evaluated: Int
    let filtered: Int
    let dismissedFromInbox: Int
    let removedFromQueue: Int
    let retainedCurrentlyPlaying: Int
}

enum EpisodeFilterMaintenanceError: LocalizedError, Sendable {
    case inactiveConfiguration
    case podcastNotFound

    var errorDescription: String? {
        switch self {
        case .inactiveConfiguration:
            "Turn on Filter new episodes and provide at least one valid enabled rule."
        case .podcastNotFound:
            "The podcast could not be found."
        }
    }
}

/// Applies the library-only outcome to existing Inbox and Queue candidates on a
/// background SwiftData executor. Already-dismissed library rows are excluded at
/// the store so a podcast's full historical relationship is never materialized.
@ModelActor
actor EpisodeFilterMaintenance {
    nonisolated static func makeBackground(
        modelContainer: ModelContainer
    ) async -> EpisodeFilterMaintenance {
        await Task.detached(priority: .utility) {
            EpisodeFilterMaintenance(modelContainer: modelContainer)
        }.value
    }

    func applyToExistingEpisodes(
        feedURL: String,
        configuration: EpisodeFilterConfiguration
    ) async throws -> ExistingEpisodeFilterReport {
        guard configuration.isActiveAtIngest else {
            throw EpisodeFilterMaintenanceError.inactiveConfiguration
        }

        let podcast = try PodcastIdentityService(context: modelContext)
            .existingFollowed(feedURL: feedURL)
        guard let podcast else { throw EpisodeFilterMaintenanceError.podcastNotFound }

        let podcastID = podcast.persistentModelID
        let descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate {
                $0.podcast?.persistentModelID == podcastID
                    && ($0.inboxDismissed == false || $0.queueItem != nil)
            }
        )
        let candidates = try modelContext.fetch(descriptor)
        let playingQueueItemID = currentlyPlayingQueueItemID()
        var filtered = 0
        var dismissedFromInbox = 0
        var removedFromQueue = 0
        var retainedCurrentlyPlaying = 0
        var stagedFollowedRemoval = false

        for (index, episode) in candidates.enumerated() {
            try Task.checkCancellation()
            guard !configuration.shouldKeep(
                title: episode.title,
                durationSeconds: episode.durationSeconds
            ) else { continue }
            filtered += 1

            if let queueItem = episode.queueItem,
               queueItem.persistentModelID == playingQueueItemID {
                retainedCurrentlyPlaying += 1
                continue
            }

            if let queueItem = episode.queueItem {
                stagedFollowedRemoval = PendingCloudQueueMutation.stageMembership(
                    episode: episode,
                    isQueued: false,
                    in: modelContext
                ) || stagedFollowedRemoval
                modelContext.delete(queueItem)
                if episode.status == .inQueue { episode.status = .newEpisode }
                removedFromQueue += 1
            }
            if !episode.inboxDismissed {
                episode.inboxDismissed = true
                dismissedFromInbox += 1
            }
            if index.isMultiple(of: 100) { await Task.yield() }
        }

        if removedFromQueue > 0 {
            recompactQueue()
            if stagedFollowedRemoval {
                PendingCloudQueueMutation.stageOrdering(in: modelContext)
            }
        }
        if modelContext.hasChanges { try modelContext.save() }
        return ExistingEpisodeFilterReport(
            evaluated: candidates.count,
            filtered: filtered,
            dismissedFromInbox: dismissedFromInbox,
            removedFromQueue: removedFromQueue,
            retainedCurrentlyPlaying: retainedCurrentlyPlaying
        )
    }

    private func currentlyPlayingQueueItemID() -> PersistentIdentifier? {
        guard let stored = LocalAppSettingIdentity.value(
            for: SettingsKey.lastPlayingEpisodeID,
            in: modelContext
        ), !stored.isEmpty,
        let episode = DownloadTaskKey.episode(matching: stored, in: modelContext)
        else { return nil }
        return episode.queueItem?.persistentModelID
    }

    private func recompactQueue() {
        let descriptor = FetchDescriptor<QueueItem>(sortBy: [SortDescriptor(\.position)])
        let items = ((try? modelContext.fetch(descriptor)) ?? []).filter { $0.episode != nil }
        for (index, item) in items.enumerated() where item.position != index {
            item.position = index
        }
    }
}
