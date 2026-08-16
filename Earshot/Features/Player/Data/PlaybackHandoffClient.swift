import CloudKit
import CryptoKit
import Foundation

/// Stable identity for the single direct-CloudKit handoff record associated
/// with an episode. The feed is canonicalized with the exact same rules as the
/// application store so handoff identity cannot drift from episode identity.
struct PlaybackHandoffIdentity: Codable, Equatable, Hashable, Sendable {
    let feedURL: String
    let guid: String

    init?(feedURL: String?, guid: String) {
        guard let feedURL, !feedURL.isEmpty, !guid.isEmpty else { return nil }
        self.feedURL = FeedURLIdentity.canonical(feedURL)
        self.guid = guid
    }

    var recordName: String {
        let input = Data("\(feedURL)\u{1f}\(guid)".utf8)
        let digest = SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
        return "handoff-v1-\(digest)"
    }
}

/// A single intentional playback boundary. Direct handoff uses one record per
/// episode and server-serialized last-write-wins updates, so a deliberate rewind
/// is preserved instead of incorrectly selecting the largest position.
struct PlaybackHandoffSnapshot: Codable, Equatable, Sendable {
    let identity: PlaybackHandoffIdentity
    let positionSeconds: Int
    let playbackRate: Double
    let eventID: UUID
    let eventDate: Date
    let sourceDeviceID: String

    init(
        identity: PlaybackHandoffIdentity,
        positionSeconds: Int,
        playbackRate: Double,
        eventID: UUID = UUID(),
        eventDate: Date = .now,
        sourceDeviceID: String = CloudProjectionDeviceIdentity.value()
    ) {
        self.identity = identity
        self.positionSeconds = max(0, positionSeconds)
        self.playbackRate = PlaybackLogic.clampedSpeed(playbackRate)
        self.eventID = eventID
        self.eventDate = eventDate
        self.sourceDeviceID = sourceDeviceID
    }
}

enum PlaybackHandoffOrdering {
    /// Prevents a delayed task or recovered offline boundary from overwriting a
    /// more recent intentional event already accepted by the server. Device
    /// clocks are normally network-synchronized; eventID makes retries
    /// idempotent when timestamps are equal.
    static func shouldAccept(
        incoming: PlaybackHandoffSnapshot,
        over existing: PlaybackHandoffSnapshot?
    ) -> Bool {
        guard let existing else { return true }
        if incoming.eventID == existing.eventID { return false }
        return incoming.eventDate >= existing.eventDate
    }
}

/// Injectable boundary between the player and direct CloudKit. Debug/test
/// builds remain synchronous and local through ``DisabledPlaybackHandoffClient``.
protocol PlaybackHandoffClient: Sendable {
    var isEnabled: Bool { get }
    func fetchLatest(for identity: PlaybackHandoffIdentity) async throws -> PlaybackHandoffSnapshot?
    func publish(_ snapshot: PlaybackHandoffSnapshot) async throws
}

/// Resolves an explicit fetch or its deadline exactly once without structured
/// concurrency waiting for a system CloudKit request that ignores cancellation.
/// A late network result is discarded by this gate and by PlayerService's
/// episode generation check.
actor PlaybackHandoffFetchRace {
    private var continuation: CheckedContinuation<PlaybackHandoffSnapshot?, Never>?

    init(_ continuation: CheckedContinuation<PlaybackHandoffSnapshot?, Never>) {
        self.continuation = continuation
    }

    func resolve(_ snapshot: PlaybackHandoffSnapshot?) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: snapshot)
    }
}

struct DisabledPlaybackHandoffClient: PlaybackHandoffClient {
    let isEnabled = false

    func fetchLatest(for identity: PlaybackHandoffIdentity) async throws -> PlaybackHandoffSnapshot? {
        nil
    }

    func publish(_ snapshot: PlaybackHandoffSnapshot) async throws {}
}

enum PlaybackHandoffClientFactory {
    static func make(
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]
    ) -> any PlaybackHandoffClient {
        guard CloudKitLaunchPolicy.isMirroringEnabled(infoDictionary: infoDictionary) else {
            return DisabledPlaybackHandoffClient()
        }
        return CloudKitPlaybackHandoffClient(
            container: CKContainer(identifier: CloudKitLaunchPolicy.containerIdentifier)
        )
    }
}

/// Explicit private-database transport for latency-sensitive playback handoff.
/// This intentionally does not read or mutate Core Data's CloudKit-managed
/// records. It owns a separate record type in the default private zone and
/// fetches by deterministic record ID, which is a single O(1) server lookup.
actor CloudKitPlaybackHandoffClient: PlaybackHandoffClient {
    nonisolated let isEnabled = true

    enum Schema {
        static let recordType = "EarshotPlaybackHandoff"
        static let schemaVersion = "schemaVersion"
        static let feedURL = "feedURL"
        static let episodeGUID = "episodeGUID"
        static let positionSeconds = "positionSeconds"
        static let playbackRate = "playbackRate"
        static let eventID = "eventID"
        static let eventDate = "eventDate"
        static let sourceDeviceID = "sourceDeviceID"
    }

    private let database: CKDatabase
    private var pendingStore: PlaybackHandoffPendingStore

    init(
        container: CKContainer,
        defaults: UserDefaults = .standard
    ) {
        database = container.privateCloudDatabase
        pendingStore = PlaybackHandoffPendingStore(defaults: defaults)
    }

    func fetchLatest(
        for identity: PlaybackHandoffIdentity
    ) async throws -> PlaybackHandoffSnapshot? {
        // Never let an older server record overwrite locally durable offline
        // progress. Retry that pending boundary first; if it still cannot upload,
        // propagate the error and let PlayerService use its local state.
        if let pending = pendingStore.snapshot(for: identity) {
            try await saveRemote(pending)
            pendingStore.clear(identity: identity, eventID: pending.eventID)
        }
        return try await fetchRemote(identity: identity)
    }

    func publish(_ snapshot: PlaybackHandoffSnapshot) async throws {
        // Persist before network I/O so cancellation, termination, and offline
        // failures cannot make a subsequent fetch accept stale server state.
        pendingStore.save(snapshot)
        try await saveRemote(snapshot)
        pendingStore.clear(identity: snapshot.identity, eventID: snapshot.eventID)
    }

    private func fetchRemote(
        identity: PlaybackHandoffIdentity
    ) async throws -> PlaybackHandoffSnapshot? {
        let recordID = CKRecord.ID(recordName: identity.recordName)
        let configuration = CKOperation.Configuration()
        configuration.qualityOfService = .userInitiated
        do {
            let record = try await database.configuredWith(configuration: configuration) { database in
                try await database.record(for: recordID)
            }
            return Self.snapshot(from: record)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    private func saveRemote(_ snapshot: PlaybackHandoffSnapshot) async throws {
        let recordID = CKRecord.ID(recordName: snapshot.identity.recordName)
        // Optimistic concurrency keeps one server-serialized ordering. Refetch
        // and retry when another device wins the race; the later accepted
        // intentional boundary becomes the handoff truth, including rewinds.
        for attempt in 0..<3 {
            let record = try await recordForUpdate(id: recordID)
                ?? CKRecord(recordType: Schema.recordType, recordID: recordID)
            if record.recordChangeTag != nil,
               !PlaybackHandoffOrdering.shouldAccept(
                   incoming: snapshot,
                   over: Self.snapshot(from: record)
               ) {
                return
            }
            Self.apply(snapshot, to: record)
            do {
                _ = try await database.save(record)
                return
            } catch let error as CKError where error.code == .serverRecordChanged && attempt < 2 {
                continue
            }
        }
    }

    private func recordForUpdate(id: CKRecord.ID) async throws -> CKRecord? {
        do {
            return try await database.record(for: id)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    static func apply(_ snapshot: PlaybackHandoffSnapshot, to record: CKRecord) {
        record[Schema.schemaVersion] = NSNumber(value: 1)
        record[Schema.feedURL] = snapshot.identity.feedURL as NSString
        record[Schema.episodeGUID] = snapshot.identity.guid as NSString
        record[Schema.positionSeconds] = NSNumber(value: snapshot.positionSeconds)
        record[Schema.playbackRate] = NSNumber(value: snapshot.playbackRate)
        record[Schema.eventID] = snapshot.eventID.uuidString as NSString
        record[Schema.eventDate] = snapshot.eventDate as NSDate
        record[Schema.sourceDeviceID] = snapshot.sourceDeviceID as NSString
    }

    static func snapshot(from record: CKRecord) -> PlaybackHandoffSnapshot? {
        guard let feedURL = record[Schema.feedURL] as? String,
              let guid = record[Schema.episodeGUID] as? String,
              let identity = PlaybackHandoffIdentity(feedURL: feedURL, guid: guid),
              let position = record[Schema.positionSeconds] as? NSNumber,
              let rate = record[Schema.playbackRate] as? NSNumber,
              let eventIDString = record[Schema.eventID] as? String,
              let eventID = UUID(uuidString: eventIDString),
              let eventDate = record[Schema.eventDate] as? Date,
              let sourceDeviceID = record[Schema.sourceDeviceID] as? String else {
            return nil
        }
        return PlaybackHandoffSnapshot(
            identity: identity,
            positionSeconds: position.intValue,
            playbackRate: rate.doubleValue,
            eventID: eventID,
            eventDate: eventDate,
            sourceDeviceID: sourceDeviceID
        )
    }
}

/// Small durable retry queue. Only the newest boundary for each episode is
/// useful, and the cap prevents abandoned offline episodes from growing defaults
/// without bound.
struct PlaybackHandoffPendingStore {
    private static let key = "earshot_playback_handoff_pending_v1"
    private static let capacity = 32
    private let defaults: UserDefaults
    private var snapshots: [String: PlaybackHandoffSnapshot]

    init(defaults: UserDefaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(
               [String: PlaybackHandoffSnapshot].self,
               from: data
           ) {
            snapshots = decoded
        } else {
            snapshots = [:]
        }
    }

    func snapshot(for identity: PlaybackHandoffIdentity) -> PlaybackHandoffSnapshot? {
        snapshots[identity.recordName]
    }

    mutating func save(_ snapshot: PlaybackHandoffSnapshot) {
        if let existing = snapshots[snapshot.identity.recordName],
           !PlaybackHandoffOrdering.shouldAccept(incoming: snapshot, over: existing) {
            return
        }
        snapshots[snapshot.identity.recordName] = snapshot
        if snapshots.count > Self.capacity {
            for stale in snapshots.values
                .sorted(by: { $0.eventDate < $1.eventDate })
                .prefix(snapshots.count - Self.capacity) {
                snapshots.removeValue(forKey: stale.identity.recordName)
            }
        }
        persist()
    }

    mutating func clear(identity: PlaybackHandoffIdentity, eventID: UUID) {
        guard snapshots[identity.recordName]?.eventID == eventID else { return }
        snapshots.removeValue(forKey: identity.recordName)
        persist()
    }

    private func persist() {
        if snapshots.isEmpty {
            defaults.removeObject(forKey: Self.key)
        } else if let data = try? JSONEncoder().encode(snapshots) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
