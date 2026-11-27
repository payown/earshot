import Foundation

/// The local episode's provenance. An old zero or nonzero checkpoint cannot be
/// treated as a fresh event merely because it was read or exported today.
enum ListeningPlacesLocalPlace: Equatable, Sendable {
    case unknownLegacy
    case knownNoEvent
    case event(ListeningPlacesStateEvent)
}

struct ListeningPlacesStateEvent: Equatable, Sendable {
    let id: String
    let positionMilliseconds: Int
    let played: Bool
    let updatedAt: Date
    let sourceDeviceID: String
    let isReset: Bool
}

struct ListeningPlacesRemoteEvent: Sendable {
    let deviceID: String
    let entry: ListeningPlacesInboundEntry
}

enum ListeningPlacesMergeDecision: Equatable, Sendable {
    case keepLocal
    case deferLoaded(ListeningPlacesStateEvent)
    case apply(ListeningPlacesStateEvent)
}

/// Pure per-ID decision. The caller must first exclude stale/wrong-device files,
/// confirm the local episode identity, and never apply a decision directly to
/// PlayerService. No store or player mutation happens here.
enum ListeningPlacesMergePlanner {
    static func decide(
        id: String,
        local: ListeningPlacesLocalPlace,
        remote: [ListeningPlacesRemoteEvent],
        isLoaded: Bool
    ) -> ListeningPlacesMergeDecision {
        guard local != .unknownLegacy else { return .keepLocal }
        let candidates = remote.compactMap { item -> ListeningPlacesStateEvent? in
            let record = item.entry.record
            guard record.id == id else { return nil }
            if record.deleted == true {
                return ListeningPlacesStateEvent(
                    id: id, positionMilliseconds: 0, played: false,
                    updatedAt: item.entry.effectiveUpdatedAt,
                    sourceDeviceID: item.deviceID, isReset: true
                )
            }
            guard let position = record.positionMilliseconds,
                  let played = record.played else { return nil }
            return ListeningPlacesStateEvent(
                id: id, positionMilliseconds: position, played: played,
                updatedAt: item.entry.effectiveUpdatedAt,
                sourceDeviceID: item.deviceID, isReset: false
            )
        }
        guard let newest = candidates.max(by: precedes) else { return .keepLocal }
        if case .event(let current) = local, newest.updatedAt < current.updatedAt {
            return .keepLocal
        }
        return isLoaded ? .deferLoaded(newest) : .apply(newest)
    }

    private static func precedes(_ lhs: ListeningPlacesStateEvent, _ rhs: ListeningPlacesStateEvent) -> Bool {
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
        // A tie against this device is handled above in favor of the remote.
        // Two remote files need a stable rule independent of enumeration order.
        return lhs.sourceDeviceID < rhs.sourceDeviceID
    }
}
