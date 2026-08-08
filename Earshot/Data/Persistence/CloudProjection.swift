import Foundation
import SwiftData

extension Notification.Name {
    static let earshotCloudProjectionDidApply = Notification.Name(
        "earshotCloudProjectionDidApply"
    )
    static let earshotSubscriptionsDidChange = Notification.Name(
        "earshotSubscriptionsDidChange"
    )
    static let earshotEpisodeUserStateDidChange = Notification.Name(
        "earshotEpisodeUserStateDidChange"
    )
}

struct EpisodeUserStateSnapshot: Sendable, Equatable {
    let feedURL: String
    let guid: String
    let positionSeconds: Int
    let isPlayed: Bool
    let playedChangedExplicitly: Bool

    @MainActor
    init?(episode: Episode, playedChangedExplicitly: Bool = false) {
        guard let feedURL = episode.podcast?.feedURL, !episode.guid.isEmpty else { return nil }
        self.feedURL = FeedURLIdentity.canonical(feedURL)
        self.guid = episode.guid
        self.positionSeconds = max(0, episode.positionSeconds)
        self.isPlayed = episode.isPlayed
        self.playedChangedExplicitly = playedChangedExplicitly
    }
}

@MainActor
func postEpisodeUserStateChanges(
    _ episodes: [Episode],
    playedChangedExplicitly: Bool = false
) {
    let snapshots = episodes.compactMap {
        EpisodeUserStateSnapshot(
            episode: $0,
            playedChangedExplicitly: playedChangedExplicitly
        )
    }
    guard !snapshots.isEmpty else { return }
    NotificationCenter.default.post(
        name: .earshotEpisodeUserStateDidChange,
        object: snapshots
    )
}

/// Relationship-free subscription record used by the B1 development gate.
/// Episode catalogs remain local and are refetched independently on each device.
@Model
final class CloudPodcastProjection {
    var feedURL: String = ""
    var title: String = ""
    var author: String?
    var podcastDescription: String?
    var artworkURL: String?
    var websiteURL: String?
    var language: String?
    var category: String?
    var autoQueue: Bool = false
    var notificationEnabled: Bool?
    var speedOverride: Double?
    var trimSilenceOverride: Bool?
    var introSkipSeconds: Int?
    var queueAgeLimitDays: Int?
    var inboxMaxEpisodes: Int?
    var inboxAgeLimitHours: Int?
    var inboxExcluded: Bool = false
    var inboxIncluded: Bool = false
    var createdAt: Date = Date.distantPast
    var lastSeenPubDate: Date?
    var modifiedAt: Date = Date.distantPast
    var deletedAt: Date?
    var sourceDeviceID: String = ""

    init() {}
}

/// One device's compact contribution to an episode's user state. Feed metadata
/// is intentionally absent: a second device refetches the catalog and applies
/// these rows only when the matching episode exists locally.
@Model
final class CloudEpisodeStateProjection {
    var feedURL: String = ""
    var episodeGUID: String = ""
    var sourceDeviceID: String = ""
    var positionSeconds: Int = 0
    var positionUpdatedAt: Date = Date.distantPast
    /// Set when this device deliberately moves progress backward. Keeping the
    /// event time lets reconciliation ignore an older offline progress write.
    var positionResetAt: Date?
    var isPlayed: Bool = false
    var playedUpdatedAt: Date = Date.distantPast
    var modifiedAt: Date = Date.distantPast
    var deletedAt: Date?

    init() {}
}

/// Per-device queue membership contribution. Reconciliation chooses the newest
/// contribution for each episode and then sorts deterministically by position.
@Model
final class CloudQueueItemProjection {
    var feedURL: String = ""
    var episodeGUID: String = ""
    var sourceDeviceID: String = ""
    var isQueued: Bool = false
    var position: Int = 0
    var modifiedAt: Date = Date.distantPast
    var deletedAt: Date?

    init() {}
}

@MainActor
final class CloudProjectionCoordinator {
    private struct PodcastValue: Equatable {
        let feedURL: String
        let title: String
        let author: String?
        let podcastDescription: String?
        let artworkURL: String?
        let websiteURL: String?
        let language: String?
        let category: String?
        let autoQueue: Bool
        let notificationEnabled: Bool?
        let speedOverride: Double?
        let trimSilenceOverride: Bool?
        let introSkipSeconds: Int?
        let queueAgeLimitDays: Int?
        let inboxMaxEpisodes: Int?
        let inboxAgeLimitHours: Int?
        let inboxExcluded: Bool
        let inboxIncluded: Bool
        let createdAt: Date
        let lastSeenPubDate: Date?
    }

    private struct EpisodeKey: Hashable, Comparable {
        let feedURL: String
        let guid: String

        static func < (lhs: EpisodeKey, rhs: EpisodeKey) -> Bool {
            if lhs.feedURL != rhs.feedURL { return lhs.feedURL < rhs.feedURL }
            return lhs.guid < rhs.guid
        }
    }

    private let applicationContainer: ModelContainer
    private let projectionContainer: ModelContainer
    private let center: NotificationCenter
    private var importObserver: NSObjectProtocol?
    private var subscriptionObserver: NSObjectProtocol?
    private var episodeObserver: NSObjectProtocol?
    private var catalogObserver: NSObjectProtocol?
    private var queueObserver: NSObjectProtocol?
    private var reconcileTask: Task<Void, Never>?
    private var knownLocalFeedURLs: Set<String> = []
    private let deviceID: String
    private var isApplyingRemote = false

    init(
        applicationContainer: ModelContainer,
        projectionContainer: ModelContainer,
        center: NotificationCenter = .default,
        deviceID: String = CloudProjectionDeviceIdentity.value()
    ) {
        self.applicationContainer = applicationContainer
        self.projectionContainer = projectionContainer
        self.center = center
        self.deviceID = deviceID
    }

    static func make(applicationContainer: ModelContainer) throws -> CloudProjectionCoordinator {
        let schema = Schema([
            CloudPodcastProjection.self,
            CloudEpisodeStateProjection.self,
            CloudQueueItemProjection.self,
        ])
        let configuration = ModelConfiguration(
            "CloudProjection",
            schema: schema,
            url: URL.applicationSupportDirectory.appending(path: "earshot-cloud-projection.store"),
            cloudKitDatabase: CloudKitLaunchPolicy.projectionDatabase()
        )
        let projectionContainer = try ModelContainer(for: schema, configurations: configuration)
        return CloudProjectionCoordinator(
            applicationContainer: applicationContainer,
            projectionContainer: projectionContainer
        )
    }

    func start() throws {
        guard importObserver == nil else { return }
        importObserver = center.addObserver(
            forName: .earshotCloudKitImportDidFinish,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleReconciliation() }
        }
        subscriptionObserver = center.addObserver(
            forName: .earshotSubscriptionsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard self?.isApplyingRemote == false else { return }
                do {
                    try self?.publishLocalSubscriptionChanges()
                } catch {
                    AppLog.data.error(
                        "Cloud subscription projection failed: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        }
        episodeObserver = center.addObserver(
            forName: .earshotEpisodeUserStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let snapshots = notification.object as? [EpisodeUserStateSnapshot],
                  !snapshots.isEmpty else { return }
            MainActor.assumeIsolated {
                guard self?.isApplyingRemote == false else { return }
                do {
                    try self?.publishLocalEpisodeStateChanges(snapshots: snapshots)
                } catch {
                    AppLog.data.error(
                        "Cloud episode-state projection failed: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        }
        // Feed refresh uses this existing event after its store save. Running
        // reconciliation on the next main-actor turn lets a newly refetched
        // episode receive any CloudKit state that arrived before its metadata.
        catalogObserver = center.addObserver(
            forName: .earshotInboxDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleReconciliation() }
        }
        queueObserver = center.addObserver(
            forName: .earshotQueueDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard self?.isApplyingRemote == false else { return }
                do {
                    try self?.publishLocalQueueChanges()
                } catch {
                    AppLog.data.error(
                        "Cloud queue projection failed: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        }
        try reconcile()
    }

    func stop() async {
        if let importObserver {
            center.removeObserver(importObserver)
            self.importObserver = nil
        }
        if let subscriptionObserver {
            center.removeObserver(subscriptionObserver)
            self.subscriptionObserver = nil
        }
        if let episodeObserver {
            center.removeObserver(episodeObserver)
            self.episodeObserver = nil
        }
        if let catalogObserver {
            center.removeObserver(catalogObserver)
            self.catalogObserver = nil
        }
        if let queueObserver {
            center.removeObserver(queueObserver)
            self.queueObserver = nil
        }
        reconcileTask?.cancel()
        _ = await reconcileTask?.value
        reconcileTask = nil
    }

    private func scheduleReconciliation() {
        guard reconcileTask == nil else { return }
        reconcileTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { reconcileTask = nil }
            do {
                try reconcile()
            } catch {
                AppLog.data.error(
                    "Cloud projection reconciliation failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    /// Applies remote subscriptions before projecting local subscriptions. An
    /// empty new device therefore cannot overwrite a populated account.
    func reconcile() throws {
        guard !isApplyingRemote else { return }
        isApplyingRemote = true
        defer { isApplyingRemote = false }
        let appContext = applicationContainer.mainContext
        let cloudContext = projectionContainer.mainContext
        let cloudRows = try cloudContext.fetch(FetchDescriptor<CloudPodcastProjection>())
        var cloudByFeed: [String: CloudPodcastProjection] = [:]
        for row in cloudRows.sorted(by: Self.projectionOrder) {
            let key = FeedURLIdentity.canonical(row.feedURL)
            if cloudByFeed[key] == nil {
                cloudByFeed[key] = row
            } else {
                cloudContext.delete(row)
            }
        }

        var applicationChanged = false
        for row in cloudByFeed.values.sorted(by: Self.projectionOrder) {
            if row.deletedAt != nil {
                if let podcast = try PodcastIdentityService(context: appContext)
                    .existing(feedURL: row.feedURL) {
                    applicationChanged = SubscriptionRepository(context: appContext)
                        .unsubscribe(podcast) || applicationChanged
                }
                continue
            }
            let result = try PodcastIdentityService(context: appContext).fetchOrCreate(
                feedURL: row.feedURL
            ) { canonical in
                Podcast(feedURL: canonical, title: row.title, createdAt: row.createdAt)
            }
            if value(row) != value(result.podcast) {
                copy(row, to: result.podcast)
            }
            applicationChanged = applicationChanged || result.inserted
        }
        if appContext.hasChanges {
            try appContext.save()
            applicationChanged = true
        }

        let podcasts = try appContext.fetch(FetchDescriptor<Podcast>())
            .sorted { FeedURLIdentity.canonical($0.feedURL) < FeedURLIdentity.canonical($1.feedURL) }
        for podcast in podcasts {
            let key = FeedURLIdentity.canonical(podcast.feedURL)
            let row = cloudByFeed[key] ?? {
                let inserted = CloudPodcastProjection()
                inserted.feedURL = key
                cloudContext.insert(inserted)
                cloudByFeed[key] = inserted
                return inserted
            }()
            guard row.deletedAt == nil else { continue }
            if value(podcast) != value(row) {
                copy(podcast, to: row)
            }
        }
        if cloudContext.hasChanges { try cloudContext.save() }
        knownLocalFeedURLs = Set(podcasts.map { FeedURLIdentity.canonical($0.feedURL) })
        // Seed only keys this device has never projected. Existing rows may
        // describe state that a prior remote reconciliation applied locally;
        // treating that as a fresh local edit would manufacture a rewind.
        try publishLocalEpisodeStateChanges(now: .now, onlyMissingOwnRows: true)
        let episodeChanged = try applyRemoteEpisodeStates(
            appContext: appContext,
            cloudContext: cloudContext
        )
        applicationChanged = episodeChanged || applicationChanged
        if episodeChanged {
            center.post(name: .earshotInboxDidChange, object: nil)
        }
        try publishLocalQueueChanges(now: .now, onlyIfCloudEmpty: true)
        let queueChanged = try applyRemoteQueue(
            appContext: appContext,
            cloudContext: cloudContext
        )
        applicationChanged = queueChanged || applicationChanged
        if queueChanged {
            center.post(name: .earshotQueueDidChange, object: nil)
            center.post(name: .earshotInboxDidChange, object: nil)
        }
        if applicationChanged {
            center.post(name: .earshotCloudProjectionDidApply, object: nil)
        }
    }

    /// Writes only meaningful, user-authored episode state. A 232,000-row feed
    /// catalog with one played episode therefore produces one state row, not a
    /// second copy of the catalog.
    func publishLocalEpisodeStateChanges(
        now: Date = .now,
        onlyMissingOwnRows: Bool = false
    ) throws {
        let appContext = applicationContainer.mainContext
        let cloudContext = projectionContainer.mainContext
        let meaningful = try appContext.fetch(FetchDescriptor<Episode>(
            predicate: #Predicate {
                $0.positionSeconds > 0 || $0.playedAt != nil
            }
        ))
        var localByKey: [EpisodeKey: Episode] = [:]
        for episode in meaningful.sorted(by: Self.episodeOrder) {
            guard let key = Self.episodeKey(for: episode) else { continue }
            if localByKey[key] == nil { localByKey[key] = episode }
        }

        let rows = try cloudContext.fetch(FetchDescriptor<CloudEpisodeStateProjection>())
        var ownByKey: [EpisodeKey: CloudEpisodeStateProjection] = [:]
        for row in rows
            .filter({ $0.sourceDeviceID == deviceID && $0.deletedAt == nil })
            .sorted(by: Self.episodeProjectionOrder) {
            let key = Self.episodeKey(for: row)
            if ownByKey[key] == nil {
                ownByKey[key] = row
            } else {
                cloudContext.delete(row)
            }
        }

        // Existing projection keys that are no longer meaningful must be
        // distinguished from episodes not yet refetched on this device.
        let existingForOwnKeys = applicationEpisodes(matching: Set(ownByKey.keys))
        let keys = Set(localByKey.keys).union(ownByKey.keys).sorted()
        for key in keys {
            if onlyMissingOwnRows, ownByKey[key] != nil { continue }
            guard let episode = localByKey[key] ?? existingForOwnKeys[key] else {
                continue
            }
            let row = ownByKey[key] ?? {
                let inserted = CloudEpisodeStateProjection()
                inserted.feedURL = key.feedURL
                inserted.episodeGUID = key.guid
                inserted.sourceDeviceID = deviceID
                inserted.positionUpdatedAt = now
                inserted.playedUpdatedAt = episode.isPlayed ? now : .distantPast
                cloudContext.insert(inserted)
                ownByKey[key] = inserted
                return inserted
            }()
            let position = max(0, episode.positionSeconds)
            if row.positionSeconds != position {
                if position < row.positionSeconds { row.positionResetAt = now }
                row.positionSeconds = position
                row.positionUpdatedAt = now
                row.modifiedAt = now
            }
            if row.isPlayed != episode.isPlayed {
                row.isPlayed = episode.isPlayed
                row.playedUpdatedAt = now
                row.modifiedAt = now
            }
            if row.modifiedAt == .distantPast { row.modifiedAt = now }
        }
        if cloudContext.hasChanges { try cloudContext.save() }
    }

    func publishLocalQueueChanges(
        now: Date = .now,
        onlyIfCloudEmpty: Bool = false
    ) throws {
        let appContext = applicationContainer.mainContext
        let cloudContext = projectionContainer.mainContext
        let rows = try cloudContext.fetch(FetchDescriptor<CloudQueueItemProjection>())
        if onlyIfCloudEmpty, !rows.isEmpty { return }

        let items = try appContext.fetch(FetchDescriptor<QueueItem>(
            sortBy: [SortDescriptor(\.position)]
        ))
        var current: [EpisodeKey: Int] = [:]
        for item in items {
            guard let episode = item.episode,
                  let key = Self.episodeKey(for: episode),
                  current[key] == nil else { continue }
            current[key] = item.position
        }

        var ownByKey: [EpisodeKey: CloudQueueItemProjection] = [:]
        for row in rows
            .filter({ $0.sourceDeviceID == deviceID && $0.deletedAt == nil })
            .sorted(by: Self.queueProjectionOrder) {
            let key = Self.episodeKey(for: row)
            if ownByKey[key] == nil {
                ownByKey[key] = row
            } else {
                cloudContext.delete(row)
            }
        }
        let keys = onlyIfCloudEmpty
            ? Set(current.keys)
            : Set(rows.filter { $0.deletedAt == nil }.map(Self.episodeKey)).union(current.keys)
        for key in keys.sorted() {
            let row = ownByKey[key] ?? {
                let inserted = CloudQueueItemProjection()
                inserted.feedURL = key.feedURL
                inserted.episodeGUID = key.guid
                inserted.sourceDeviceID = deviceID
                cloudContext.insert(inserted)
                ownByKey[key] = inserted
                return inserted
            }()
            let queued = current[key] != nil
            let position = current[key] ?? 0
            if row.isQueued != queued || row.position != position || row.deletedAt != nil {
                row.isQueued = queued
                row.position = position
                row.modifiedAt = now
                row.deletedAt = nil
            } else if row.modifiedAt == .distantPast {
                row.modifiedAt = now
            }
        }
        if cloudContext.hasChanges { try cloudContext.save() }
    }

    /// O(number of changed episodes) hot path used by playback and explicit
    /// actions. It never scans the feed catalog when a position anchor saves.
    func publishLocalEpisodeStateChanges(
        snapshots: [EpisodeUserStateSnapshot],
        now: Date = .now
    ) throws {
        guard !snapshots.isEmpty else { return }
        let cloudContext = projectionContainer.mainContext
        let rows = try cloudContext.fetch(FetchDescriptor<CloudEpisodeStateProjection>())
        var ownByKey: [EpisodeKey: CloudEpisodeStateProjection] = [:]
        for row in rows
            .filter({ $0.sourceDeviceID == deviceID && $0.deletedAt == nil })
            .sorted(by: Self.episodeProjectionOrder) {
            let key = Self.episodeKey(for: row)
            if ownByKey[key] == nil {
                ownByKey[key] = row
            } else {
                cloudContext.delete(row)
            }
        }
        var latestByKey: [EpisodeKey: EpisodeUserStateSnapshot] = [:]
        for snapshot in snapshots {
            let key = EpisodeKey(
                feedURL: FeedURLIdentity.canonical(snapshot.feedURL),
                guid: snapshot.guid
            )
            latestByKey[key] = snapshot
        }
        for key in latestByKey.keys.sorted() {
            guard let snapshot = latestByKey[key] else { continue }
            let row = ownByKey[key] ?? {
                let inserted = CloudEpisodeStateProjection()
                inserted.feedURL = key.feedURL
                inserted.episodeGUID = key.guid
                inserted.sourceDeviceID = deviceID
                inserted.positionUpdatedAt = now
                inserted.isPlayed = snapshot.isPlayed
                inserted.playedUpdatedAt = snapshot.isPlayed
                    || snapshot.playedChangedExplicitly ? now : .distantPast
                cloudContext.insert(inserted)
                ownByKey[key] = inserted
                return inserted
            }()
            if row.positionSeconds != snapshot.positionSeconds {
                if snapshot.positionSeconds < row.positionSeconds {
                    row.positionResetAt = now
                }
                row.positionSeconds = snapshot.positionSeconds
                row.positionUpdatedAt = now
                row.modifiedAt = now
            }
            if snapshot.playedChangedExplicitly {
                row.isPlayed = snapshot.isPlayed
                row.playedUpdatedAt = now
                row.modifiedAt = now
            }
            if row.modifiedAt == .distantPast { row.modifiedAt = now }
        }
        if cloudContext.hasChanges { try cloudContext.save() }
    }

    /// Persists additions, edits, and deletions synchronously at the domain save
    /// boundary. The CloudKit upload may be delayed, but a force quit cannot lose
    /// the local projection operation because its SQLite save has completed.
    func publishLocalSubscriptionChanges(now: Date = .now) throws {
        let appContext = applicationContainer.mainContext
        let cloudContext = projectionContainer.mainContext
        let podcasts = try appContext.fetch(FetchDescriptor<Podcast>())
        // Legacy stores can contain duplicate spellings of the same feed URL.
        // Launch repair normally coalesces them, but projection must remain
        // total even if a save notification arrives before that repair.
        var localByFeed: [String: Podcast] = [:]
        for podcast in podcasts.sorted(by: Self.podcastOrder) {
            let key = FeedURLIdentity.canonical(podcast.feedURL)
            if localByFeed[key] == nil { localByFeed[key] = podcast }
        }
        let rows = try cloudContext.fetch(FetchDescriptor<CloudPodcastProjection>())
        var cloudByFeed: [String: CloudPodcastProjection] = [:]
        for row in rows.sorted(by: Self.projectionOrder) {
            let key = FeedURLIdentity.canonical(row.feedURL)
            if cloudByFeed[key] == nil {
                cloudByFeed[key] = row
            } else {
                cloudContext.delete(row)
            }
        }

        for (key, podcast) in localByFeed {
            let row = cloudByFeed[key] ?? {
                let inserted = CloudPodcastProjection()
                inserted.feedURL = key
                cloudContext.insert(inserted)
                cloudByFeed[key] = inserted
                return inserted
            }()
            if row.deletedAt != nil || value(podcast) != value(row) {
                copy(podcast, to: row)
                row.deletedAt = nil
                row.modifiedAt = now
                row.sourceDeviceID = deviceID
            }
        }

        for key in knownLocalFeedURLs.subtracting(localByFeed.keys) {
            guard let row = cloudByFeed[key] else { continue }
            row.deletedAt = now
            row.modifiedAt = now
            row.sourceDeviceID = deviceID
        }
        if cloudContext.hasChanges { try cloudContext.save() }
        knownLocalFeedURLs = Set(localByFeed.keys)
    }

    /// Records the destructive intent before the application-store transaction.
    /// The projection store remains in place, so a force quit after this save
    /// restarts from tombstones rather than re-importing the deleted library.
    func markAllSubscriptionsDeleted(now: Date = .now) throws {
        let context = projectionContainer.mainContext
        let podcastRows = try context.fetch(FetchDescriptor<CloudPodcastProjection>())
        for row in podcastRows where row.deletedAt == nil {
            row.deletedAt = now
            row.modifiedAt = now
            row.sourceDeviceID = deviceID
        }
        let episodeRows = try context.fetch(FetchDescriptor<CloudEpisodeStateProjection>())
        for row in episodeRows where row.deletedAt == nil {
            row.deletedAt = now
            row.modifiedAt = now
        }
        let queueRows = try context.fetch(FetchDescriptor<CloudQueueItemProjection>())
        for row in queueRows where row.deletedAt == nil {
            row.isQueued = false
            row.deletedAt = now
            row.modifiedAt = now
        }
        if context.hasChanges { try context.save() }
        knownLocalFeedURLs.removeAll()
    }

    private static func projectionOrder(
        _ lhs: CloudPodcastProjection,
        _ rhs: CloudPodcastProjection
    ) -> Bool {
        if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt > rhs.modifiedAt }
        if lhs.sourceDeviceID != rhs.sourceDeviceID {
            return lhs.sourceDeviceID < rhs.sourceDeviceID
        }
        return FeedURLIdentity.canonical(lhs.feedURL) < FeedURLIdentity.canonical(rhs.feedURL)
    }

    private static func podcastOrder(_ lhs: Podcast, _ rhs: Podcast) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        if lhs.feedURL != rhs.feedURL { return lhs.feedURL < rhs.feedURL }
        return lhs.title < rhs.title
    }

    private static func episodeOrder(_ lhs: Episode, _ rhs: Episode) -> Bool {
        let lhsKey = episodeKey(for: lhs)
        let rhsKey = episodeKey(for: rhs)
        switch (lhsKey, rhsKey) {
        case let (lhs?, rhs?): return lhs < rhs
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return lhs.createdAt < rhs.createdAt
        }
    }

    private static func episodeProjectionOrder(
        _ lhs: CloudEpisodeStateProjection,
        _ rhs: CloudEpisodeStateProjection
    ) -> Bool {
        if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt > rhs.modifiedAt }
        if lhs.sourceDeviceID != rhs.sourceDeviceID {
            return lhs.sourceDeviceID < rhs.sourceDeviceID
        }
        return episodeKey(for: lhs) < episodeKey(for: rhs)
    }

    private static func episodeKey(for episode: Episode) -> EpisodeKey? {
        guard let feedURL = episode.podcast?.feedURL, !episode.guid.isEmpty else { return nil }
        return EpisodeKey(feedURL: FeedURLIdentity.canonical(feedURL), guid: episode.guid)
    }

    private static func episodeKey(for row: CloudEpisodeStateProjection) -> EpisodeKey {
        EpisodeKey(
            feedURL: FeedURLIdentity.canonical(row.feedURL),
            guid: row.episodeGUID
        )
    }

    private static func episodeKey(for row: CloudQueueItemProjection) -> EpisodeKey {
        EpisodeKey(
            feedURL: FeedURLIdentity.canonical(row.feedURL),
            guid: row.episodeGUID
        )
    }

    private static func queueProjectionOrder(
        _ lhs: CloudQueueItemProjection,
        _ rhs: CloudQueueItemProjection
    ) -> Bool {
        if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt > rhs.modifiedAt }
        if lhs.sourceDeviceID != rhs.sourceDeviceID {
            return lhs.sourceDeviceID < rhs.sourceDeviceID
        }
        return episodeKey(for: lhs) < episodeKey(for: rhs)
    }

    private func applicationEpisodes(matching keys: Set<EpisodeKey>) -> [EpisodeKey: Episode] {
        guard !keys.isEmpty else { return [:] }
        let keysByFeed = Dictionary(grouping: keys, by: \.feedURL)
        let context = applicationContainer.mainContext
        let podcasts = (try? context.fetch(FetchDescriptor<Podcast>())) ?? []
        var result: [EpisodeKey: Episode] = [:]
        for podcast in podcasts {
            let feed = FeedURLIdentity.canonical(podcast.feedURL)
            guard let requested = keysByFeed[feed] else { continue }
            let requestedGUIDs = Set(requested.map(\.guid))
            for episode in (podcast.episodes ?? []).sorted(by: Self.episodeOrder)
            where requestedGUIDs.contains(episode.guid) {
                let key = EpisodeKey(feedURL: feed, guid: episode.guid)
                if result[key] == nil { result[key] = episode }
            }
        }
        return result
    }

    private func applyRemoteEpisodeStates(
        appContext: ModelContext,
        cloudContext: ModelContext
    ) throws -> Bool {
        let rows = try cloudContext.fetch(FetchDescriptor<CloudEpisodeStateProjection>())
            .filter { $0.deletedAt == nil && !$0.episodeGUID.isEmpty }
        let grouped = Dictionary(grouping: rows, by: Self.episodeKey)
        let episodes = applicationEpisodes(matching: Set(grouped.keys))
        var changed = false
        for key in grouped.keys.sorted() {
            guard let episode = episodes[key], let contributions = grouped[key] else { continue }

            let playedWinner = contributions.max {
                if $0.playedUpdatedAt != $1.playedUpdatedAt {
                    return $0.playedUpdatedAt < $1.playedUpdatedAt
                }
                return $0.sourceDeviceID > $1.sourceDeviceID
            }
            let mergedPlayed = playedWinner?.isPlayed ?? false

            let resetWinner = contributions.compactMap { row in
                row.positionResetAt.map { (date: $0, row: row) }
            }.max {
                if $0.date != $1.date { return $0.date < $1.date }
                return $0.row.sourceDeviceID > $1.row.sourceDeviceID
            }
            let progress = contributions.filter {
                guard let resetWinner else { return true }
                return $0.positionUpdatedAt > resetWinner.date
            }
            let mergedPosition = mergedPlayed ? 0 : max(
                0,
                progress.map(\.positionSeconds).max()
                    ?? resetWinner?.row.positionSeconds
                    ?? 0
            )

            if mergedPlayed {
                if !episode.isPlayed {
                    episode.isPlayed = true
                    changed = true
                }
            } else if episode.isPlayed {
                episode.isPlayed = false
                changed = true
            }
            if episode.positionSeconds != mergedPosition {
                episode.positionSeconds = mergedPosition
                changed = true
            }
        }
        if appContext.hasChanges { try appContext.save() }
        return changed
    }

    private func applyRemoteQueue(
        appContext: ModelContext,
        cloudContext: ModelContext
    ) throws -> Bool {
        let rows = try cloudContext.fetch(FetchDescriptor<CloudQueueItemProjection>())
            .filter { $0.deletedAt == nil && !$0.episodeGUID.isEmpty }
        var contributionByDevice: [String: CloudQueueItemProjection] = [:]
        for row in rows.sorted(by: Self.queueProjectionOrder) {
            let key = Self.episodeKey(for: row)
            let contributionKey = "\(key.feedURL)\u{1f}\(key.guid)\u{1f}\(row.sourceDeviceID)"
            if contributionByDevice[contributionKey] == nil {
                contributionByDevice[contributionKey] = row
            } else {
                cloudContext.delete(row)
            }
        }
        let grouped = Dictionary(
            grouping: contributionByDevice.values,
            by: Self.episodeKey
        )
        var winners: [EpisodeKey: CloudQueueItemProjection] = [:]
        for (key, contributions) in grouped {
            winners[key] = contributions.sorted(by: Self.queueProjectionOrder).first
        }
        let episodes = applicationEpisodes(matching: Set(winners.keys))
        let existing = try appContext.fetch(FetchDescriptor<QueueItem>(
            sortBy: [SortDescriptor(\.position)]
        ))
        var existingByKey: [EpisodeKey: QueueItem] = [:]
        for item in existing {
            guard let episode = item.episode,
                  let key = Self.episodeKey(for: episode),
                  existingByKey[key] == nil else { continue }
            existingByKey[key] = item
        }

        var changed = false
        for key in winners.keys.sorted() {
            guard let winner = winners[key], let episode = episodes[key] else { continue }
            if winner.isQueued {
                if existingByKey[key] == nil {
                    let item = QueueItem(episode: episode, position: winner.position)
                    appContext.insert(item)
                    existingByKey[key] = item
                    changed = true
                }
                if episode.status != .inQueue {
                    episode.status = .inQueue
                    changed = true
                }
            } else if let item = existingByKey.removeValue(forKey: key) {
                appContext.delete(item)
                if episode.status == .inQueue { episode.status = .newEpisode }
                changed = true
            }
        }

        let projected = existingByKey.compactMap { key, item -> (QueueItem, Int, EpisodeKey)? in
            guard let winner = winners[key], winner.isQueued else { return nil }
            return (item, winner.position, key)
        }.sorted {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            return $0.2 < $1.2
        }.map(\.0)
        let projectedIDs = Set(projected.map(\.persistentModelID))
        let untouched = existing.filter {
            !projectedIDs.contains($0.persistentModelID) && !$0.isDeleted
        }
        let ordered = projected + untouched
        for (position, item) in ordered.enumerated() where item.position != position {
            item.position = position
            changed = true
        }
        if appContext.hasChanges { try appContext.save() }
        if cloudContext.hasChanges { try cloudContext.save() }
        return changed
    }

    private func copy(_ source: CloudPodcastProjection, to target: Podcast) {
        target.feedURL = FeedURLIdentity.canonical(source.feedURL)
        target.title = source.title
        target.author = source.author
        target.podcastDescription = source.podcastDescription
        target.artworkURL = source.artworkURL
        target.websiteURL = source.websiteURL
        target.language = source.language
        target.category = source.category
        target.autoQueue = source.autoQueue
        target.notificationEnabled = source.notificationEnabled
        target.speedOverride = source.speedOverride
        target.trimSilenceOverride = source.trimSilenceOverride
        target.introSkipSeconds = source.introSkipSeconds
        target.queueAgeLimitDays = source.queueAgeLimitDays
        target.inboxMaxEpisodes = source.inboxMaxEpisodes
        target.inboxAgeLimitHours = source.inboxAgeLimitHours
        target.inboxExcluded = source.inboxExcluded
        target.inboxIncluded = source.inboxIncluded
        target.createdAt = source.createdAt
        target.lastSeenPubDate = source.lastSeenPubDate
    }

    private func value(_ source: CloudPodcastProjection) -> PodcastValue {
        PodcastValue(
            feedURL: FeedURLIdentity.canonical(source.feedURL), title: source.title,
            author: source.author, podcastDescription: source.podcastDescription,
            artworkURL: source.artworkURL, websiteURL: source.websiteURL,
            language: source.language, category: source.category,
            autoQueue: source.autoQueue, notificationEnabled: source.notificationEnabled,
            speedOverride: source.speedOverride,
            trimSilenceOverride: source.trimSilenceOverride,
            introSkipSeconds: source.introSkipSeconds,
            queueAgeLimitDays: source.queueAgeLimitDays,
            inboxMaxEpisodes: source.inboxMaxEpisodes,
            inboxAgeLimitHours: source.inboxAgeLimitHours,
            inboxExcluded: source.inboxExcluded, inboxIncluded: source.inboxIncluded,
            createdAt: source.createdAt, lastSeenPubDate: source.lastSeenPubDate
        )
    }

    private func value(_ source: Podcast) -> PodcastValue {
        PodcastValue(
            feedURL: FeedURLIdentity.canonical(source.feedURL), title: source.title,
            author: source.author, podcastDescription: source.podcastDescription,
            artworkURL: source.artworkURL, websiteURL: source.websiteURL,
            language: source.language, category: source.category,
            autoQueue: source.autoQueue, notificationEnabled: source.notificationEnabled,
            speedOverride: source.speedOverride,
            trimSilenceOverride: source.trimSilenceOverride,
            introSkipSeconds: source.introSkipSeconds,
            queueAgeLimitDays: source.queueAgeLimitDays,
            inboxMaxEpisodes: source.inboxMaxEpisodes,
            inboxAgeLimitHours: source.inboxAgeLimitHours,
            inboxExcluded: source.inboxExcluded, inboxIncluded: source.inboxIncluded,
            createdAt: source.createdAt, lastSeenPubDate: source.lastSeenPubDate
        )
    }

    private func copy(_ source: Podcast, to target: CloudPodcastProjection) {
        target.feedURL = FeedURLIdentity.canonical(source.feedURL)
        target.title = source.title
        target.author = source.author
        target.podcastDescription = source.podcastDescription
        target.artworkURL = source.artworkURL
        target.websiteURL = source.websiteURL
        target.language = source.language
        target.category = source.category
        target.autoQueue = source.autoQueue
        target.notificationEnabled = source.notificationEnabled
        target.speedOverride = source.speedOverride
        target.trimSilenceOverride = source.trimSilenceOverride
        target.introSkipSeconds = source.introSkipSeconds
        target.queueAgeLimitDays = source.queueAgeLimitDays
        target.inboxMaxEpisodes = source.inboxMaxEpisodes
        target.inboxAgeLimitHours = source.inboxAgeLimitHours
        target.inboxExcluded = source.inboxExcluded
        target.inboxIncluded = source.inboxIncluded
        target.createdAt = source.createdAt
        target.lastSeenPubDate = source.lastSeenPubDate
        target.modifiedAt = .now
        target.deletedAt = nil
        target.sourceDeviceID = deviceID
    }
}

enum CloudProjectionDeviceIdentity {
    private static let key = "earshot_cloud_projection_device_id"

    static func value(defaults: UserDefaults = .standard) -> String {
        if let existing = defaults.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let created = UUID().uuidString
        defaults.set(created, forKey: key)
        return created
    }
}
