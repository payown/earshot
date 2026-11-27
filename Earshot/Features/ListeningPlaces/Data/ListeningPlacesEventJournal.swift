import CryptoKit
import Foundation
import SwiftData

/// Experimental local provenance for future two-way places. Episode and
/// AppSetting are in the same FutureMirrored SQLite configuration, which has
/// CloudKit disabled. Callers must stage the event before the Episode save;
/// this helper never saves independently. The receiver remains disabled.
enum ListeningPlacesEventJournal {
    private static let keyPrefix = "listening_places_event_v1:"

    enum Error: Swift.Error {
        case missingEpisodeIdentity
        case encodingFailure
    }

    struct StoredEvent: Codable, Equatable {
        let positionMilliseconds: Int
        let played: Bool
        let updatedAt: Date
        let sourceDeviceID: String
        let isReset: Bool
    }

    /// Missing or unreadable provenance is unknown, never assigned export time.
    static func read(for episode: Episode, in context: ModelContext) throws -> ListeningPlacesLocalPlace {
        guard let key = key(for: episode),
              let raw = try AppSettingIdentity.valueThrowing(for: key, in: context),
              let stored = decode(raw) else { return .unknownLegacy }
        let currentPosition = ListeningPlacesFormat.milliseconds(episode.positionSeconds)
        guard stored.positionMilliseconds == currentPosition,
              stored.played == episode.isPlayed else { return .unknownLegacy }
        let id = ListeningPlacesFormat.episodeID(guid: episode.guid, enclosureURL: episode.audioURL)
        return .event(ListeningPlacesStateEvent(
            id: id, positionMilliseconds: currentPosition, played: stored.played,
            updatedAt: stored.updatedAt, sourceDeviceID: stored.sourceDeviceID,
            isReset: stored.isReset
        ))
    }

    /// Stage only after an actual local playback/Played-state mutation. A
    /// metadata-only save must not call this. A no-op checkpoint retains its
    /// earlier clock; a changed event advances even if the wall clock went back.
    @discardableResult
    static func stageLocalMutation(
        of episode: Episode, in context: ModelContext,
        deviceID: String, now: Date = .now, isReset: Bool = false,
        force: Bool = false
    ) throws -> Bool {
        guard let key = key(for: episode), !deviceID.isEmpty else {
            throw Error.missingEpisodeIdentity
        }
        let previous = try AppSettingIdentity.valueThrowing(for: key, in: context).flatMap(decode)
        let position = ListeningPlacesFormat.milliseconds(episode.positionSeconds)
        let played = episode.isPlayed
        if !force, previous?.positionMilliseconds == position && previous?.played == played {
            return false
        }
        let event = StoredEvent(
            positionMilliseconds: position, played: played,
            updatedAt: max(now, previous?.updatedAt.addingTimeInterval(0.001) ?? now),
            sourceDeviceID: deviceID, isReset: isReset
        )
        try AppSettingIdentity.setValue(encode(event), for: key, in: context)
        return true
    }

    /// Stage provenance at the same save boundary as an Episode mutation. A
    /// fresh context supplies the last committed values so a metadata-only
    /// save does not invent a playback event. A changed value forces a new
    /// clock even when a previously unstaged write made the old signature
    /// match again. This covers only callers that use this boundary; there is
    /// deliberately no claim that it intercepts every SwiftData save.
    static func stageChangedEpisodesBeforeSave(
        in context: ModelContext, localDeviceID: String?, now: Date = .now
    ) throws {
        let changed = context.changedModelsArray.compactMap { $0 as? Episode }
        guard !changed.isEmpty else { return }
        let committed = ModelContext(context.container)
        for episode in changed {
            guard let previous = committed.model(for: episode.persistentModelID) as? Episode,
                  previous.positionSeconds != episode.positionSeconds
                    || previous.isPlayed != episode.isPlayed else { continue }
            // A playable catalog row can lack a stable interchange identity.
            // Its ordinary playback save must never fail for that reason.
            guard key(for: episode) != nil else { continue }
            if let localDeviceID, !localDeviceID.isEmpty {
                try stageLocalMutation(
                    of: episode, in: context, deviceID: localDeviceID,
                    now: now, force: true
                )
            } else {
                try invalidate(for: episode, in: context)
            }
        }
    }

    /// An imported state with no trustworthy peer event time must not inherit
    /// an earlier local event. The receiver can later stage the true peer
    /// event in the same transaction when that time is available.
    static func invalidate(for episode: Episode, in context: ModelContext) throws {
        guard let key = key(for: episode) else { return }
        try AppSettingIdentity.removeValue(for: key, in: context)
    }

    /// Peer application will use its original event time and device identity,
    /// never the import time. This stages provenance only; it does not mutate an
    /// Episode or trigger playback and is not called by the app today.
    static func stagePeerEvent(
        _ event: ListeningPlacesStateEvent, for episode: Episode,
        in context: ModelContext
    ) throws {
        guard let key = key(for: episode), !event.sourceDeviceID.isEmpty,
              event.id == ListeningPlacesFormat.episodeID(
                guid: episode.guid, enclosureURL: episode.audioURL
              ),
              event.positionMilliseconds == ListeningPlacesFormat.milliseconds(episode.positionSeconds),
              event.played == episode.isPlayed else { throw Error.missingEpisodeIdentity }
        try AppSettingIdentity.setValue(encode(StoredEvent(
            positionMilliseconds: event.positionMilliseconds,
            played: event.played, updatedAt: event.updatedAt,
            sourceDeviceID: event.sourceDeviceID, isReset: event.isReset
        )), for: key, in: context)
    }

    private static func key(for episode: Episode) -> String? {
        guard let feedURL = episode.podcast?.feedURL,
              !feedURL.isEmpty else { return nil }
        let identity = ListeningPlacesFormat.episodeID(
            guid: episode.guid, enclosureURL: episode.audioURL
        )
        guard !identity.isEmpty else { return nil }
        let source = FeedURLIdentity.canonical(feedURL) + "\u{0}" + identity
        let hash = SHA256.hash(data: Data(source.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return keyPrefix + hash
    }

    private static func encode(_ event: StoredEvent) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(event)
        guard let raw = String(data: data, encoding: .utf8) else { throw Error.encodingFailure }
        return raw
    }

    private static func decode(_ raw: String) -> StoredEvent? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(StoredEvent.self, from: Data(raw.utf8))
    }
}
