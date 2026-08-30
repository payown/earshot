import Foundation
import SwiftData

struct CatalogEpisodeIdentity: Equatable, Sendable {
    let feedURL: String
    let guid: String
}

enum CatalogEpisodeQueueOutcome: Equatable, Sendable {
    case added
    case alreadyQueued
    case movedNext
    case alreadyNext
    case removed
    case alreadyRemoved
}

enum CatalogEpisodeQueueFailure: Error, Equatable, Sendable {
    case invalidFeedURL
    case missingPodcastTitle
    case missingGUID
    case missingAudioURL
    case cancelled
    case persistenceFailed
}

/// The repository is MainActor-isolated to share the same global queue-write
/// serialization as every existing ``QueueRepository`` caller. After awaiting
/// the per-feed identity gate, it performs deterministic upsert, queue stage,
/// and the one durable save without another suspension. The context is fresh for
/// each operation and no SwiftData model enters or leaves this boundary.
@MainActor
final class CatalogEpisodeQueueRepository {
    typealias SaveOperation = (ModelContext) throws -> Void
    typealias CleanupRowsOperation = (EpisodeLocalKey, ModelContext) throws -> [LocalEpisodeState]

    private struct MaterializationInput {
        let canonicalFeedURL: String
        let podcastTitle: String
        let podcastArtworkURL: String?
        let guid: String
        let title: String
        let audioURL: String
        let episodeDescription: String?
        let durationSeconds: Int?
        let pubDate: Date?
        let artworkURL: String?
        let episodeNumber: Int?
        let seasonNumber: Int?
        let chapterURL: String?
        let transcriptURL: String?
    }

    private let container: ModelContainer
    private let notificationCenter: NotificationCenter
    private let saveOperation: SaveOperation
    private let cleanupSaveOperation: SaveOperation
    private let cleanupRowsOperation: CleanupRowsOperation

    init(
        container: ModelContainer,
        notificationCenter: NotificationCenter = .default,
        saveOperation: @escaping SaveOperation = { try $0.save() },
        cleanupSaveOperation: @escaping SaveOperation = { try $0.save() },
        cleanupRowsOperation: @escaping CleanupRowsOperation = LocalStateStore.episodeRowsThrowing
    ) {
        self.container = container
        self.notificationCenter = notificationCenter
        self.saveOperation = saveOperation
        self.cleanupSaveOperation = cleanupSaveOperation
        self.cleanupRowsOperation = cleanupRowsOperation
    }

    func add(
        _ preview: PreviewEpisode
    ) async -> Result<CatalogEpisodeQueueOutcome, CatalogEpisodeQueueFailure> {
        switch materializationInput(from: preview) {
        case let .failure(failure): return .failure(failure)
        case let .success(input):
            return await withFeedIdentityLock(input.canonicalFeedURL) { context in
                let upserted = try upsert(input, in: context)
                let queue = QueueRepository(context: context)
                let stage = try queue.stageCatalogAdd(upserted.episode)
                try saveOperation(context)
                if stage.queueChanged || upserted.queuedPresentationChanged {
                    queue.postCommittedCatalogQueueChange(to: notificationCenter)
                }
                return stage.intentChanged ? .added : .alreadyQueued
            }
        }
    }

    func playNext(
        _ preview: PreviewEpisode,
        after current: CatalogEpisodeIdentity?
    ) async -> Result<CatalogEpisodeQueueOutcome, CatalogEpisodeQueueFailure> {
        switch materializationInput(from: preview) {
        case let .failure(failure): return .failure(failure)
        case let .success(input):
            return await withFeedIdentityLock(input.canonicalFeedURL) { context in
                let upserted = try upsert(input, in: context)
                let currentEpisode = try current.flatMap {
                    try queuedEpisode(matching: $0, in: context)
                }
                let queue = QueueRepository(context: context)
                let stage = try queue.stageCatalogPlayNext(upserted.episode, after: currentEpisode)
                try saveOperation(context)
                if stage.queueChanged || upserted.queuedPresentationChanged {
                    queue.postCommittedCatalogQueueChange(to: notificationCenter)
                }
                return stage.intentChanged ? .movedNext : .alreadyNext
            }
        }
    }

    func remove(
        _ identity: CatalogEpisodeIdentity
    ) async -> Result<CatalogEpisodeQueueOutcome, CatalogEpisodeQueueFailure> {
        switch identityInput(from: identity) {
        case let .failure(failure): return .failure(failure)
        case let .success(validated):
            return await withFeedIdentityLock(validated.feedURL) { context in
                let queue = QueueRepository(context: context)
                let stage = try queue.stageCatalogCancelFromQueue(
                    feedURL: validated.feedURL,
                    guid: validated.guid
                )
                guard stage.mutation.queueChanged else { return .alreadyRemoved }
                try saveOperation(context)
                performDownloadCleanup(stage.downloadCleanupAfterCommit)
                if stage.mutation.queueChanged {
                    queue.postCommittedCatalogQueueChange(to: notificationCenter)
                }
                return stage.mutation.intentChanged ? .removed : .alreadyRemoved
            }
        }
    }

    /// Download state is in the device-local store, which cannot participate in
    /// a distributed transaction with the mirrored queue store. Clean it only
    /// after the queue commit; failure preserves the recoverable file/state and
    /// cannot turn a durable queue removal into a false failure result.
    private func performDownloadCleanup(_ cleanup: QueueRepository.CatalogDownloadCleanup?) {
        guard let cleanup else { return }
        let context = ModelContext(container)
        context.autosaveEnabled = false
        do {
            for row in try cleanupRowsOperation(cleanup.key, context) {
                if row.volumeBoost == nil {
                    context.delete(row)
                } else {
                    row.downloadStatus = .none
                    row.downloadPath = nil
                }
            }
            try cleanupSaveOperation(context)
            LocalRuntimeState.shared.setEpisode(cleanup.episodeID, status: .none, path: nil)
            if let fileURL = cleanup.fileURL { try? FileManager.default.removeItem(at: fileURL) }
        } catch {
            context.rollback()
            AppLog.player.error(
                "Post-commit catalog download cleanup failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// The final await happens before the synchronous transaction body. This is
    /// what makes different-feed operations safe too: once resumed, MainActor
    /// runs the queue fetch/stage/save interval without interleaving another
    /// existing MainActor queue writer.
    private func withFeedIdentityLock(
        _ canonicalFeedURL: String,
        operation: (ModelContext) throws -> CatalogEpisodeQueueOutcome
    ) async -> Result<CatalogEpisodeQueueOutcome, CatalogEpisodeQueueFailure> {
        await PodcastIdentityWriteGate.shared.acquire(feedURLs: [canonicalFeedURL])
        if Task.isCancelled {
            await PodcastIdentityWriteGate.shared.release(feedURLs: [canonicalFeedURL])
            return .failure(.cancelled)
        }
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let result: Result<CatalogEpisodeQueueOutcome, CatalogEpisodeQueueFailure>
        do {
            result = .success(try operation(context))
        } catch {
            context.rollback()
            AppLog.player.error(
                "Catalog queue transaction failed: \(error.localizedDescription, privacy: .public)"
            )
            result = .failure(.persistenceFailed)
        }
        await PodcastIdentityWriteGate.shared.release(feedURLs: [canonicalFeedURL])
        return result
    }

    private func materializationInput(
        from preview: PreviewEpisode
    ) -> Result<MaterializationInput, CatalogEpisodeQueueFailure> {
        let canonicalFeedURL = FeedURLIdentity.canonical(preview.podcastFeedURL)
        guard !canonicalFeedURL.isEmpty else { return .failure(.invalidFeedURL) }
        let podcastTitle = preview.podcastTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !podcastTitle.isEmpty else { return .failure(.missingPodcastTitle) }
        let guid = preview.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !guid.isEmpty else { return .failure(.missingGUID) }
        let audioURL = preview.audioURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !audioURL.isEmpty else { return .failure(.missingAudioURL) }
        return .success(MaterializationInput(
            canonicalFeedURL: canonicalFeedURL,
            podcastTitle: podcastTitle,
            podcastArtworkURL: preview.podcastArtworkURL,
            guid: guid,
            title: preview.title,
            audioURL: audioURL,
            episodeDescription: preview.episodeDescription,
            durationSeconds: preview.durationSeconds,
            pubDate: preview.pubDate,
            artworkURL: preview.artworkURL,
            episodeNumber: preview.episodeNumber,
            seasonNumber: preview.seasonNumber,
            chapterURL: preview.chapterURL,
            transcriptURL: preview.transcriptURL
        ))
    }

    private func identityInput(
        from identity: CatalogEpisodeIdentity
    ) -> Result<CatalogEpisodeIdentity, CatalogEpisodeQueueFailure> {
        let feedURL = FeedURLIdentity.canonical(identity.feedURL)
        guard !feedURL.isEmpty else { return .failure(.invalidFeedURL) }
        guard !identity.guid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.missingGUID)
        }
        return .success(CatalogEpisodeIdentity(
            feedURL: feedURL,
            guid: identity.guid.trimmingCharacters(in: .whitespacesAndNewlines)
        ))
    }

    private func upsert(
        _ input: MaterializationInput,
        in context: ModelContext
    ) throws -> (episode: Episode, queuedPresentationChanged: Bool) {
        let identity = PodcastIdentityService(context: context)
        let podcast: Podcast
        if let existing = try identity.existingAnyState(feedURL: input.canonicalFeedURL) {
            podcast = existing
            // A Discovery queue race must never overwrite followed ownership or
            // its refresh-authored show metadata.
            if existing.isCatalogOnly {
                existing.title = input.podcastTitle
                existing.artworkURL = input.podcastArtworkURL
            }
        } else {
            podcast = Podcast(
                feedURL: input.canonicalFeedURL,
                title: input.podcastTitle,
                artworkURL: input.podcastArtworkURL,
                subscriptionStateRaw: PodcastSubscriptionState.catalogOnly.rawValue
            )
            context.insert(podcast)
        }

        let guid = input.guid
        let episode: Episode
        var queuedPresentationChanged = false
        // Do not run destructive legacy repair inside a user action. Repair's
        // required pre-delete player notification cannot be rolled back if this
        // transaction later fails. Prefer a queued legacy survivor, then the
        // oldest/stable row; the catalog path itself never creates another.
        let matches = try context.fetch(
            FetchDescriptor<Episode>(predicate: #Predicate { $0.guid == guid })
        ).filter {
            $0.podcast.map {
                FeedURLIdentity.matches($0.feedURL, input.canonicalFeedURL)
            } == true
        }.sorted(by: episodeUpsertOrder)
        if let existing = matches.first {
            episode = existing
            // Converge the one survivor used by this action on the same
            // followed-first Podcast identity without deleting legacy rows.
            let oldPodcastID = existing.podcast?.persistentModelID
            existing.podcast = podcast
            queuedPresentationChanged = existing.queueItem != nil
                && oldPodcastID != podcast.persistentModelID
            refreshEpisodeMetadata(existing, from: input)
        } else {
            episode = Episode(
                guid: input.guid,
                title: input.title,
                audioURL: input.audioURL,
                episodeDescription: input.episodeDescription,
                durationSeconds: input.durationSeconds,
                pubDate: input.pubDate,
                artworkURL: input.artworkURL,
                episodeNumber: input.episodeNumber,
                seasonNumber: input.seasonNumber,
                chapterURL: input.chapterURL,
                transcriptURL: input.transcriptURL,
                inboxDismissed: true
            )
            episode.podcast = podcast
            context.insert(episode)
        }
        return (episode, queuedPresentationChanged)
    }

    private func episodeUpsertOrder(_ lhs: Episode, _ rhs: Episode) -> Bool {
        if (lhs.queueItem != nil) != (rhs.queueItem != nil) { return lhs.queueItem != nil }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return String(describing: lhs.persistentModelID)
            < String(describing: rhs.persistentModelID)
    }

    private func refreshEpisodeMetadata(_ episode: Episode, from input: MaterializationInput) {
        episode.title = input.title
        episode.audioURL = input.audioURL
        episode.episodeDescription = input.episodeDescription
        episode.durationSeconds = input.durationSeconds
        episode.pubDate = input.pubDate
        episode.artworkURL = input.artworkURL
        episode.episodeNumber = input.episodeNumber
        episode.seasonNumber = input.seasonNumber
        episode.chapterURL = input.chapterURL
        episode.transcriptURL = input.transcriptURL
    }

    /// Resolve only a real queued row, including legacy feed spellings, so a
    /// transient or unavailable player identity naturally anchors Play Next at
    /// the front.
    private func queuedEpisode(
        matching identity: CatalogEpisodeIdentity,
        in context: ModelContext
    ) throws -> Episode? {
        let items = try context.fetch(
            FetchDescriptor<QueueItem>(sortBy: [SortDescriptor(\.position)])
        )
        return items.compactMap(\.episode).first {
            $0.guid == identity.guid
                && $0.podcast.map {
                    FeedURLIdentity.matches($0.feedURL, identity.feedURL)
                } == true
        }
    }
}
