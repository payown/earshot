import Foundation
import SwiftData

/// Applies only validated peer playback events to eligible idle episodes.
/// The caller must establish fresh local receiving consent and revalidate it
/// after coordinated file reads, before invoking this synchronous save boundary.
@MainActor
enum ListeningPlacesPlaybackReceiver {
    struct Result {
        var applied = 0
        var deferredLoaded = 0
        var deferred = 0
    }

    enum ReceiverError: Error { case dirtyContext, revalidationFailed }

    /// Pure bounded decoding can run away from the main actor for an automatic
    /// Queue check. The store, eligibility and loaded-item checks remain on the
    /// main actor at the eventual save boundary.
    nonisolated static func parsePeerFiles(
        _ files: [(deviceID: String, data: Data)], ownDeviceID: String, now: Date
    ) -> [(deviceID: String, file: ListeningPlacesInboundFile)] {
        files.compactMap { source in
            guard source.deviceID != ownDeviceID,
                  let parsed = try? ListeningPlacesInboundParser.parse(
                    data: source.data, now: now
                  ), parsed.deviceID == source.deviceID, !parsed.isStale else {
                return nil
            }
            return (deviceID: source.deviceID, file: parsed)
        }
    }

    static func apply(
        _ files: [(deviceID: String, data: Data)], in context: ModelContext,
        ownDeviceID: String, now: Date,
        loadedEpisodeID: @MainActor () -> PersistentIdentifier?,
        targetEpisode: Episode? = nil
    ) throws -> Result {
        try applyParsed(
            parsePeerFiles(files, ownDeviceID: ownDeviceID, now: now),
            in: context, loadedEpisodeID: loadedEpisodeID,
            targetEpisode: targetEpisode
        )
    }

    static func applyParsed(
        _ files: [(deviceID: String, file: ListeningPlacesInboundFile)],
        in context: ModelContext,
        loadedEpisodeID: @MainActor () -> PersistentIdentifier?,
        targetEpisode: Episode? = nil
    ) throws -> Result {
        guard ListeningPlacesPlaybackReceiveConsent.isEnabled(in: context) else {
            return Result()
        }
        guard !context.hasChanges else { throw ReceiverError.dirtyContext }
        var remoteByID: [String: [ListeningPlacesRemoteEvent]] = [:]
        let targetID = targetEpisode.map {
            ListeningPlacesFormat.episodeID(guid: $0.guid, enclosureURL: $0.audioURL)
        }
        for file in files {
            for entry in file.file.entries where targetID == nil || entry.record.id == targetID {
                remoteByID[entry.record.id, default: []].append(
                    ListeningPlacesRemoteEvent(deviceID: file.deviceID, entry: entry)
                )
            }
        }
        guard !remoteByID.isEmpty else { return Result() }
        let deviceOnly = try ListeningPlacesFeedPrivacy.deviceOnlyKeys(in: context)
        let approved = try ListeningPlacesPublicFeedApproval.approvedKeys(in: context)
        var matches: [String: [Episode]] = [:]
        if let targetEpisode {
            guard targetEpisode.modelContext === context, !targetEpisode.isDeleted else {
                return Result()
            }
            let id = ListeningPlacesFormat.episodeID(
                guid: targetEpisode.guid, enclosureURL: targetEpisode.audioURL
            )
            if remoteByID[id] != nil {
                let guid = targetEpisode.guid
                let sameGUID = try context.fetch(FetchDescriptor<Episode>(
                    predicate: #Predicate { $0.guid == guid }
                ))
                matches[id] = sameGUID.filter {
                    ListeningPlacesFormat.episodeID(
                        guid: $0.guid, enclosureURL: $0.audioURL
                    ) == id
                }
            }
        } else {
            var offset = 0
            while true {
                var descriptor = FetchDescriptor<Episode>()
                descriptor.fetchOffset = offset
                descriptor.fetchLimit = 256
                let batch = try context.fetch(descriptor)
                if batch.isEmpty { break }
                for episode in batch {
                    let id = ListeningPlacesFormat.episodeID(
                        guid: episode.guid, enclosureURL: episode.audioURL
                    )
                    if remoteByID[id] != nil { matches[id, default: []].append(episode) }
                }
                if batch.count < 256 { break }
                offset += batch.count
            }
        }
        var result = Result()
        var staged: [(episode: Episode, event: ListeningPlacesStateEvent,
                      feed: String)] = []
        do {
            for id in remoteByID.keys.sorted() {
                guard let rows = matches[id], rows.count == 1, let episode = rows.first,
                      let feed = episode.podcast?.feedURL,
                      ListeningPlacesFeedPrivacy.mayShare(
                        feedURL: feed, deviceOnlyKeys: deviceOnly
                      ),
                      approved.contains(ListeningPlacesPublicFeedApproval.key(feed)),
                      episode.status != .expired
                else { result.deferred += 1; continue }
                let local = try ListeningPlacesEventJournal.read(for: episode, in: context)
                let loaded = loadedEpisodeID() == episode.persistentModelID
                let decision = ListeningPlacesMergePlanner.decide(
                    id: id, local: local, remote: remoteByID[id] ?? [], isLoaded: loaded
                )
                switch decision {
                case .keepLocal: result.deferred += 1
                case .deferLoaded: result.deferredLoaded += 1
                case .apply(let event):
                    guard event.positionMilliseconds >= 0,
                          loadedEpisodeID() != episode.persistentModelID,
                          ListeningPlacesFormat.episodeID(
                            guid: episode.guid, enclosureURL: episode.audioURL
                          ) == event.id else {
                        result.deferred += 1; continue
                    }
                    episode.positionSeconds = event.positionMilliseconds / 1_000
                    if event.played {
                        episode.status = .played
                        episode.playedAt = event.updatedAt
                    } else {
                        if episode.status == .played { episode.status = .newEpisode }
                        episode.playedAt = nil
                    }
                    try ListeningPlacesEventJournal.stagePeerEvent(
                        event, for: episode, in: context
                    )
                    staged.append((episode, event, feed))
                    result.applied += 1
                }
            }
            if context.hasChanges {
                guard ListeningPlacesPlaybackReceiveConsent.isEnabled(in: context),
                      staged.allSatisfy({ item in
                    loadedEpisodeID() != item.episode.persistentModelID
                        && item.episode.podcast?.feedURL == item.feed
                        && ListeningPlacesFormat.episodeID(
                            guid: item.episode.guid, enclosureURL: item.episode.audioURL
                        ) == item.event.id
                        && ListeningPlacesFeedPrivacy.mayShare(
                            feedURL: item.feed, deviceOnlyKeys: deviceOnly
                        ) && approved.contains(ListeningPlacesPublicFeedApproval.key(item.feed))
                }) else {
                    throw ReceiverError.revalidationFailed
                }
                // No suspension occurs between the final loaded check and save.
                try context.save()
            }
        } catch {
            context.rollback()
            throw error
        }
        return result
    }
}
