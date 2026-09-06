import Foundation
import Dispatch
import SwiftData

extension Notification.Name {
    static let earshotCloudProjectionDidApply = Notification.Name(
        "earshotCloudProjectionDidApply"
    )
    static let earshotCloudSettingsProjectionDidApply = Notification.Name(
        "earshotCloudSettingsProjectionDidApply"
    )
    static let earshotSubscriptionsDidChange = Notification.Name(
        "earshotSubscriptionsDidChange"
    )
    static let earshotEpisodeUserStateDidChange = Notification.Name(
        "earshotEpisodeUserStateDidChange"
    )
    static let earshotMirroredSettingDidChange = Notification.Name(
        "earshotMirroredSettingDidChange"
    )
    static let earshotFolderSyncConflictRepaired = Notification.Name(
        "earshotFolderSyncConflictRepaired"
    )
}

struct EpisodeUserStateSnapshot: Sendable, Equatable {
    let feedURL: String
    let guid: String
    let positionSeconds: Int
    let isPlayed: Bool
    let playedChangedExplicitly: Bool
    let inboxDismissed: Bool
    let inboxDismissedChangedExplicitly: Bool

    @MainActor
    init?(
        episode: Episode,
        positionSeconds: Int? = nil,
        playedChangedExplicitly: Bool = false,
        inboxDismissedChangedExplicitly: Bool = false
    ) {
        guard let podcast = episode.podcast, podcast.isFollowed,
              !episode.guid.isEmpty else { return nil }
        let feedURL = podcast.feedURL
        self.feedURL = FeedURLIdentity.canonical(feedURL)
        self.guid = episode.guid
        self.positionSeconds = max(0, positionSeconds ?? episode.positionSeconds)
        self.isPlayed = episode.isPlayed
        self.playedChangedExplicitly = playedChangedExplicitly
        self.inboxDismissed = episode.inboxDismissed
        self.inboxDismissedChangedExplicitly = inboxDismissedChangedExplicitly
    }
}

@MainActor
func postEpisodeUserStateSnapshots(_ snapshots: [EpisodeUserStateSnapshot]) {
    guard !snapshots.isEmpty else { return }
    NotificationCenter.default.post(
        name: .earshotEpisodeUserStateDidChange,
        object: snapshots
    )
}

@MainActor
func postEpisodeUserStateChanges(
    _ episodes: [Episode],
    playedChangedExplicitly: Bool = false,
    inboxDismissedChangedExplicitly: Bool = false
) {
    let snapshots = episodes.compactMap {
        EpisodeUserStateSnapshot(
            episode: $0,
            playedChangedExplicitly: playedChangedExplicitly,
            inboxDismissedChangedExplicitly: inboxDismissedChangedExplicitly
        )
    }
    postEpisodeUserStateSnapshots(snapshots)
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
    var inboxDismissed: Bool = false
    /// Independent last-write-wins clock for explicit Inbox dismissal or a
    /// later feed-authored re-entry. Legacy rows stay at distantPast and do not
    /// alter Inbox membership.
    var inboxDismissedUpdatedAt: Date = Date.distantPast
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
    // Queue membership must remain usable when the destination's deliberately
    // local, bounded episode catalog has not retained this episode. These
    // optional fields let reconciliation create one dismissed episode shell;
    // legacy projection rows remain readable and simply wait for a feed fetch.
    var episodeTitle: String?
    var episodeAudioURL: String?
    var episodeDescription: String?
    var episodeDurationSeconds: Int?
    var episodePubDate: Date?
    var episodeArtworkURL: String?
    var episodeNumber: Int?
    var episodeSeasonNumber: Int?
    var episodeChapterURL: String?
    var episodeTranscriptURL: String?
    var sourceDeviceID: String = ""
    var isQueued: Bool = false
    var position: Int = 0
    /// Clock for the listener's add/remove decision. Kept separate from
    /// ``modifiedAt`` so a stale device merely reordering its queue cannot turn
    /// an older `isQueued = true` contribution into a newer membership decision
    /// and resurrect an episode another device explicitly removed.
    var membershipUpdatedAt: Date = Date.distantPast
    var modifiedAt: Date = Date.distantPast
    var deletedAt: Date?

    init() {}
}

@Model
final class CloudSettingProjection {
    var key: String = ""
    var value: String = ""
    var sourceDeviceID: String = ""
    var modifiedAt: Date = Date.distantPast
    var deletedAt: Date?

    init() {}
}

@Model
final class CloudBookmarkProjection {
    var bookmarkID: String = ""
    var feedURL: String = ""
    var episodeGUID: String = ""
    var positionSeconds: Int = 0
    var note: String = ""
    var createdAt: Date = Date.distantPast
    var modifiedAt: Date = Date.distantPast
    var deletedAt: Date?
    var sourceDeviceID: String = ""

    init() {}
}

@Model
final class CloudListeningSessionProjection {
    var sessionID: String = ""
    var feedURL: String = ""
    var episodeGUID: String?
    var durationSeconds: Int = 0
    var speed: Double = 1
    var date: Date = Date.distantPast
    var modifiedAt: Date = Date.distantPast
    var deletedAt: Date?
    var sourceDeviceID: String = ""

    init() {}
}

private struct CloudFolderPodcastMember: Codable, Equatable {
    let feedURL: String
    let sortOrder: Int
}

private struct CloudFolderEpisodeMember: Codable, Equatable {
    let feedURL: String
    let guid: String
    let sortOrder: Int
}

@Model
final class CloudFolderProjection {
    var folderID: String = ""
    var name: String = ""
    var sortOrder: Int = 0
    var queueAgeLimitDays: Int?
    var createdAt: Date = Date.distantPast
    var parentFolderID: String?
    var podcastMembersJSON: String = "[]"
    var episodeMembersJSON: String = "[]"
    var modifiedAt: Date = Date.distantPast
    var deletedAt: Date?
    var sourceDeviceID: String = ""

    init() {}
}

struct CompactProjectionSeedCounts: Codable, Equatable, Sendable {
    let podcasts: Int
    let episodeStates: Int
    let queueItems: Int
    let settings: Int
    let bookmarks: Int
    let listeningSessions: Int
    let folders: Int
}

enum CompactProjectionSeedMarker: Equatable, Sendable {
    case start(runID: String)
    case complete(runID: String, durationSeconds: Double, counts: CompactProjectionSeedCounts)
    case failure(runID: String, durationSeconds: Double, error: String)
}

actor CloudProjectionCoordinator: ModelActor {
    /// Marks UI change notifications emitted while applying remote projection
    /// state. NotificationCenter delivers the observer on the main queue and
    /// then hops back to this actor; checking `isApplyingRemote` after that hop
    /// is too late because reconciliation may already have ended. Carry the
    /// origin with the event so UI consumers still refresh without feeding the
    /// projection's own write back into another reconciliation pass.
    nonisolated static let notificationOriginKey =
        "media.payown.earshot.cloud-projection-origin"

    nonisolated static func isProjectionOriginated(_ notification: Notification) -> Bool {
        notification.userInfo?[notificationOriginKey] as? Bool == true
    }

    /// Actor isolation alone does not promise a background thread. Under launch
    /// pressure Swift's cooperative executor can run this actor on the main
    /// thread, which makes otherwise-correct SwiftData reconciliation block
    /// VoiceOver gestures. Pin the actor to a background serial executor while
    /// retaining the single-writer ordering required by the projection stores.
    nonisolated private let executionQueue: DispatchSerialQueue
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        executionQueue.asUnownedSerialExecutor()
    }
    nonisolated let modelExecutor: any ModelExecutor
    nonisolated let modelContainer: ModelContainer
    /// Initial subscription projection is restartable at natural-key boundaries.
    /// Checkpoint frequently enough that a force quit replays at most this many
    /// small, relationship-free rows rather than one all-or-nothing library seed.
    private static let subscriptionBackfillSaveBatchSize = 50
    /// Listening history may predate CloudKit activation. Checkpoint missing
    /// semantic rows so an interrupted first reconciliation resumes without
    /// replaying one unbounded save or duplicating already durable sessions.
    private static let listeningHistoryBackfillSaveBatchSize = 50
    static let storeURL = URL.applicationSupportDirectory
        .appending(path: "earshot-cloud-projection.store")

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

    private struct EpisodeKey: Hashable, Comparable, Sendable {
        let feedURL: String
        let guid: String

        static func < (lhs: EpisodeKey, rhs: EpisodeKey) -> Bool {
            if lhs.feedURL != rhs.feedURL { return lhs.feedURL < rhs.feedURL }
            return lhs.guid < rhs.guid
        }
    }

    /// Relationship-free queue state crossing from the projection actor to the
    /// application-store writer. SwiftData models must never cross this boundary:
    /// another context may delete their relationship rows while this actor is
    /// suspended.
    private struct RemoteQueuePlan: Sendable {
        struct Entry: Sendable {
            let key: EpisodeKey
            let isQueued: Bool
            let membershipUpdatedAt: Date
            let membershipModifiedAt: Date
            let membershipSourceDeviceID: String
            let position: Int
            let positionModifiedAt: Date
            let positionSourceDeviceID: String
            let metadata: EpisodeMetadata?
        }

        struct EpisodeMetadata: Sendable {
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

        let entries: [Entry]
        let currentDeviceID: String
    }

    /// A value snapshot of one local history row. Relationship objects may be
    /// SwiftData future faults whose stored-property getters trap when their
    /// destination row was deleted by an older build. Persistent identifiers
    /// remain safe to carry into an independent resolver context.
    private struct LocalListeningSessionSnapshot {
        let session: ListeningSession
        let directPodcastID: PersistentIdentifier?
        let episodeID: PersistentIdentifier?
        let durationSeconds: Int
        let speed: Double
        let date: Date
    }

    private struct ResolvedListeningSession {
        let session: ListeningSession
        let feedURL: String
        let episodeGUID: String?
        let durationSeconds: Int
        let speed: Double
        let date: Date
    }

    private struct EpisodeIdentity {
        let guid: String
        let podcastID: PersistentIdentifier?
    }

    /// Resolves relationship identifiers in a private context so the partial
    /// Podcast fetches used by large-library reconciliation never poison the
    /// application context's relationship faults. No stored property is read
    /// from a Podcast or Episode object reached through ListeningSession.
    private final class ListeningHistoryIdentityResolver {
        private let context: ModelContext
        private var feedURLByPodcastID: [PersistentIdentifier: String] = [:]
        private var episodeByID: [PersistentIdentifier: EpisodeIdentity] = [:]
        private var missingEpisodeIDs: Set<PersistentIdentifier> = []

        init(container: ModelContainer) throws {
            context = ModelContext(container)
            context.autosaveEnabled = false
            var descriptor = FetchDescriptor<Podcast>()
            descriptor.propertiesToFetch = [\Podcast.feedURL]
            for podcast in try context.fetch(descriptor) {
                feedURLByPodcastID[podcast.persistentModelID] = podcast.feedURL
            }
        }

        func feedURL(for podcastID: PersistentIdentifier) -> String? {
            feedURLByPodcastID[podcastID]
        }

        func episode(for episodeID: PersistentIdentifier) throws -> EpisodeIdentity? {
            if let cached = episodeByID[episodeID] { return cached }
            if missingEpisodeIDs.contains(episodeID) { return nil }
            var descriptor = FetchDescriptor<Episode>(
                predicate: #Predicate { $0.persistentModelID == episodeID }
            )
            descriptor.fetchLimit = 1
            guard let episode = try context.fetch(descriptor).first else {
                missingEpisodeIDs.insert(episodeID)
                return nil
            }
            let identity = EpisodeIdentity(
                guid: episode.guid,
                podcastID: episode.podcast?.persistentModelID
            )
            episodeByID[episodeID] = identity
            return identity
        }
    }

    private let projectionContainer: ModelContainer
    private let projectionContext: ModelContext
    private let center: NotificationCenter
    private var importObserver: NSObjectProtocol?
    private var subscriptionObserver: NSObjectProtocol?
    private var episodeObserver: NSObjectProtocol?
    private var catalogObserver: NSObjectProtocol?
    private var queueObserver: NSObjectProtocol?
    private var settingObserver: NSObjectProtocol?
    private var bookmarkObserver: NSObjectProtocol?
    private var historyObserver: NSObjectProtocol?
    private var folderObserver: NSObjectProtocol?
    private var reconcileTask: Task<Void, Never>?
    private var pendingRemotePodcastDeletionFeedURLs: Set<String> = []
    private var knownLocalFeedURLs: Set<String> = []
    private var knownLocalBookmarkIDs: Set<String> = []
    private var knownLocalSessionIDs: Set<String> = []
    private var knownLocalFolderIDs: Set<String> = []
    private let deviceID: String
    private let seedInstrumentationEnabled: @Sendable () -> Bool
    private let seedMarkerRecorder: @Sendable (CompactProjectionSeedMarker) -> Void
    private let remotePodcastDeletionDelayNanoseconds: UInt64
    private let pendingFollowFeedURLs: @Sendable (ModelContext) throws -> Set<String>
    private let followActivationCheckpoint: @Sendable (String) throws -> Void
    private let pendingIntentSave: @Sendable (ModelContext) throws -> Void
    private let remoteSubscriptionSave: @Sendable (ModelContext) throws -> Void
    private let queueApplicationCheckpoint: (@Sendable (String) async throws -> Void)?
    private var isApplyingRemote = false

    private init(
        applicationContainer: ModelContainer,
        projectionContainer: ModelContainer,
        center: NotificationCenter = .default,
        deviceID: String = CloudProjectionDeviceIdentity.value(),
        seedInstrumentationEnabled: @escaping @Sendable () -> Bool = {
            CloudKitLaunchPolicy.isMirroringEnabled()
        },
        seedMarkerRecorder: @escaping @Sendable (CompactProjectionSeedMarker) -> Void = {
            CloudProjectionCoordinator.recordSeedMarker($0)
        },
        remotePodcastDeletionDelayNanoseconds: UInt64 = 0,
        pendingFollowFeedURLs: @escaping @Sendable (ModelContext) throws -> Set<String> = {
            try PendingCloudFollowIntent.feedURLs(in: $0)
        },
        followActivationCheckpoint: @escaping @Sendable (String) throws -> Void = { _ in },
        pendingIntentSave: @escaping @Sendable (ModelContext) throws -> Void = { try $0.save() },
        remoteSubscriptionSave: @escaping @Sendable (ModelContext) throws -> Void = {
            try $0.save()
        },
        queueApplicationCheckpoint: (@Sendable (String) async throws -> Void)? = nil
    ) {
        executionQueue = DispatchSerialQueue(
            label: "media.payown.earshot.cloud-projection",
            qos: .background
        )
        let applicationContext = ModelContext(applicationContainer)
        modelExecutor = DefaultSerialModelExecutor(modelContext: applicationContext)
        modelContainer = applicationContainer
        self.projectionContainer = projectionContainer
        projectionContext = ModelContext(projectionContainer)
        self.center = center
        self.deviceID = deviceID
        self.seedInstrumentationEnabled = seedInstrumentationEnabled
        self.seedMarkerRecorder = seedMarkerRecorder
        self.remotePodcastDeletionDelayNanoseconds = remotePodcastDeletionDelayNanoseconds
        self.pendingFollowFeedURLs = pendingFollowFeedURLs
        self.followActivationCheckpoint = followActivationCheckpoint
        self.pendingIntentSave = pendingIntentSave
        self.remoteSubscriptionSave = remoteSubscriptionSave
        self.queueApplicationCheckpoint = queueApplicationCheckpoint
    }

    nonisolated static func make(
        applicationContainer: ModelContainer
    ) async throws -> CloudProjectionCoordinator {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let schema = Schema([
                        CloudPodcastProjection.self,
                        CloudEpisodeStateProjection.self,
                        CloudQueueItemProjection.self,
                        CloudSettingProjection.self,
                        CloudBookmarkProjection.self,
                        CloudListeningSessionProjection.self,
                        CloudFolderProjection.self,
                    ])
                    let configuration = ModelConfiguration(
                        "CloudProjection",
                        schema: schema,
                        url: storeURL,
                        cloudKitDatabase: CloudKitLaunchPolicy.projectionDatabase()
                    )
                    let projectionContainer = try ModelContainer(
                        for: schema,
                        configurations: configuration
                    )
                    continuation.resume(returning: CloudProjectionCoordinator(
                        applicationContainer: applicationContainer,
                        projectionContainer: projectionContainer,
                        // SwiftUI can keep an outgoing VoiceOver row alive for part of the
                        // navigation-pop transition. Stop playback and dismiss first, then
                        // let that transition finish before the cascade invalidates the
                        // row's SwiftData models.
                        remotePodcastDeletionDelayNanoseconds: 750_000_000
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

#if DEBUG
    func executorRunsOnMainThreadForTesting() -> Bool {
        Thread.isMainThread
    }

    nonisolated static func makeForTesting(
        applicationContainer: ModelContainer,
        projectionContainer: ModelContainer,
        center: NotificationCenter = .default,
        deviceID: String = CloudProjectionDeviceIdentity.value(),
        seedInstrumentationEnabled: @escaping @Sendable () -> Bool = { false },
        seedMarkerRecorder: @escaping @Sendable (CompactProjectionSeedMarker) -> Void = { _ in },
        remotePodcastDeletionDelayNanoseconds: UInt64 = 0,
        pendingFollowFeedURLs: @escaping @Sendable (ModelContext) throws -> Set<String> = {
            try PendingCloudFollowIntent.feedURLs(in: $0)
        },
        followActivationCheckpoint: @escaping @Sendable (String) throws -> Void = { _ in },
        pendingIntentSave: @escaping @Sendable (ModelContext) throws -> Void = { try $0.save() },
        remoteSubscriptionSave: @escaping @Sendable (ModelContext) throws -> Void = {
            try $0.save()
        },
        queueApplicationCheckpoint: (@Sendable (String) async throws -> Void)? = nil
    ) async -> CloudProjectionCoordinator {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: CloudProjectionCoordinator(
                    applicationContainer: applicationContainer,
                    projectionContainer: projectionContainer,
                    center: center,
                    deviceID: deviceID,
                    seedInstrumentationEnabled: seedInstrumentationEnabled,
                    seedMarkerRecorder: seedMarkerRecorder,
                    remotePodcastDeletionDelayNanoseconds: remotePodcastDeletionDelayNanoseconds,
                    pendingFollowFeedURLs: pendingFollowFeedURLs,
                    followActivationCheckpoint: followActivationCheckpoint,
                    pendingIntentSave: pendingIntentSave,
                    remoteSubscriptionSave: remoteSubscriptionSave,
                    queueApplicationCheckpoint: queueApplicationCheckpoint
                ))
            }
        }
    }
#endif

    func start(performInitialReconciliation: Bool = true) async throws {
        refreshContextsFromStore()
        guard importObserver == nil else { return }
        importObserver = center.addObserver(
            forName: .earshotCloudKitImportDidFinish,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.scheduleReconciliation() }
        }
        subscriptionObserver = center.addObserver(
            forName: .earshotSubscriptionsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let changedFeedURL = notification.object as? String
            let settingsOnly = notification.userInfo?[PodcastSettingsPersistence.settingsOnlyKey] as? Bool == true
            Task {
                await self?.handleLocalSubscriptionChange(
                    feedURL: changedFeedURL, settingsOnly: settingsOnly
                )
            }
        }
        episodeObserver = center.addObserver(
            forName: .earshotEpisodeUserStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let snapshots = notification.object as? [EpisodeUserStateSnapshot],
                  !snapshots.isEmpty else { return }
            Task { await self?.handleLocalEpisodeStateChanges(snapshots) }
        }
        // Feed refresh uses this existing event after its store save. Running
        // reconciliation on the next main-actor turn lets a newly refetched
        // episode receive any CloudKit state that arrived before its metadata.
        catalogObserver = center.addObserver(
            forName: .earshotInboxDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard !Self.isProjectionOriginated(notification) else { return }
            Task { await self?.scheduleReconciliationUnlessApplyingRemote() }
        }
        queueObserver = center.addObserver(
            forName: .earshotQueueDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard !Self.isProjectionOriginated(notification) else { return }
            Task { await self?.handleLocalQueueChange() }
        }
        settingObserver = center.addObserver(
            forName: .earshotMirroredSettingDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let key = notification.object as? String else { return }
            Task { await self?.handleLocalSettingChange(key) }
        }
        bookmarkObserver = center.addObserver(
            forName: .earshotBookmarksDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.handleLocalBookmarkChange() }
        }
        historyObserver = center.addObserver(
            forName: .earshotListeningHistoryDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.handleLocalListeningHistoryChange() }
        }
        folderObserver = center.addObserver(
            forName: .earshotFoldersDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.handleLocalFolderChange() }
        }
        guard performInitialReconciliation else { return }
        guard seedInstrumentationEnabled() else {
            try await reconcile()
            return
        }
        let runID = UUID().uuidString
        let clock = ContinuousClock()
        let started = clock.now
        seedMarkerRecorder(.start(runID: runID))
        do {
            try await reconcile()
            seedMarkerRecorder(.complete(
                runID: runID,
                durationSeconds: Self.seconds(clock.now - started),
                counts: try compactProjectionCounts()
            ))
        } catch {
            seedMarkerRecorder(.failure(
                runID: runID,
                durationSeconds: Self.seconds(clock.now - started),
                error: error.localizedDescription
            ))
            throw error
        }
    }

    private func handleLocalSubscriptionChange(feedURL: String?, settingsOnly: Bool) {
        guard !isApplyingRemote else { return }
        do {
            try publishLocalSubscriptionGraphChange(feedURL: feedURL)
            // A saved scalar edit only needs its outbound projection. Full
            // reconciliation republishes every subscription and defeats the
            // targeted path. Graph changes and remote imports still reconcile.
            if !settingsOnly || feedURL == nil { scheduleReconciliation() }
        } catch {
            AppLog.data.error(
                "Cloud subscription projection failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func publishLocalSubscriptionGraphChange(feedURL: String?) throws {
        if let feedURL {
            try publishLocalSubscriptionChange(feedURL: feedURL)
        } else {
            try publishLocalSubscriptionChanges()
        }
    }

    private func handleLocalEpisodeStateChanges(_ snapshots: [EpisodeUserStateSnapshot]) {
        guard !isApplyingRemote else { return }
        do {
            try publishLocalEpisodeStateChanges(snapshots: snapshots)
        } catch {
            AppLog.data.error(
                "Cloud episode-state projection failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func scheduleReconciliationUnlessApplyingRemote() {
        // Reconciliation itself posts the Inbox notification after applying
        // remote state. Only an external catalog refresh needs another pass.
        guard !isApplyingRemote else { return }
        scheduleReconciliation()
    }

    private func handleLocalQueueChange() {
        guard !isApplyingRemote else { return }
        do { try publishLocalQueueChanges() }
        catch {
            AppLog.data.error(
                "Cloud queue projection failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func handleLocalSettingChange(_ key: String) {
        guard !isApplyingRemote else { return }
        do { try publishLocalSettingChange(key: key) }
        catch {
            AppLog.data.error(
                "Cloud setting projection failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func handleLocalBookmarkChange() {
        guard !isApplyingRemote else { return }
        do { try publishLocalBookmarkChanges() }
        catch {
            AppLog.data.error(
                "Cloud bookmark projection failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func handleLocalListeningHistoryChange() {
        guard !isApplyingRemote else { return }
        do { try publishLocalListeningHistoryChanges() }
        catch {
            AppLog.data.error(
                "Cloud listening-history projection failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func handleLocalFolderChange() {
        guard !isApplyingRemote else { return }
        do { try publishLocalFolderChanges() }
        catch {
            AppLog.data.error(
                "Cloud folder projection failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func compactProjectionCounts() throws -> CompactProjectionSeedCounts {
        let context = projectionContext
        return try CompactProjectionSeedCounts(
            podcasts: context.fetchCount(FetchDescriptor<CloudPodcastProjection>()),
            episodeStates: context.fetchCount(FetchDescriptor<CloudEpisodeStateProjection>()),
            queueItems: context.fetchCount(FetchDescriptor<CloudQueueItemProjection>()),
            settings: context.fetchCount(FetchDescriptor<CloudSettingProjection>()),
            bookmarks: context.fetchCount(FetchDescriptor<CloudBookmarkProjection>()),
            listeningSessions: context.fetchCount(FetchDescriptor<CloudListeningSessionProjection>()),
            folders: context.fetchCount(FetchDescriptor<CloudFolderProjection>())
        )
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    private static func recordSeedMarker(_ marker: CompactProjectionSeedMarker) {
        do {
            try CompactProjectionSeedMarkerStore().record(marker)
        } catch {
            AppLog.data.error(
                "compact-projection-seed-marker-persist-failed error=\(error.localizedDescription, privacy: .public)"
            )
        }
        switch marker {
        case .start(let runID):
            AppLog.data.notice(
                "compact-projection-seed-start runID=\(runID, privacy: .public)"
            )
        case .complete(let runID, let duration, let counts):
            AppLog.data.notice(
                "compact-projection-seed-complete runID=\(runID, privacy: .public) durationSeconds=\(duration, privacy: .public) podcasts=\(counts.podcasts, privacy: .public) episodeStates=\(counts.episodeStates, privacy: .public) queueItems=\(counts.queueItems, privacy: .public) settings=\(counts.settings, privacy: .public) bookmarks=\(counts.bookmarks, privacy: .public) listeningSessions=\(counts.listeningSessions, privacy: .public) folders=\(counts.folders, privacy: .public)"
            )
        case .failure(let runID, let duration, let error):
            AppLog.data.error(
                "compact-projection-seed-failed runID=\(runID, privacy: .public) durationSeconds=\(duration, privacy: .public) error=\(error, privacy: .public)"
            )
        }
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
        if let settingObserver {
            center.removeObserver(settingObserver)
            self.settingObserver = nil
        }
        if let bookmarkObserver {
            center.removeObserver(bookmarkObserver)
            self.bookmarkObserver = nil
        }
        if let historyObserver {
            center.removeObserver(historyObserver)
            self.historyObserver = nil
        }
        if let folderObserver {
            center.removeObserver(folderObserver)
            self.folderObserver = nil
        }
        reconcileTask?.cancel()
        _ = await reconcileTask?.value
        reconcileTask = nil
    }

    private func scheduleReconciliation() {
        guard reconcileTask == nil else { return }
        reconcileTask = Task { [weak self] in
            await self?.runScheduledReconciliation()
        }
    }

    /// Starts the cold-launch pass without making RootView's main-actor
    /// activation await it. The detached caller supplies background priority;
    /// the coordinator retains the child so `stop()` can still cancel and join
    /// it during reset or account replacement.
    nonisolated func scheduleInitialReconciliationInBackground() {
        Task.detached(priority: .background) { [weak self] in
            await self?.scheduleReconciliation()
        }
    }

    private func runScheduledReconciliation() async {
        defer { reconcileTask = nil }
        do {
            try await reconcile()
        } catch {
            AppLog.data.error(
                "Cloud projection reconciliation failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// External application and CloudKit contexts can save while this actor is
    /// idle. Drop only clean registered-object caches before each entry point so
    /// retained SwiftData faults cannot hide a newer cross-context save.
    private func refreshContextsFromStore() {
        if !modelContext.hasChanges { modelContext.rollback() }
        if !projectionContext.hasChanges { projectionContext.rollback() }
    }

    /// Applies an active remote subscription under the same canonical identity
    /// gate used by local Follow and catalog queue materialization. A catalog
    /// shell is promoted in place and receives a distinct restart marker in the
    /// same application-store save; the remote row remains the subscription
    /// authority and is never retimestamped as a local Follow.
    private func applyRemoteActiveSubscription(feedURL: String) async throws -> Bool {
        let feed = FeedURLIdentity.canonical(feedURL)
        await PodcastIdentityWriteGate.shared.acquire(feedURLs: [feed])
        do {
            try Task.checkCancellation()
            let changed = try applyRemoteActiveSubscriptionWhileLocked(feedURL: feed)
            await PodcastIdentityWriteGate.shared.release(feedURLs: [feed])
            return changed
        } catch {
            modelContext.rollback()
            await PodcastIdentityWriteGate.shared.release(feedURLs: [feed])
            throw error
        }
    }

    private func applyRemoteActiveSubscriptionWhileLocked(feedURL feed: String) throws -> Bool {
        refreshContextsFromStore()
        guard let remote = try projectionContext
            .fetch(FetchDescriptor<CloudPodcastProjection>())
            .filter({ FeedURLIdentity.canonical($0.feedURL) == feed })
            .sorted(by: Self.projectionOrder)
            .first,
            remote.deletedAt == nil else { return false }
        guard try !PendingCloudUnfollowIntent.feedURLs(in: modelContext).contains(feed) else {
            return false
        }

        // Destructive duplicate repair retains its established pre-delete
        // protocol and commits as a prerequisite. Promotion itself remains
        // one rollback-safe save with no irreversible pre-save notification.
        let repair = try IdentityRepairService(context: modelContext)
            .repair(feedURLs: [feed])
        if repair.didChange { try remoteSubscriptionSave(modelContext) }

        let identity = PodcastIdentityService(context: modelContext)
        let existing = try identity.existingAnyState(feedURL: feed)
        let wasCatalogOnly = existing.map { !$0.isFollowed } ?? false
        let podcast = existing ?? {
            let inserted = Podcast(feedURL: feed, title: remote.title, createdAt: remote.createdAt)
            modelContext.insert(inserted)
            return inserted
        }()
        let before = value(podcast)
        copy(remote, to: podcast)
        if wasCatalogOnly {
            podcast.subscriptionStateRaw = nil
            try PendingCloudRemoteActivationIntent.set(feedURL: feed, in: modelContext)
        }
        let changed = existing == nil || wasCatalogOnly || before != value(podcast)
        if modelContext.hasChanges { try remoteSubscriptionSave(modelContext) }
        return changed
    }

    /// Applies remote subscriptions before projecting local subscriptions. An
    /// empty new device therefore cannot overwrite a populated account.
    func reconcile() async throws {
        refreshContextsFromStore()
        guard !isApplyingRemote else { return }
        isApplyingRemote = true
        defer { isApplyingRemote = false }
        try publishPendingUnfollowIntents()
        refreshContextsFromStore()
        let activeRemoteFeeds: [String]
        do {
            let cloudContext = projectionContext
            let cloudRows = try cloudContext.fetch(FetchDescriptor<CloudPodcastProjection>())
            var feeds: Set<String> = []
            var seen: Set<String> = []
            for row in cloudRows.sorted(by: Self.projectionOrder) {
                let key = FeedURLIdentity.canonical(row.feedURL)
                if seen.insert(key).inserted {
                    if row.deletedAt == nil { feeds.insert(key) }
                } else {
                    cloudContext.delete(row)
                }
            }
            if cloudContext.hasChanges { try cloudContext.save() }
            activeRemoteFeeds = feeds.sorted()
        }
        var applicationChanged = false
        for feedURL in activeRemoteFeeds {
            applicationChanged = try await applyRemoteActiveSubscription(feedURL: feedURL)
                || applicationChanged
        }
        refreshContextsFromStore()
        let appContext = modelContext
        let cloudContext = projectionContext
        let cloudRows = try cloudContext.fetch(FetchDescriptor<CloudPodcastProjection>())
        var cloudByFeed: [String: CloudPodcastProjection] = [:]
        for row in cloudRows.sorted(by: Self.projectionOrder) {
            let key = FeedURLIdentity.canonical(row.feedURL)
            if cloudByFeed[key] == nil { cloudByFeed[key] = row }
        }

        let podcastIdentity = PodcastIdentityService(context: appContext)
        var localByFeed = try podcastIdentity.existingAnyStateByCanonicalFeedURL(
            for: Array(cloudByFeed.keys)
        )
        let pendingFollowFeeds = try pendingFollowFeedURLs(appContext)
        for row in cloudByFeed.values.sorted(by: Self.projectionOrder) {
            let key = FeedURLIdentity.canonical(row.feedURL)
            if row.deletedAt != nil {
                if let podcast = localByFeed[key], podcast.isFollowed {
                    if pendingFollowFeeds.contains(key) {
                        continue
                    }
                    if remotePodcastDeletionDelayNanoseconds == 0 {
                        // Tests and non-UI coordinators retain deterministic,
                        // synchronous reconciliation.
                        applicationChanged = SubscriptionDeletionRepository(context: appContext)
                            .unsubscribe(podcast) || applicationChanged
                    } else {
                        scheduleRemotePodcastDeletion(podcast, feedURL: row.feedURL)
                        applicationChanged = true
                    }
                }
                continue
            }
            let podcast: Podcast
            if let existing = localByFeed[key] {
                guard existing.isFollowed else { continue }
                podcast = existing
            } else {
                podcast = Podcast(feedURL: key, title: row.title, createdAt: row.createdAt)
                appContext.insert(podcast)
                localByFeed[key] = podcast
                applicationChanged = true
            }
            if value(row) != value(podcast) {
                copy(row, to: podcast)
            }
        }
        applicationChanged = try removeOrphanedLibraryRows(in: appContext)
            || applicationChanged
        if appContext.hasChanges {
            try appContext.save()
            applicationChanged = true
        }

        let podcasts = try podcastIdentity.allScalarPodcasts()
            .filter(\.isFollowed)
            .sorted { FeedURLIdentity.canonical($0.feedURL) < FeedURLIdentity.canonical($1.feedURL) }
        var subscriptionRowsSinceSave = 0
        for podcast in podcasts {
            let key = FeedURLIdentity.canonical(podcast.feedURL)
            var insertedRow = false
            let row = cloudByFeed[key] ?? {
                let inserted = CloudPodcastProjection()
                inserted.feedURL = key
                cloudContext.insert(inserted)
                cloudByFeed[key] = inserted
                insertedRow = true
                return inserted
            }()
            var changedRow = insertedRow
            let hasPendingFollow = pendingFollowFeeds.contains(key)
            if row.deletedAt != nil, hasPendingFollow {
                row.deletedAt = nil
                row.modifiedAt = .now
                row.sourceDeviceID = deviceID
                changedRow = true
            }
            guard row.deletedAt == nil else { continue }
            if hasPendingFollow, row.sourceDeviceID != deviceID {
                row.sourceDeviceID = deviceID
                row.modifiedAt = .now
                changedRow = true
            }
            if value(podcast) != value(row) {
                copy(podcast, to: row)
                changedRow = true
            }
            if changedRow { subscriptionRowsSinceSave += 1 }
            if subscriptionRowsSinceSave >= Self.subscriptionBackfillSaveBatchSize {
                try cloudContext.save()
                subscriptionRowsSinceSave = 0
            }
        }
        if cloudContext.hasChanges { try cloudContext.save() }
        try clearPublishedFollowIntents(
            feedURLs: Set(podcasts.map { FeedURLIdentity.canonical($0.feedURL) }),
            activeProjectionFeedURLs: Set(cloudByFeed.values.compactMap {
                $0.deletedAt == nil ? FeedURLIdentity.canonical($0.feedURL) : nil
            }),
            appContext: appContext
        )
        try publishPendingRemoteActivations()
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
            postProjectionChange(.earshotInboxDidChange)
        }
        try publishLocalQueueChanges(now: .now, onlyIfCloudEmpty: true)
        let queueChanged = try await applyRemoteQueue(
            appContext: appContext,
            cloudContext: cloudContext
        )
        applicationChanged = queueChanged || applicationChanged
        if queueChanged {
            postProjectionChange(.earshotQueueDidChange)
            postProjectionChange(.earshotInboxDidChange)
        }
        try publishLocalSettings(onlyIfCloudEmpty: true)
        let settingsChanged = try applyRemoteSettings(
            appContext: appContext,
            cloudContext: cloudContext
        )
        applicationChanged = settingsChanged || applicationChanged
        if settingsChanged {
            center.post(name: .earshotCloudSettingsProjectionDidApply, object: nil)
        }
        let bookmarkChanged = try applyRemoteBookmarks(
            appContext: appContext,
            cloudContext: cloudContext
        )
        try publishLocalBookmarkChanges(now: .now, onlyIfCloudEmpty: true)
        applicationChanged = bookmarkChanged || applicationChanged
        let historyChanged = try applyRemoteListeningHistory(
            appContext: appContext,
            cloudContext: cloudContext
        )
        try publishLocalListeningHistoryChanges(now: .now)
        applicationChanged = historyChanged || applicationChanged
        let folderChanged = try applyRemoteFolders(
            appContext: appContext,
            cloudContext: cloudContext
        )
        try publishLocalFolderChanges(now: .now, onlyIfCloudEmpty: true)
        applicationChanged = folderChanged || applicationChanged
        if applicationChanged {
            center.post(name: .earshotCloudProjectionDidApply, object: nil)
        }
    }

    private func postProjectionChange(_ name: Notification.Name) {
        center.post(
            name: name,
            object: nil,
            userInfo: [Self.notificationOriginKey: true]
        )
    }

    /// A remote tombstone can arrive while the deleted podcast's episode list is
    /// still on screen. Notify the player and presentation synchronously, then
    /// postpone the destructive cascade until SwiftUI has completed its pop
    /// transition. Otherwise VoiceOver may request a final label from an Episode
    /// that SwiftData invalidated between two property reads.
    private func scheduleRemotePodcastDeletion(_ podcast: Podcast, feedURL: String) {
        let key = FeedURLIdentity.canonical(feedURL)
        guard pendingRemotePodcastDeletionFeedURLs.insert(key).inserted else { return }

        center.post(
            name: .earshotWillDeleteEpisodes,
            object: nil,
            userInfo: [PlayerService.willDeletePodcastIDKey: podcast.persistentModelID]
        )

        let deletionDelay = remotePodcastDeletionDelayNanoseconds
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: deletionDelay)
            await self?.finishRemotePodcastDeletion(key: key)
        }
    }

    private func finishRemotePodcastDeletion(key: String) async {
        defer { pendingRemotePodcastDeletionFeedURLs.remove(key) }

        // Cold-launch feed refresh and CloudKit import can begin together. Let
        // any refresh unwind before deleting its Podcast, or that refresh can
        // save newly fetched Episodes after the cascade and leave them detached.
        await BackgroundFeedRefresher.cancelAndWait()

        // A rapid refollow may clear the tombstone while dismissal is in flight.
        let rows = (try? projectionContext.fetch(
            FetchDescriptor<CloudPodcastProjection>()
        )) ?? []
        guard rows.contains(where: {
            FeedURLIdentity.canonical($0.feedURL) == key && $0.deletedAt != nil
        }) else { return }
        do {
            guard try !pendingFollowFeedURLs(modelContext).contains(key) else {
                return
            }
        } catch {
            AppLog.data.error(
                "Remote subscription deletion intent check failed: \(error.localizedDescription, privacy: .public)"
            )
            return
        }
        guard let current = try? PodcastIdentityService(context: modelContext)
            .existingFollowed(feedURL: key) else { return }

        isApplyingRemote = true
        let changed = SubscriptionDeletionRepository(context: modelContext)
            .unsubscribe(current)
        let removedOrphans = (try? removeOrphanedLibraryRows(in: modelContext)) ?? false
        if modelContext.hasChanges { try? modelContext.save() }
        isApplyingRemote = false
        if changed || removedOrphans {
            center.post(name: .earshotCloudProjectionDidApply, object: nil)
        }
    }

    /// Removes invalid residue from a refresh that raced an older build's
    /// remote-unfollow cascade. Episodes cannot be useful without a Podcast,
    /// and unsubscribe intentionally removes that podcast's listening history.
    private func removeOrphanedLibraryRows(in context: ModelContext) throws -> Bool {
        let history = try resolvedLocalListeningSessions(in: context)
        let sessions = try context.fetch(FetchDescriptor<ListeningSession>(
            predicate: #Predicate { $0.podcast == nil }
        ))
        let episodes = try context.fetch(FetchDescriptor<Episode>(
            predicate: #Predicate { $0.podcast == nil }
        ))
        let episodeIDs = Set(episodes.map(\.persistentModelID))
        if !episodeIDs.isEmpty {
            center.post(
                name: .earshotWillDeleteEpisodes,
                object: nil,
                userInfo: [PlayerService.willDeleteEpisodeIDsKey: episodeIDs]
            )
        }
        for session in sessions where !session.isDeleted { context.delete(session) }
        for episode in episodes { context.delete(episode) }
        return history.repaired || !sessions.isEmpty || !episodes.isEmpty
    }

    /// Builds semantic history values without ever reading a stored property on
    /// a model reached through a ListeningSession relationship. This is the
    /// build-205 crash boundary: a dangling Podcast future fault allowed the
    /// relationship getter to return an object, then trapped at `feedURL`.
    ///
    /// A valid Episode can repair a missing direct Podcast relationship. A valid
    /// Podcast preserves a session whose Episode was deleted. Only a row with no
    /// surviving Podcast identity is irrecoverable and removed; a remote active
    /// projection can recreate it later from its scalar feed URL.
    private func resolvedLocalListeningSessions(
        in context: ModelContext
    ) throws -> (sessions: [ResolvedListeningSession], repaired: Bool) {
        let resolver = try ListeningHistoryIdentityResolver(container: modelContainer)
        var descriptor = FetchDescriptor<ListeningSession>()
        descriptor.propertiesToFetch = [
            \ListeningSession.episode,
            \ListeningSession.podcast,
            \ListeningSession.durationSeconds,
            \ListeningSession.speed,
            \ListeningSession.date,
        ]
        let snapshots = try context.fetch(descriptor).map { session in
            LocalListeningSessionSnapshot(
                session: session,
                directPodcastID: session.podcast?.persistentModelID,
                episodeID: session.episode?.persistentModelID,
                durationSeconds: session.durationSeconds,
                speed: session.speed,
                date: session.date
            )
        }
        var repaired = false
        var resolved: [ResolvedListeningSession] = []
        resolved.reserveCapacity(snapshots.count)

        for snapshot in snapshots {
            let episode = try snapshot.episodeID.flatMap { try resolver.episode(for: $0) }
            let directFeedURL = snapshot.directPodcastID.flatMap(resolver.feedURL(for:))
            let episodeFeedURL = episode?.podcastID.flatMap(resolver.feedURL(for:))
            guard let feedURL = directFeedURL ?? episodeFeedURL,
                  let podcastID = directFeedURL == nil
                    ? episode?.podcastID : snapshot.directPodcastID else {
                context.delete(snapshot.session)
                repaired = true
                continue
            }

            if directFeedURL == nil {
                var podcastDescriptor = FetchDescriptor<Podcast>(
                    predicate: #Predicate { $0.persistentModelID == podcastID }
                )
                podcastDescriptor.fetchLimit = 1
                snapshot.session.podcast = try context.fetch(podcastDescriptor).first
                repaired = true
            }
            if snapshot.episodeID != nil, episode == nil {
                snapshot.session.episode = nil
                repaired = true
            }
            resolved.append(ResolvedListeningSession(
                session: snapshot.session,
                feedURL: feedURL,
                episodeGUID: episode?.guid,
                durationSeconds: snapshot.durationSeconds,
                speed: snapshot.speed,
                date: snapshot.date
            ))
        }
        return (resolved, repaired)
    }

    /// Writes only meaningful, user-authored episode state. A 232,000-row feed
    /// catalog with one played episode therefore produces one state row, not a
    /// second copy of the catalog.
    func publishLocalEpisodeStateChanges(
        now: Date = .now,
        onlyMissingOwnRows: Bool = false,
        activatingFeedURL: String? = nil
    ) throws {
        refreshContextsFromStore()
        let appContext = modelContext
        let cloudContext = projectionContext
        let activationFeed = activatingFeedURL.map(FeedURLIdentity.canonical)
        let meaningful = try appContext.fetch(FetchDescriptor<Episode>(
            predicate: #Predicate {
                $0.positionSeconds > 0 || $0.playedAt != nil
            }
        ))
        var localByKey: [EpisodeKey: Episode] = [:]
        for episode in meaningful.sorted(by: Self.episodeOrder) {
            guard episode.podcast?.isFollowed == true,
                  let key = Self.episodeKey(for: episode),
                  activationFeed == nil || key.feedURL == activationFeed else { continue }
            if localByKey[key] == nil { localByKey[key] = episode }
        }

        let rows = try cloudContext.fetch(FetchDescriptor<CloudEpisodeStateProjection>())
        var ownByKey: [EpisodeKey: CloudEpisodeStateProjection] = [:]
        for row in rows
            .filter({ $0.sourceDeviceID == deviceID && $0.deletedAt == nil })
            .filter({ activationFeed == nil || Self.episodeKey(for: $0).feedURL == activationFeed })
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
        let existingForOwnKeys = onlyMissingOwnRows
            ? [:] : applicationEpisodes(matching: Set(ownByKey.keys))
        let keys = Set(localByKey.keys).union(ownByKey.keys).sorted()
        for key in keys {
            if onlyMissingOwnRows, ownByKey[key] != nil { continue }
            guard let episode = localByKey[key] ?? existingForOwnKeys[key] else {
                continue
            }
            let row: CloudEpisodeStateProjection
            if let existing = ownByKey[key] {
                row = existing
            } else {
                let inserted = CloudEpisodeStateProjection()
                inserted.feedURL = key.feedURL
                inserted.episodeGUID = key.guid
                inserted.sourceDeviceID = deviceID
                inserted.positionUpdatedAt = now
                inserted.playedUpdatedAt = episode.isPlayed ? now : .distantPast
                cloudContext.insert(inserted)
                ownByKey[key] = inserted
                row = inserted
            }
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
        if activationFeed != nil {
            for row in rows where row.sourceDeviceID == deviceID
                && Self.episodeKey(for: row).feedURL == activationFeed
                && localByKey[Self.episodeKey(for: row)] == nil && row.deletedAt == nil {
                row.deletedAt = now
                row.modifiedAt = now
            }
        }
        if cloudContext.hasChanges { try cloudContext.save() }
    }
    private func prepareQueueProjectionBootstrapIfNeeded(
        now: Date,
        appContext: ModelContext,
        cloudRows: [CloudQueueItemProjection]
    ) throws {
        guard try !PendingCloudQueueMutation.bootstrapCompleted(in: appContext) else { return }

        let activeRows = cloudRows.filter { $0.deletedAt == nil && !$0.episodeGUID.isEmpty }
        let projectedKeys = Set(activeRows.map(Self.episodeKey))
        let pendingMembershipKeys = Set(
            try PendingCloudQueueMutation.memberships(in: appContext).map {
                EpisodeKey(feedURL: $0.feedURL, guid: $0.guid)
            }
        )
        let items = try appContext.fetch(FetchDescriptor<QueueItem>())
        var current: [EpisodeKey: Episode] = [:]
        for item in items {
            guard let episode = item.episode,
                  episode.podcast?.isFollowed == true,
                  let key = Self.episodeKey(for: episode) else { continue }
            current[key] = episode
        }
        var stagedMembership = false
        for key in current.keys {
            guard !pendingMembershipKeys.contains(key),
                  !projectedKeys.contains(key) else { continue }
            PendingCloudQueueMutation.stageMembership(
                feedURL: key.feedURL,
                guid: key.guid,
                isQueued: true,
                eventDate: now,
                in: appContext
            )
            stagedMembership = true
        }
        if stagedMembership {
            PendingCloudQueueMutation.stageOrdering(eventDate: now, in: appContext)
        }
        // Keep bootstrap open until the first projection import/seed exists.
        if !cloudRows.isEmpty {
            try PendingCloudQueueMutation.markBootstrapCompleted(in: appContext)
        }
        do {
            if appContext.hasChanges { try appContext.save() }
        } catch {
            appContext.rollback()
            throw error
        }
    }

    func publishLocalQueueChanges(
        now: Date = .now,
        onlyIfCloudEmpty: Bool = false,
        activatingFeedURL: String? = nil
    ) throws {
        refreshContextsFromStore()
        let appContext = modelContext
        let cloudContext = projectionContext
        let activationFeed = activatingFeedURL.map(FeedURLIdentity.canonical)
        let allRows = try cloudContext.fetch(FetchDescriptor<CloudQueueItemProjection>())
        let rows = allRows.filter {
            activationFeed == nil || Self.episodeKey(for: $0).feedURL == activationFeed
        }
        if activationFeed == nil {
            try prepareQueueProjectionBootstrapIfNeeded(
                now: now,
                appContext: appContext,
                cloudRows: allRows
            )
        }

        let items = try appContext.fetch(FetchDescriptor<QueueItem>(
            sortBy: [SortDescriptor(\.position)]
        ))
        var current: [EpisodeKey: (position: Int, episode: Episode)] = [:]
        for item in items {
            guard let episode = item.episode else {
                AppLog.data.error(
                    "Queue projection skipped unprojectable item at position \(item.position, privacy: .public); missing usable episode or feed key"
                )
                continue
            }
            guard episode.podcast?.isFollowed == true else { continue }
            guard let key = Self.episodeKey(for: episode) else {
                AppLog.data.error(
                    "Queue projection skipped unprojectable item at position \(item.position, privacy: .public); missing usable episode or feed key"
                )
                continue
            }
            guard activationFeed == nil || key.feedURL == activationFeed else { continue }
            guard current[key] == nil else { continue }
            current[key] = (item.position, episode)
        }
        let observedMemberships = activationFeed == nil
            ? try PendingCloudQueueMutation.memberships(in: appContext) : []
        let observedOrderings = activationFeed == nil
            ? try PendingCloudQueueMutation.orderings(in: appContext) : []
        var membershipByKey: [EpisodeKey: PendingCloudQueueMutation.Membership] = [:]
        for intent in observedMemberships {
            let key = EpisodeKey(feedURL: intent.feedURL, guid: intent.guid)
            if let existing = membershipByKey[key],
               existing.eventDate > intent.eventDate
                || (existing.eventDate == intent.eventDate && existing.token < intent.token) {
                continue
            }
            membershipByKey[key] = intent
        }
        let orderingDate = observedOrderings.max {
            if $0.eventDate != $1.eventDate { return $0.eventDate < $1.eventDate }
            return $0.token > $1.token
        }?.eventDate

        if onlyIfCloudEmpty, !rows.isEmpty,
           membershipByKey.isEmpty, orderingDate == nil {
            for row in rows where row.sourceDeviceID == deviceID && row.deletedAt == nil {
                guard let item = current[Self.episodeKey(for: row)] else { continue }
                Self.copyEpisodeMetadata(item.episode, to: row)
            }
            if cloudContext.hasChanges { try cloudContext.save() }
            return
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
        let activeByKey = Dictionary(grouping: rows.filter { $0.deletedAt == nil }, by: Self.episodeKey)
        var membershipWinnerByKey: [EpisodeKey: CloudQueueItemProjection] = [:]
        for (key, contributions) in activeByKey {
            membershipWinnerByKey[key] = contributions.sorted(by: Self.queueMembershipOrder).first
        }

        let cloudWasEmptySeed = onlyIfCloudEmpty && rows.isEmpty
        var keys: Set<EpisodeKey>
        if activationFeed != nil || cloudWasEmptySeed {
            keys = Set(ownByKey.keys).union(current.keys)
        } else {
            keys = Set(ownByKey.keys).union(membershipByKey.keys)
            if orderingDate != nil { keys.formUnion(current.keys) }
        }
        for key in keys.sorted() {
            var intent = membershipByKey[key]
            let item = current[key]
            let inheritedWinner = membershipWinnerByKey[key]
            if ownByKey[key] == nil, intent == nil,
               activationFeed == nil, !cloudWasEmptySeed {
                // Ordering may adopt only a remote affirmative and its original clock.
                guard inheritedWinner?.isQueued == true, item != nil else { continue }
            }
            let row: CloudQueueItemProjection
            let insertedRow: Bool
            if let existing = ownByKey[key] {
                row = existing
                insertedRow = false
            } else {
                let inserted = CloudQueueItemProjection()
                inserted.feedURL = key.feedURL
                inserted.episodeGUID = key.guid
                inserted.sourceDeviceID = deviceID
                cloudContext.insert(inserted)
                ownByKey[key] = inserted
                row = inserted
                insertedRow = true
            }
            let existingMembershipDate = row.membershipUpdatedAt == .distantPast
                ? row.modifiedAt : row.membershipUpdatedAt
            var ignoredStaleIntent = false
            if let candidate = intent, !insertedRow,
               candidate.eventDate < existingMembershipDate {
                // Never let an older retry rewind saved local membership.
                intent = nil
                ignoredStaleIntent = true
            }
            let snapshotOwnsMembership = activationFeed != nil || cloudWasEmptySeed
            let queued: Bool
            if ignoredStaleIntent {
                queued = row.isQueued
            } else if let intent {
                queued = intent.isQueued
            } else if snapshotOwnsMembership {
                queued = item != nil
            } else if insertedRow, inheritedWinner?.isQueued == true, item != nil {
                queued = true
            } else {
                // Absence is not removal without a durable local intent.
                queued = row.isQueued
            }
            let position = item?.position ?? 0
            if let episode = item?.episode {
                Self.copyEpisodeMetadata(episode, to: row)
            }
            let membershipChanged = insertedRow || intent != nil
                || row.isQueued != queued || row.deletedAt != nil
            let mayPublishPosition = activationFeed != nil || cloudWasEmptySeed
                || orderingDate != nil || intent?.isQueued == true
            let positionChanged = mayPublishPosition && row.position != position
            if membershipChanged || positionChanged {
                row.isQueued = queued
                if mayPublishPosition { row.position = position }
                row.deletedAt = nil
                if membershipChanged {
                    row.membershipUpdatedAt = intent?.eventDate
                        ?? inheritedWinner.map {
                            $0.membershipUpdatedAt == .distantPast
                                ? $0.modifiedAt : $0.membershipUpdatedAt
                        }
                        ?? now
                }
                // Position uses the later event without advancing membership's clock.
                row.modifiedAt = [
                    intent?.eventDate,
                    mayPublishPosition ? orderingDate : nil,
                ].compactMap { $0 }.max() ?? now
            } else if row.modifiedAt == .distantPast {
                row.modifiedAt = now
            }
            // Legacy rows predate the independent membership clock. Preserve
            // their last-writer-wins meaning once, then future order-only edits
            // leave this clock untouched.
            if row.membershipUpdatedAt == .distantPast {
                row.membershipUpdatedAt = row.modifiedAt
            }
        }
        if cloudContext.hasChanges { try cloudContext.save() }
        guard activationFeed == nil,
              !observedMemberships.isEmpty || !observedOrderings.isEmpty else { return }
        do {
            try PendingCloudQueueMutation.clear(
                memberships: observedMemberships,
                orderings: observedOrderings,
                in: appContext
            )
            if appContext.hasChanges { try appContext.save() }
        } catch {
            appContext.rollback()
            throw error
        }
    }
    func publishLocalSettings(
        now: Date = .now,
        onlyIfCloudEmpty: Bool = false,
        activatingFeedURL: String? = nil
    ) throws {
        refreshContextsFromStore()
        let appContext = modelContext
        let cloudContext = projectionContext
        let rows = try cloudContext.fetch(FetchDescriptor<CloudSettingProjection>())
        if onlyIfCloudEmpty, !rows.isEmpty { return }
        let settings = try appContext.fetch(FetchDescriptor<AppSetting>())
        let followedFeeds = try followedFeedURLs(in: appContext)
        var publishedKeys: Set<String> = []
        for setting in settings where AppSettingScope.isMirrored(setting.key)
            && Self.settingBelongsToFollowedPodcast(setting.key, followedFeeds: followedFeeds)
            && Self.setting(setting.key, isActivatedBy: activatingFeedURL) {
            guard let projectedValue = Self.projectedSettingValue(
                key: setting.key,
                value: setting.value,
                followedFeeds: followedFeeds
            ) else { continue }
            publishedKeys.insert(AppSettingIdentity.canonicalKey(setting.key))
            try publishLocalSettingChange(
                key: setting.key,
                value: projectedValue,
                now: now,
                rows: rows,
                cloudContext: cloudContext
            )
        }
        if activatingFeedURL != nil {
            for row in rows where row.sourceDeviceID == deviceID && row.deletedAt == nil
                && row.key != SettingsKey.morningLineup
                && Self.setting(row.key, isActivatedBy: activatingFeedURL)
                && !publishedKeys.contains(AppSettingIdentity.canonicalKey(row.key)) {
                row.deletedAt = now
                row.modifiedAt = now
            }
        }
        if cloudContext.hasChanges { try cloudContext.save() }
    }

    func publishLocalSettingChange(key: String, now: Date = .now) throws {
        refreshContextsFromStore()
        guard AppSettingScope.isMirrored(key) else { return }
        let canonical = AppSettingIdentity.canonicalKey(key)
        let appContext = modelContext
        let followedFeeds = try followedFeedURLs(in: appContext)
        guard Self.settingBelongsToFollowedPodcast(
            canonical,
            followedFeeds: followedFeeds
        ) else { return }
        guard let value = AppSettingIdentity.value(for: canonical, in: appContext),
              let projectedValue = Self.projectedSettingValue(
                  key: canonical,
                  value: value,
                  followedFeeds: followedFeeds
              ) else { return }
        let cloudContext = projectionContext
        let rows = try cloudContext.fetch(FetchDescriptor<CloudSettingProjection>())
        try publishLocalSettingChange(
            key: canonical,
            value: projectedValue,
            now: now,
            rows: rows,
            cloudContext: cloudContext
        )
        if cloudContext.hasChanges { try cloudContext.save() }
    }
    func publishLocalBookmarkChanges(
        now: Date = .now,
        onlyIfCloudEmpty: Bool = false,
        activatingFeedURL: String? = nil
    ) throws {
        refreshContextsFromStore()
        let appContext = modelContext
        let cloudContext = projectionContext
        let activationFeed = activatingFeedURL.map(FeedURLIdentity.canonical)
        let rows = try cloudContext.fetch(FetchDescriptor<CloudBookmarkProjection>()).filter {
            activationFeed == nil || FeedURLIdentity.canonical($0.feedURL) == activationFeed
        }
        if onlyIfCloudEmpty, !rows.isEmpty { return }
        let bookmarks = try appContext.fetch(FetchDescriptor<Bookmark>())
        var activeBySemanticKey: [String: CloudBookmarkProjection] = [:]
        for row in rows.filter({ $0.deletedAt == nil }).sorted(by: Self.bookmarkProjectionOrder) {
            let key = Self.bookmarkSemanticKey(row)
            if activeBySemanticKey[key] == nil { activeBySemanticKey[key] = row }
        }
        var currentIDs: Set<String> = []
        for bookmark in bookmarks.sorted(by: { $0.createdAt < $1.createdAt }) {
            guard let episode = bookmark.episode,
                  episode.podcast?.isFollowed == true,
                  let feedURL = episode.podcast?.feedURL,
                  !episode.guid.isEmpty,
                  activationFeed == nil || FeedURLIdentity.canonical(feedURL) == activationFeed
            else { continue }
            let key = Self.bookmarkSemanticKey(
                feedURL: feedURL,
                guid: episode.guid,
                position: bookmark.positionSeconds,
                createdAt: bookmark.createdAt
            )
            let row: CloudBookmarkProjection
            if let existing = activeBySemanticKey[key] {
                row = existing
            } else {
                let inserted = CloudBookmarkProjection()
                inserted.bookmarkID = UUID().uuidString.lowercased()
                inserted.feedURL = FeedURLIdentity.canonical(feedURL)
                inserted.episodeGUID = episode.guid
                inserted.positionSeconds = max(0, bookmark.positionSeconds)
                inserted.createdAt = bookmark.createdAt
                inserted.sourceDeviceID = deviceID
                cloudContext.insert(inserted)
                activeBySemanticKey[key] = inserted
                row = inserted
            }
            currentIDs.insert(row.bookmarkID)
            if row.note != bookmark.note || row.modifiedAt == .distantPast {
                row.note = bookmark.note
                row.modifiedAt = now
            }
        }
        if activationFeed != nil {
            for row in rows where row.sourceDeviceID == deviceID
                && !currentIDs.contains(row.bookmarkID) && row.deletedAt == nil {
                row.deletedAt = now
                row.modifiedAt = now
            }
            knownLocalBookmarkIDs.formUnion(currentIDs)
        } else if !onlyIfCloudEmpty, !knownLocalBookmarkIDs.isEmpty {
            for row in rows where knownLocalBookmarkIDs.contains(row.bookmarkID)
                && !currentIDs.contains(row.bookmarkID) && row.deletedAt == nil {
                row.deletedAt = now
                row.modifiedAt = now
            }
        }
        if activationFeed == nil { knownLocalBookmarkIDs = currentIDs }
        if cloudContext.hasChanges { try cloudContext.save() }
    }
    func publishLocalListeningHistoryChanges(
        now: Date = .now, activatingFeedURL: String? = nil
    ) throws {
        refreshContextsFromStore()
        let appContext = modelContext
        let cloudContext = projectionContext
        let activationFeed = activatingFeedURL.map(FeedURLIdentity.canonical)
        let rows = try cloudContext.fetch(FetchDescriptor<CloudListeningSessionProjection>()).filter {
            activationFeed == nil || FeedURLIdentity.canonical($0.feedURL) == activationFeed
        }
        let local = try resolvedLocalListeningSessions(in: appContext)
        if local.repaired, appContext.hasChanges { try appContext.save() }
        var activeByKey: [String: CloudListeningSessionProjection] = [:]
        for row in rows.filter({ $0.deletedAt == nil }).sorted(by: Self.sessionProjectionOrder) {
            let key = Self.sessionSemanticKey(row)
            if activeByKey[key] == nil { activeByKey[key] = row }
        }
        var currentIDs: Set<String> = []
        var insertedRowsSinceSave = 0
        let followedFeeds = try followedFeedURLs(in: appContext)
        for session in local.sessions
            .filter({
                let feed = FeedURLIdentity.canonical($0.feedURL)
                return followedFeeds.contains(feed) && (activationFeed == nil || feed == activationFeed)
            })
            .sorted(by: { $0.date < $1.date }) {
            let key = Self.sessionSemanticKey(
                feedURL: session.feedURL,
                guid: session.episodeGUID,
                duration: session.durationSeconds,
                speed: session.speed,
                date: session.date
            )
            let row: CloudListeningSessionProjection
            if let existing = activeByKey[key] {
                row = existing
            } else {
                let inserted = CloudListeningSessionProjection()
                inserted.sessionID = UUID().uuidString.lowercased()
                inserted.feedURL = FeedURLIdentity.canonical(session.feedURL)
                inserted.episodeGUID = session.episodeGUID
                inserted.durationSeconds = max(0, session.durationSeconds)
                inserted.speed = session.speed
                inserted.date = session.date
                inserted.modifiedAt = now
                inserted.sourceDeviceID = deviceID
                cloudContext.insert(inserted)
                activeByKey[key] = inserted
                insertedRowsSinceSave += 1
                row = inserted
            }
            currentIDs.insert(row.sessionID)
            if insertedRowsSinceSave >= Self.listeningHistoryBackfillSaveBatchSize {
                try cloudContext.save()
                insertedRowsSinceSave = 0
            }
        }
        if activationFeed != nil {
            for row in rows where row.sourceDeviceID == deviceID
                && !currentIDs.contains(row.sessionID) && row.deletedAt == nil {
                row.deletedAt = now
                row.modifiedAt = now
            }
        } else if !knownLocalSessionIDs.isEmpty {
            for row in rows where knownLocalSessionIDs.contains(row.sessionID)
                && !currentIDs.contains(row.sessionID) && row.deletedAt == nil {
                row.deletedAt = now
                row.modifiedAt = now
            }
        }
        if activationFeed == nil { knownLocalSessionIDs = currentIDs }
        if cloudContext.hasChanges { try cloudContext.save() }
    }

    func publishLocalFolderChanges(
        now: Date = .now,
        onlyIfCloudEmpty: Bool = false,
        activatingFeedURL: String? = nil
    ) throws {
        refreshContextsFromStore()
        let appContext = modelContext
        let cloudContext = projectionContext
        let rows = try cloudContext.fetch(FetchDescriptor<CloudFolderProjection>())
        if onlyIfCloudEmpty, !rows.isEmpty { return }
        let allFolders = try appContext.fetch(FetchDescriptor<PodcastFolder>())
        let podcastMemberships = try appContext.fetch(FetchDescriptor<FolderMembership>())
        let episodeMemberships = try appContext.fetch(FetchDescriptor<EpisodeFolderMembership>())
        let activationFeed = activatingFeedURL.map(FeedURLIdentity.canonical)
        if let activationFeed {
            for row in rows where row.sourceDeviceID == deviceID && row.deletedAt == nil {
                let podcasts = Self.decodeJSON(
                    [CloudFolderPodcastMember].self, from: row.podcastMembersJSON
                ) ?? []
                let episodes = Self.decodeJSON(
                    [CloudFolderEpisodeMember].self, from: row.episodeMembersJSON
                ) ?? []
                let keptPodcasts = podcasts.filter { $0.feedURL != activationFeed }
                let keptEpisodes = episodes.filter { $0.feedURL != activationFeed }
                if keptPodcasts.count != podcasts.count || keptEpisodes.count != episodes.count {
                    row.podcastMembersJSON = try Self.jsonString(keptPodcasts)
                    row.episodeMembersJSON = try Self.jsonString(keptEpisodes)
                    row.modifiedAt = now
                }
            }
        }
        var relevantFolderIDs: Set<PersistentIdentifier> = []
        if let activationFeed {
            for membership in podcastMemberships
            where membership.podcast.map({ FeedURLIdentity.canonical($0.feedURL) }) == activationFeed {
                if let folder = membership.folder { relevantFolderIDs.insert(folder.persistentModelID) }
            }
            for membership in episodeMemberships
            where membership.episode?.podcast.map({ FeedURLIdentity.canonical($0.feedURL) }) == activationFeed {
                if let folder = membership.folder { relevantFolderIDs.insert(folder.persistentModelID) }
            }
            var changed = true
            while changed {
                changed = false
                for folder in allFolders where relevantFolderIDs.contains(folder.persistentModelID) {
                    if let parent = folder.parent,
                       relevantFolderIDs.insert(parent.persistentModelID).inserted { changed = true }
                }
            }
        }
        let folders = activationFeed == nil
            ? allFolders : allFolders.filter { relevantFolderIDs.contains($0.persistentModelID) }
        let podcastMembershipsByFolderID = Dictionary(grouping: podcastMemberships) {
            $0.folder?.persistentModelID
        }
        var activeByCreatedAt: [UInt64: CloudFolderProjection] = [:]
        for row in rows.filter({ $0.deletedAt == nil }).sorted(by: Self.folderProjectionOrder) {
            let key = row.createdAt.timeIntervalSinceReferenceDate.bitPattern
            if activeByCreatedAt[key] == nil { activeByCreatedAt[key] = row }
        }
        var rowByFolderID: [PersistentIdentifier: CloudFolderProjection] = [:]
        for folder in folders.sorted(by: Self.folderOrder) {
            let key = folder.createdAt.timeIntervalSinceReferenceDate.bitPattern
            let row: CloudFolderProjection
            if let existing = activeByCreatedAt[key] {
                row = existing
            } else {
                let inserted = CloudFolderProjection()
                inserted.folderID = UUID().uuidString.lowercased()
                inserted.createdAt = folder.createdAt
                inserted.sourceDeviceID = deviceID
                cloudContext.insert(inserted)
                activeByCreatedAt[key] = inserted
                row = inserted
            }
            rowByFolderID[folder.persistentModelID] = row
        }
        var currentIDs: Set<String> = []
        for folder in folders.sorted(by: Self.folderOrder) {
            guard let row = rowByFolderID[folder.persistentModelID] else { continue }
            if activationFeed != nil, row.sourceDeviceID != deviceID { row.sourceDeviceID = deviceID; row.modifiedAt = now }
            currentIDs.insert(row.folderID)
            // Do not fault PodcastFolder.memberships here. A first production
            // reconciliation after V5 migration can otherwise populate large
            // inverse graphs synchronously on the main actor (build 202
            // watchdog incident). Direct join-row fetches stay proportional to
            // the small membership table rather than the episode catalog.
            let podcastMembers = podcastMembershipsByFolderID[folder.persistentModelID, default: []]
                .compactMap { membership -> CloudFolderPodcastMember? in
                guard let podcast = membership.podcast, podcast.isFollowed else { return nil }
                let feedURL = podcast.feedURL
                return CloudFolderPodcastMember(
                    feedURL: FeedURLIdentity.canonical(feedURL),
                    sortOrder: membership.sortOrder
                )
            }.sorted {
                if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
                return $0.feedURL < $1.feedURL
            }
            let episodeMembers = episodeMemberships.compactMap { membership -> CloudFolderEpisodeMember? in
                guard membership.folder?.persistentModelID == folder.persistentModelID,
                      let episode = membership.episode,
                      episode.podcast?.isFollowed == true,
                      let feedURL = episode.podcast?.feedURL else { return nil }
                return CloudFolderEpisodeMember(
                    feedURL: FeedURLIdentity.canonical(feedURL),
                    guid: episode.guid,
                    sortOrder: membership.sortOrder
                )
            }.sorted {
                if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
                if $0.feedURL != $1.feedURL { return $0.feedURL < $1.feedURL }
                return $0.guid < $1.guid
            }
            let podcastJSON = try Self.jsonString(podcastMembers)
            let episodeJSON = try Self.jsonString(episodeMembers)
            let parentID = folder.parent.flatMap { rowByFolderID[$0.persistentModelID]?.folderID }
            if row.name != folder.name || row.sortOrder != folder.sortOrder
                || row.queueAgeLimitDays != folder.queueAgeLimitDays
                || row.parentFolderID != parentID
                || row.podcastMembersJSON != podcastJSON
                || row.episodeMembersJSON != episodeJSON
                || row.deletedAt != nil {
                row.name = folder.name
                row.sortOrder = folder.sortOrder
                row.queueAgeLimitDays = folder.queueAgeLimitDays
                row.parentFolderID = parentID
                row.podcastMembersJSON = podcastJSON
                row.episodeMembersJSON = episodeJSON
                row.modifiedAt = now
                row.deletedAt = nil
            } else if row.modifiedAt == .distantPast {
                row.modifiedAt = now
            }
        }
        if activationFeed == nil, !onlyIfCloudEmpty, !knownLocalFolderIDs.isEmpty {
            for row in rows where knownLocalFolderIDs.contains(row.folderID)
                && !currentIDs.contains(row.folderID) && row.deletedAt == nil {
                row.deletedAt = now
                row.modifiedAt = now
            }
        }
        if activationFeed == nil { knownLocalFolderIDs = currentIDs }
        if cloudContext.hasChanges { try cloudContext.save() }
    }

    private func publishLocalSettingChange(
        key: String,
        value: String,
        now: Date,
        rows: [CloudSettingProjection],
        cloudContext: ModelContext
    ) throws {
        let canonical = AppSettingIdentity.canonicalKey(key)
        let matches = rows.filter {
            AppSettingIdentity.canonicalKey($0.key) == canonical
                && $0.sourceDeviceID == deviceID
                && $0.deletedAt == nil
        }.sorted(by: Self.settingProjectionOrder)
        let row = matches.first ?? {
            let inserted = CloudSettingProjection()
            inserted.key = canonical
            inserted.sourceDeviceID = deviceID
            cloudContext.insert(inserted)
            return inserted
        }()
        for duplicate in matches.dropFirst() { cloudContext.delete(duplicate) }
        if row.value != value || row.deletedAt != nil || row.modifiedAt == .distantPast {
            row.key = canonical
            row.value = value
            row.modifiedAt = now
            row.deletedAt = nil
        }
    }

    /// O(number of changed episodes) hot path used by playback and explicit
    /// actions. It never scans the feed catalog when a position anchor saves.
    func publishLocalEpisodeStateChanges(
        snapshots: [EpisodeUserStateSnapshot],
        now: Date = .now
    ) throws {
        refreshContextsFromStore()
        guard !snapshots.isEmpty else { return }
        let cloudContext = projectionContext
        let changedGUIDs = Array(Set(snapshots.map(\.guid)))
        let sourceDeviceID = deviceID
        let rows = try cloudContext.fetch(FetchDescriptor<CloudEpisodeStateProjection>(
            predicate: #Predicate {
                $0.sourceDeviceID == sourceDeviceID
                    && $0.deletedAt == nil
                    && changedGUIDs.contains($0.episodeGUID)
            }
        ))
        var ownByKey: [EpisodeKey: CloudEpisodeStateProjection] = [:]
        for row in rows
            .sorted(by: Self.episodeProjectionOrder) {
            let key = Self.episodeKey(for: row)
            if ownByKey[key] == nil {
                ownByKey[key] = row
            } else {
                cloudContext.delete(row)
            }
        }
        var latestByKey: [EpisodeKey: EpisodeUserStateSnapshot] = [:]
        let followedFeeds = try followedFeedURLs(in: modelContext)
        for snapshot in snapshots {
            let key = EpisodeKey(
                feedURL: FeedURLIdentity.canonical(snapshot.feedURL),
                guid: snapshot.guid
            )
            guard followedFeeds.contains(key.feedURL) else { continue }
            latestByKey[key] = snapshot
        }
        for key in latestByKey.keys.sorted() {
            guard let snapshot = latestByKey[key] else { continue }
            let row: CloudEpisodeStateProjection
            if let existing = ownByKey[key] {
                row = existing
            } else {
                let inserted = CloudEpisodeStateProjection()
                inserted.feedURL = key.feedURL
                inserted.episodeGUID = key.guid
                inserted.sourceDeviceID = deviceID
                inserted.positionUpdatedAt = now
                inserted.isPlayed = snapshot.isPlayed
                inserted.playedUpdatedAt = snapshot.isPlayed
                    || snapshot.playedChangedExplicitly ? now : .distantPast
                inserted.inboxDismissed = snapshot.inboxDismissed
                inserted.inboxDismissedUpdatedAt = snapshot.inboxDismissedChangedExplicitly
                    ? now : .distantPast
                cloudContext.insert(inserted)
                ownByKey[key] = inserted
                row = inserted
            }
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
            if snapshot.inboxDismissedChangedExplicitly {
                row.inboxDismissed = snapshot.inboxDismissed
                row.inboxDismissedUpdatedAt = now
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
        refreshContextsFromStore()
        try publishPendingUnfollowIntents()
        refreshContextsFromStore()
        let appContext = modelContext
        let cloudContext = projectionContext
        let podcasts = try PodcastIdentityService(context: appContext)
            .allScalarPodcasts()
            .filter(\.isFollowed)
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
        let pendingFollowFeeds = try pendingFollowFeedURLs(appContext)

        for (key, podcast) in localByFeed {
            let row: CloudPodcastProjection
            if let existing = cloudByFeed[key] {
                row = existing
            } else {
                let inserted = CloudPodcastProjection()
                inserted.feedURL = key
                cloudContext.insert(inserted)
                cloudByFeed[key] = inserted
                row = inserted
            }
            let hasPendingFollow = pendingFollowFeeds.contains(key)
            let needsCopy: Bool
            if row.deletedAt != nil || hasPendingFollow {
                needsCopy = true
            } else {
                let localValue = value(podcast)
                let projectedValue = value(row)
                needsCopy = localValue != projectedValue
            }
            if needsCopy {
                copy(podcast, to: row)
                row.deletedAt = nil
                row.modifiedAt = now
                row.sourceDeviceID = deviceID
            }
        }

        let ownActiveFeedURLs = Set(cloudByFeed.compactMap { key, row in
            row.sourceDeviceID == deviceID && row.deletedAt == nil ? key : nil
        })
        for key in knownLocalFeedURLs.union(ownActiveFeedURLs).subtracting(localByFeed.keys) {
            guard let row = cloudByFeed[key] else { continue }
            row.deletedAt = now
            row.modifiedAt = now
            row.sourceDeviceID = deviceID
        }
        if cloudContext.hasChanges { try cloudContext.save() }
        try clearPublishedFollowIntents(
            feedURLs: Set(localByFeed.keys),
            activeProjectionFeedURLs: Set(cloudByFeed.values.compactMap {
                $0.deletedAt == nil ? FeedURLIdentity.canonical($0.feedURL) : nil
            }),
            appContext: appContext
        )
        knownLocalFeedURLs = Set(localByFeed.keys)
    }

    /// Updates one subscription projection without walking the full library.
    /// Player controls use this path for per-podcast settings that can change
    /// repeatedly while a slider is adjusted. Both lookups use stable feed URL
    /// keys, keeping the work independent of library size.
    func publishLocalSubscriptionChange(feedURL: String, now: Date = .now) throws {
        refreshContextsFromStore()
        let requestedFeed = FeedURLIdentity.canonical(feedURL)
        if try PendingCloudUnfollowIntent.feedURLs(in: modelContext).contains(requestedFeed) {
            try publishPendingUnfollowIntents(feedURLs: [requestedFeed])
            return
        }
        let appContext = modelContext
        let cloudContext = projectionContext
        let podcast = try PodcastIdentityService(context: appContext)
            .existingAnyState(feedURL: feedURL)
        let canonicalFeedURL = FeedURLIdentity.canonical(podcast?.feedURL ?? feedURL)
        var projectionDescriptor = FetchDescriptor<CloudPodcastProjection>(
            predicate: #Predicate { $0.feedURL == canonicalFeedURL }
        )
        projectionDescriptor.fetchLimit = 1
        let existingRow = try cloudContext.fetch(projectionDescriptor).first
        guard let podcast, podcast.isFollowed else {
            // Catalog identity is local-only. Preserve any remote subscription
            // record for a later explicit promotion instead of treating the
            // hidden application row as an Unfollow.
            knownLocalFeedURLs.remove(canonicalFeedURL)
            return
        }
        let row = existingRow ?? {
            let inserted = CloudPodcastProjection()
            inserted.feedURL = canonicalFeedURL
            cloudContext.insert(inserted)
            return inserted
        }()
        let hasPendingFollow = try pendingFollowFeedURLs(appContext).contains(canonicalFeedURL)
        if row.deletedAt != nil || value(podcast) != value(row)
            || hasPendingFollow {
            copy(podcast, to: row)
            row.deletedAt = nil
            row.modifiedAt = now
            row.sourceDeviceID = deviceID
        }
        if cloudContext.hasChanges { try cloudContext.save() }
        try clearPublishedFollowIntents(
            feedURLs: [canonicalFeedURL],
            activeProjectionFeedURLs: row.deletedAt == nil ? [canonicalFeedURL] : [],
            appContext: appContext
        )
        knownLocalFeedURLs.insert(canonicalFeedURL)
    }

    private func clearPublishedFollowIntents(
        feedURLs: Set<String>,
        activeProjectionFeedURLs: Set<String>,
        appContext: ModelContext
    ) throws {
        let clearable = feedURLs.intersection(activeProjectionFeedURLs)
            .intersection(try pendingFollowFeedURLs(appContext))
        guard !clearable.isEmpty else { return }
        do {
            for feedURL in clearable {
                let tokens = Set(try PendingCloudFollowIntent.tokens(
                    feedURL: feedURL, in: appContext
                ))
                guard !tokens.isEmpty else { continue }
                try publishActivatedFollowGraph(feedURL: feedURL, tokens: tokens)
                for token in tokens {
                    try PendingCloudFollowIntent.clear(
                        feedURL: feedURL, matching: token, in: appContext
                    )
                }
            }
            if appContext.hasChanges { try pendingIntentSave(appContext) }
        } catch {
            appContext.rollback()
            throw error
        }
    }

    private func publishActivatedFollowGraph(feedURL: String, tokens: Set<String>) throws {
        let feed = FeedURLIdentity.canonical(feedURL)
        try publishFollowDependentGraph(feedURL: feed)
        try validateFollowActivation(feedURL: feed, tokens: tokens)
        let active = try projectionContext.fetch(FetchDescriptor<CloudPodcastProjection>()).contains {
            FeedURLIdentity.canonical($0.feedURL) == feed && $0.deletedAt == nil
        }
        guard active else { throw CocoaError(.validationMissingMandatoryProperty) }
        try followActivationCheckpoint("verified")
        try validateFollowActivation(feedURL: feed, tokens: tokens)
    }

    private func publishFollowDependentGraph(feedURL: String) throws {
        let feed = FeedURLIdentity.canonical(feedURL)
        try publishLocalEpisodeStateChanges(activatingFeedURL: feed)
        try followActivationCheckpoint("episode")
        try publishLocalQueueChanges(activatingFeedURL: feed)
        try followActivationCheckpoint("queue")
        try publishLocalSettings(activatingFeedURL: feed)
        try followActivationCheckpoint("settings")
        try publishLocalBookmarkChanges(activatingFeedURL: feed)
        try followActivationCheckpoint("bookmarks")
        try publishLocalListeningHistoryChanges(activatingFeedURL: feed)
        try followActivationCheckpoint("history")
        try publishLocalFolderChanges(activatingFeedURL: feed)
        try followActivationCheckpoint("folders")
    }

    private func validateFollowActivation(feedURL: String, tokens: Set<String>) throws {
        refreshContextsFromStore()
        guard try PodcastIdentityService(context: modelContext)
            .existingFollowed(feedURL: feedURL) != nil else {
            try neutralizeCancelledFollowActivation(feedURL: feedURL)
            throw CancellationError()
        }
        guard !tokens.isDisjoint(with: try PendingCloudFollowIntent.tokens(
            feedURL: feedURL, in: modelContext
        ))
        else { throw CancellationError() }
    }

    /// Completes feed-scoped publication for catalog graphs promoted by an
    /// active remote subscription. Snapshot generations are cleared exactly;
    /// a newer activation written by another context remains restart-visible.
    private func publishPendingRemoteActivations() throws {
        let grouped = Dictionary(grouping: try PendingCloudRemoteActivationIntent.intents(
            in: modelContext
        )) { $0.feed }
        for feed in grouped.keys.sorted() {
            let tokens = Set(grouped[feed, default: []].map(\.token))
            guard !tokens.isEmpty,
                  try validateRemoteActivation(feedURL: feed, tokens: tokens) else { continue }
            try publishFollowDependentGraph(feedURL: feed)
            guard try validateRemoteActivation(feedURL: feed, tokens: tokens) else { continue }
            try followActivationCheckpoint("verified")
            guard try validateRemoteActivation(feedURL: feed, tokens: tokens) else { continue }
            do {
                for token in tokens {
                    try PendingCloudRemoteActivationIntent.clear(
                        feedURL: feed, matching: token, in: modelContext
                    )
                }
                if modelContext.hasChanges { try pendingIntentSave(modelContext) }
            } catch {
                modelContext.rollback()
                throw error
            }
        }
    }

    private func validateRemoteActivation(feedURL: String, tokens: Set<String>) throws -> Bool {
        refreshContextsFromStore()
        let feed = FeedURLIdentity.canonical(feedURL)
        let followed = try PodcastIdentityService(context: modelContext)
            .existingFollowed(feedURL: feed) != nil
        let pendingUnfollow = try PendingCloudUnfollowIntent.feedURLs(in: modelContext)
            .contains(feed)
        let active = try projectionContext.fetch(FetchDescriptor<CloudPodcastProjection>())
            .contains {
                FeedURLIdentity.canonical($0.feedURL) == feed && $0.deletedAt == nil
            }
        if !followed || pendingUnfollow {
            try neutralizeCancelledFollowActivation(feedURL: feed)
            return false
        }
        // The projection import may not yet contain the remote subscription row
        // that created this durable application marker. Retain the marker and
        // wait rather than manufacturing dependent rows without its authority.
        guard active else { return false }
        let currentTokens = Set(try PendingCloudRemoteActivationIntent.tokens(
            feedURL: feed, in: modelContext
        ))
        return !tokens.isDisjoint(with: currentTokens)
    }

    private func publishPendingUnfollowIntents(feedURLs requested: Set<String>? = nil) throws {
        let pending = try PendingCloudUnfollowIntent.intents(in: modelContext)
        for (token, feed) in pending where requested?.contains(feed) != false {
            refreshContextsFromStore()
            if try PodcastIdentityService(context: modelContext)
                .existingFollowed(feedURL: feed) == nil {
                try neutralizeCancelledFollowActivation(feedURL: feed)
            }
            do {
                try PendingCloudUnfollowIntent.clear(
                    feedURL: feed, matching: token, in: modelContext
                )
                if modelContext.hasChanges { try pendingIntentSave(modelContext) }
            } catch {
                modelContext.rollback()
                throw error
            }
        }
    }

    private func neutralizeCancelledFollowActivation(feedURL: String) throws {
        let now = Date.now
        let rows = try projectionContext.fetch(FetchDescriptor<CloudPodcastProjection>())
        for row in rows where FeedURLIdentity.canonical(row.feedURL) == feedURL
            && row.deletedAt == nil {
            row.deletedAt = now
            row.modifiedAt = now
            row.sourceDeviceID = deviceID
        }
        if projectionContext.hasChanges { try projectionContext.save() }
        try publishLocalEpisodeStateChanges(now: now, activatingFeedURL: feedURL)
        try publishLocalQueueChanges(now: now, activatingFeedURL: feedURL)
        try publishLocalSettings(now: now, activatingFeedURL: feedURL)
        try publishLocalBookmarkChanges(now: now, activatingFeedURL: feedURL)
        try publishLocalListeningHistoryChanges(now: now, activatingFeedURL: feedURL)
        try publishLocalFolderChanges(now: now, activatingFeedURL: feedURL)
    }

    /// Records the destructive intent before the application-store transaction.
    /// The projection store remains in place, so a force quit after this save
    /// restarts from tombstones rather than re-importing the deleted library.
    func markAllSubscriptionsDeleted(now: Date = .now) throws {
        refreshContextsFromStore()
        let context = projectionContext
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
        let bookmarkRows = try context.fetch(FetchDescriptor<CloudBookmarkProjection>())
        for row in bookmarkRows where row.deletedAt == nil {
            row.deletedAt = now
            row.modifiedAt = now
        }
        let sessionRows = try context.fetch(FetchDescriptor<CloudListeningSessionProjection>())
        for row in sessionRows where row.deletedAt == nil {
            row.deletedAt = now
            row.modifiedAt = now
        }
        let folderRows = try context.fetch(FetchDescriptor<CloudFolderProjection>())
        for row in folderRows where row.deletedAt == nil {
            row.deletedAt = now
            row.modifiedAt = now
        }
        if context.hasChanges { try context.save() }
        knownLocalFeedURLs.removeAll()
        knownLocalBookmarkIDs.removeAll()
        knownLocalSessionIDs.removeAll()
        knownLocalFolderIDs.removeAll()
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

    private static func queueMembershipOrder(
        _ lhs: CloudQueueItemProjection,
        _ rhs: CloudQueueItemProjection
    ) -> Bool {
        let lhsMembershipDate = lhs.membershipUpdatedAt == .distantPast
            ? lhs.modifiedAt : lhs.membershipUpdatedAt
        let rhsMembershipDate = rhs.membershipUpdatedAt == .distantPast
            ? rhs.modifiedAt : rhs.membershipUpdatedAt
        if lhsMembershipDate != rhsMembershipDate {
            return lhsMembershipDate > rhsMembershipDate
        }
        return queueProjectionOrder(lhs, rhs)
    }

    private static func copyEpisodeMetadata(
        _ episode: Episode,
        to row: CloudQueueItemProjection
    ) {
        row.episodeTitle = episode.title
        row.episodeAudioURL = episode.audioURL
        row.episodeDescription = episode.episodeDescription
        row.episodeDurationSeconds = episode.durationSeconds
        row.episodePubDate = episode.pubDate
        row.episodeArtworkURL = episode.artworkURL
        row.episodeNumber = episode.episodeNumber
        row.episodeSeasonNumber = episode.seasonNumber
        row.episodeChapterURL = episode.chapterURL
        row.episodeTranscriptURL = episode.transcriptURL
    }

    private static func settingProjectionOrder(
        _ lhs: CloudSettingProjection,
        _ rhs: CloudSettingProjection
    ) -> Bool {
        if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt > rhs.modifiedAt }
        if lhs.sourceDeviceID != rhs.sourceDeviceID {
            return lhs.sourceDeviceID < rhs.sourceDeviceID
        }
        return lhs.value < rhs.value
    }

    private static func bookmarkProjectionOrder(
        _ lhs: CloudBookmarkProjection,
        _ rhs: CloudBookmarkProjection
    ) -> Bool {
        if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt > rhs.modifiedAt }
        return lhs.bookmarkID < rhs.bookmarkID
    }

    private static func bookmarkSemanticKey(_ row: CloudBookmarkProjection) -> String {
        bookmarkSemanticKey(
            feedURL: row.feedURL,
            guid: row.episodeGUID,
            position: row.positionSeconds,
            createdAt: row.createdAt
        )
    }

    private static func bookmarkSemanticKey(
        feedURL: String,
        guid: String,
        position: Int,
        createdAt: Date
    ) -> String {
        "\(FeedURLIdentity.canonical(feedURL))\u{1f}\(guid)\u{1f}\(max(0, position))\u{1f}\(createdAt.timeIntervalSinceReferenceDate.bitPattern)"
    }

    private static func sessionProjectionOrder(
        _ lhs: CloudListeningSessionProjection,
        _ rhs: CloudListeningSessionProjection
    ) -> Bool {
        if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt > rhs.modifiedAt }
        return lhs.sessionID < rhs.sessionID
    }

    private static func sessionSemanticKey(_ row: CloudListeningSessionProjection) -> String {
        sessionSemanticKey(
            feedURL: row.feedURL,
            guid: row.episodeGUID,
            duration: row.durationSeconds,
            speed: row.speed,
            date: row.date
        )
    }

    private static func sessionSemanticKey(
        feedURL: String,
        guid: String?,
        duration: Int,
        speed: Double,
        date: Date
    ) -> String {
        "\(FeedURLIdentity.canonical(feedURL))\u{1f}\(guid ?? "")\u{1f}\(max(0, duration))\u{1f}\(speed.bitPattern)\u{1f}\(date.timeIntervalSinceReferenceDate.bitPattern)"
    }

    private static func folderProjectionOrder(
        _ lhs: CloudFolderProjection,
        _ rhs: CloudFolderProjection
    ) -> Bool {
        if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt > rhs.modifiedAt }
        return lhs.folderID < rhs.folderID
    }

    private static func folderOrder(_ lhs: PodcastFolder, _ rhs: PodcastFolder) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
        return lhs.name < rhs.name
    }

    private static func jsonString<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard let result = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        return result
    }

    private static func decodeJSON<T: Decodable>(_ type: T.Type, from value: String) -> T? {
        guard let data = value.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func followedFeedURLs(in context: ModelContext) throws -> Set<String> {
        Set(try PodcastIdentityService(context: context).allScalarPodcasts()
            .filter(\.isFollowed)
            .map { FeedURLIdentity.canonical($0.feedURL) })
    }

    private static func projectedSettingValue(
        key: String,
        value: String,
        followedFeeds: Set<String>
    ) -> String? {
        guard AppSettingIdentity.canonicalKey(key) == SettingsKey.morningLineup else {
            return value
        }
        return QueueLineupIdentityPolicy.outboundValue(
            value,
            followedFeeds: followedFeeds
        )
    }

    private static func settingBelongsToFollowedPodcast(
        _ rawKey: String,
        followedFeeds: Set<String>
    ) -> Bool {
        let key = AppSettingIdentity.canonicalKey(rawKey)
        for prefix in [
            SettingsKey.podcastFilterPrefix,
            SettingsKey.podcastInboxCapPrefix,
            SettingsKey.episodeFilterConfigurationPrefix,
            SettingsKey.podcastDisplayNamePrefix,
        ] where key.hasPrefix(prefix) {
            return followedFeeds.contains(
                FeedURLIdentity.canonical(String(key.dropFirst(prefix.count)))
            )
        }
        return true
    }

    private static func setting(_ rawKey: String, isActivatedBy feedURL: String?) -> Bool {
        guard let feedURL else { return true }
        let key = AppSettingIdentity.canonicalKey(rawKey)
        if key == SettingsKey.morningLineup { return true }
        let feed = FeedURLIdentity.canonical(feedURL)
        for prefix in [
            SettingsKey.podcastFilterPrefix,
            SettingsKey.podcastInboxCapPrefix,
            SettingsKey.episodeFilterConfigurationPrefix,
            SettingsKey.podcastDisplayNamePrefix,
        ] where key.hasPrefix(prefix) {
            return FeedURLIdentity.canonical(String(key.dropFirst(prefix.count))) == feed
        }
        return false
    }

    private func applicationEpisodes(matching keys: Set<EpisodeKey>) -> [EpisodeKey: Episode] {
        guard !keys.isEmpty else { return [:] }
        let keysByFeed = Dictionary(grouping: keys, by: \.feedURL)
        let context = modelContext
        let podcasts = (
            try? PodcastIdentityService(context: context).allScalarPodcasts()
        )?.filter(\.isFollowed) ?? []
        var result: [EpisodeKey: Episode] = [:]
        for podcast in podcasts {
            let feed = FeedURLIdentity.canonical(podcast.feedURL)
            guard let requested = keysByFeed[feed] else { continue }
            let requestedGUIDs = requested.map(\.guid)
            let podcastID = podcast.persistentModelID
            let matched = (try? context.fetch(FetchDescriptor<Episode>(
                predicate: #Predicate {
                    $0.podcast?.persistentModelID == podcastID
                        && requestedGUIDs.contains($0.guid)
                }
            ))) ?? []
            // Never fault podcast.episodes here. The real phone has a 45,436-row
            // inverse relationship; loading and sorting that graph to resolve one
            // queue projection caused the build-180 launch hang.
            for episode in matched.sorted(by: Self.episodeOrder) {
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

            let dismissalWinner = contributions
                .filter { $0.inboxDismissedUpdatedAt != .distantPast }
                .max {
                    if $0.inboxDismissedUpdatedAt != $1.inboxDismissedUpdatedAt {
                        return $0.inboxDismissedUpdatedAt < $1.inboxDismissedUpdatedAt
                    }
                    return $0.sourceDeviceID > $1.sourceDeviceID
                }

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
            if let dismissalWinner,
               episode.inboxDismissed != dismissalWinner.inboxDismissed {
                episode.inboxDismissed = dismissalWinner.inboxDismissed
                changed = true
            }
        }
        if appContext.hasChanges { try appContext.save() }
        return changed
    }

    private func applyRemoteQueue(
        appContext: ModelContext,
        cloudContext: ModelContext
    ) async throws -> Bool {
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
        var positionWinners: [EpisodeKey: CloudQueueItemProjection] = [:]
        for (key, contributions) in grouped {
            // Membership has its own clock. A later position-only edit from a
            // stale device must not override a newer explicit removal.
            winners[key] = contributions.sorted(by: Self.queueMembershipOrder).first
            // Once membership says the episode is queued, ordering remains a
            // normal last-writer-wins value. Keeping this separate prevents the
            // independent membership clock from freezing an older position.
            positionWinners[key] = contributions
                .filter(\.isQueued)
                .sorted(by: Self.queueProjectionOrder)
                .first
        }

        let plan = RemoteQueuePlan(
            entries: winners.keys.sorted().compactMap { key in
                guard let membership = winners[key] else { return nil }
                let position = positionWinners[key] ?? membership
                let metadataRow = grouped[key]?
                    .sorted(by: Self.queueProjectionOrder)
                    .first {
                        $0.episodeTitle?.isEmpty == false
                            && $0.episodeAudioURL?.isEmpty == false
                    }
                let metadata: RemoteQueuePlan.EpisodeMetadata?
                if let metadataRow,
                   let title = metadataRow.episodeTitle,
                   let audioURL = metadataRow.episodeAudioURL {
                    metadata = RemoteQueuePlan.EpisodeMetadata(
                        title: title,
                        audioURL: audioURL,
                        episodeDescription: metadataRow.episodeDescription,
                        durationSeconds: metadataRow.episodeDurationSeconds,
                        pubDate: metadataRow.episodePubDate,
                        artworkURL: metadataRow.episodeArtworkURL,
                        episodeNumber: metadataRow.episodeNumber,
                        seasonNumber: metadataRow.episodeSeasonNumber,
                        chapterURL: metadataRow.episodeChapterURL,
                        transcriptURL: metadataRow.episodeTranscriptURL
                    )
                } else {
                    metadata = nil
                }
                return RemoteQueuePlan.Entry(
                    key: key,
                    isQueued: membership.isQueued,
                    membershipUpdatedAt: membership.membershipUpdatedAt == .distantPast
                        ? membership.modifiedAt : membership.membershipUpdatedAt,
                    membershipModifiedAt: membership.modifiedAt,
                    membershipSourceDeviceID: membership.sourceDeviceID,
                    position: position.position,
                    positionModifiedAt: position.modifiedAt,
                    positionSourceDeviceID: position.sourceDeviceID,
                    metadata: metadata
                )
            },
            currentDeviceID: deviceID
        )

        // The testing checkpoint intentionally faults the coordinator's old
        // inverse before playback deletes it in another context. Production does
        // not resolve this graph; only the Sendable plan crosses to MainActor.
        if let queueApplicationCheckpoint {
            let episodes = applicationEpisodes(matching: Set(winners.keys))
            let inverseCount = episodes.values.reduce(into: 0) { count, episode in
                if episode.queueItem != nil { count += 1 }
            }
            try await queueApplicationCheckpoint("episodes-resolved:\(inverseCount)")
        }

        let changed = try await Self.applyRemoteQueuePlan(
            plan,
            applicationContainer: modelContainer,
            checkpoint: queueApplicationCheckpoint
        )
        if cloudContext.hasChanges { try cloudContext.save() }
        return changed
    }

    /// MainActor serializes this transaction with playback queue writes and keeps
    /// the UI's registered graph coherent. Commit any pre-existing UI work before
    /// establishing the rollback boundary; a queue-pass failure can then roll
    /// back only mutations made by this transaction.
    @MainActor
    private static func applyRemoteQueuePlan(
        _ plan: RemoteQueuePlan,
        applicationContainer: ModelContainer,
        checkpoint: (@Sendable (String) async throws -> Void)?
    ) async throws -> Bool {
        let context = applicationContainer.mainContext
        if context.hasChanges {
            // Queue repositories already use immediate saves. Preserve unrelated
            // dirty UI edits by committing them; never roll them back as though
            // they belonged to remote queue application.
            try context.save()
        }
        if let checkpoint {
            let plannedKeys = Set(plan.entries.map(\.key))
            // Complete model iteration before awaiting and retain only a scalar.
            let existingCount = try context.fetch(FetchDescriptor<QueueItem>())
                .reduce(into: 0) { count, item in
                    guard let episode = item.episode,
                          let key = episodeKey(for: episode),
                          plannedKeys.contains(key) else { return }
                    count += 1
                }
            try await checkpoint("existing-fetched:\(existingCount)")
        }

        // The test hook can suspend. Save any work that arrived during it before
        // establishing the no-await transaction's rollback boundary.
        if context.hasChanges { try context.save() }
        do {
            let changed = try applyRemoteQueuePlanSynchronously(plan, in: context)
            if context.hasChanges { try context.save() }
            return changed
        } catch {
            context.rollback()
            throw error
        }
    }

    /// Re-fetch, decide, mutate, and save without an actor suspension. This is
    /// deliberately a small application-store critical section; projection
    /// scanning and winner calculation stay on the Cloud actor.
    @MainActor
    private static func applyRemoteQueuePlanSynchronously(
        _ plan: RemoteQueuePlan,
        in context: ModelContext
    ) throws -> Bool {
        let entriesByKey = Dictionary(uniqueKeysWithValues: plan.entries.map { ($0.key, $0) })
        let pendingMemberships = try PendingCloudQueueMutation.memberships(in: context)
        let pendingOrderings = try PendingCloudQueueMutation.orderings(in: context)
        var pendingMembershipByKey: [EpisodeKey: PendingCloudQueueMutation.Membership] = [:]
        for pending in pendingMemberships {
            let key = EpisodeKey(feedURL: pending.feedURL, guid: pending.guid)
            if let existing = pendingMembershipByKey[key],
               existing.eventDate > pending.eventDate
                || (existing.eventDate == pending.eventDate && existing.token < pending.token) {
                continue
            }
            pendingMembershipByKey[key] = pending
        }
        let latestOrdering = pendingOrderings.max {
            if $0.eventDate != $1.eventDate { return $0.eventDate < $1.eventDate }
            return $0.token > $1.token
        }?.eventDate

        let identity = PodcastIdentityService(context: context)
        let requestedFeeds = Set(plan.entries.map { $0.key.feedURL })
        // Resolve the entire remote queue against one scalar Podcast fetch. A
        // legacy, non-canonical stored URL makes `existingFollowed(feedURL:)`
        // fall back to `allScalarPodcasts()`; doing that once per remote feed was
        // O(feeds × library) on MainActor and produced measured ~428 ms VoiceOver
        // microhangs while Settings was onscreen.
        let resolvedPodcasts = try identity.existingAnyStateByCanonicalFeedURL(
            for: Array(requestedFeeds)
        )
        var podcastByFeed: [String: Podcast] = [:]
        for feed in requestedFeeds.sorted() {
            if let podcast = resolvedPodcasts[FeedURLIdentity.canonical(feed)],
               podcast.isFollowed {
                podcastByFeed[feed] = podcast
            }
        }
        let requestedByFeed = Dictionary(grouping: plan.entries.map(\.key), by: \.feedURL)
        var episodesByKey: [EpisodeKey: Episode] = [:]
        for (feed, keys) in requestedByFeed {
            guard let podcast = podcastByFeed[feed] else { continue }
            let guids = keys.map(\.guid)
            let podcastID = podcast.persistentModelID
            let episodes = try context.fetch(FetchDescriptor<Episode>(predicate: #Predicate {
                $0.podcast?.persistentModelID == podcastID && guids.contains($0.guid)
            }))
            for episode in episodes.sorted(by: episodeOrder) {
                let key = EpisodeKey(feedURL: feed, guid: episode.guid)
                if episodesByKey[key] == nil { episodesByKey[key] = episode }
            }
        }

        let existing = try context.fetch(FetchDescriptor<QueueItem>(
            sortBy: [SortDescriptor(\.position)]
        ))
        var existingByKey: [EpisodeKey: QueueItem] = [:]
        var keyByItemID: [PersistentIdentifier: EpisodeKey] = [:]
        var changed = false
        for item in existing {
            guard let episode = item.episode,
                  episode.podcast?.isFollowed == true,
                  let key = episodeKey(for: episode) else { continue }
            keyByItemID[item.persistentModelID] = key
            if existingByKey[key] == nil {
                existingByKey[key] = item
            } else {
                // Repair an aged duplicate without ever assigning a contested
                // one-to-one inverse.
                context.delete(item)
                changed = true
            }
        }

        func pendingMembershipWins(
            _ pending: PendingCloudQueueMutation.Membership,
            over remote: RemoteQueuePlan.Entry
        ) -> Bool {
            if pending.eventDate != remote.membershipUpdatedAt {
                return pending.eventDate > remote.membershipUpdatedAt
            }
            // Publishing an equal-clock edit updates this device's own row.
            if remote.membershipSourceDeviceID == plan.currentDeviceID { return true }
            let virtualModifiedAt = max(
                pending.eventDate,
                latestOrdering ?? pending.eventDate
            )
            if virtualModifiedAt != remote.membershipModifiedAt {
                return virtualModifiedAt > remote.membershipModifiedAt
            }
            return plan.currentDeviceID < remote.membershipSourceDeviceID
        }

        func localPositionWins(
            for key: EpisodeKey,
            remote: RemoteQueuePlan.Entry
        ) -> Bool {
            let membershipDate = pendingMembershipByKey[key].flatMap {
                $0.isQueued ? $0.eventDate : nil
            }
            guard let localDate = [latestOrdering, membershipDate]
                .compactMap({ $0 }).max() else { return false }
            if localDate != remote.positionModifiedAt {
                return localDate > remote.positionModifiedAt
            }
            if remote.positionSourceDeviceID == plan.currentDeviceID { return true }
            return plan.currentDeviceID < remote.positionSourceDeviceID
        }

        var effectiveQueuedByKey: [EpisodeKey: Bool] = [:]
        var targetPositionByKey: [EpisodeKey: Int] = [:]
        for entry in plan.entries {
            let pending = pendingMembershipByKey[entry.key]
            let queued = pending.map { pendingMembershipWins($0, over: entry) }
                == true ? pending!.isQueued : entry.isQueued
            effectiveQueuedByKey[entry.key] = queued
            if localPositionWins(for: entry.key, remote: entry),
               let current = existingByKey[entry.key] {
                targetPositionByKey[entry.key] = current.position
            } else {
                targetPositionByKey[entry.key] = entry.position
            }
        }

        for entry in plan.entries where effectiveQueuedByKey[entry.key] == true
            && episodesByKey[entry.key] == nil {
            guard let podcast = podcastByFeed[entry.key.feedURL],
                  let metadata = entry.metadata else { continue }
            let episode = Episode(
                guid: entry.key.guid,
                title: metadata.title,
                audioURL: metadata.audioURL,
                episodeDescription: metadata.episodeDescription,
                durationSeconds: metadata.durationSeconds,
                pubDate: metadata.pubDate,
                artworkURL: metadata.artworkURL,
                episodeNumber: metadata.episodeNumber,
                seasonNumber: metadata.seasonNumber,
                chapterURL: metadata.chapterURL,
                transcriptURL: metadata.transcriptURL,
                status: .inQueue,
                inboxDismissed: true
            )
            episode.podcast = podcast
            context.insert(episode)
            episodesByKey[entry.key] = episode
            changed = true
        }

        for entry in plan.entries {
            guard let episode = episodesByKey[entry.key] else { continue }
            if effectiveQueuedByKey[entry.key] == true {
                if existingByKey[entry.key] == nil {
                    // A non-nil inverse that was absent from the QueueItem fetch
                    // is an inconsistent cross-context snapshot. Defer this key
                    // instead of invoking SwiftData's trapping relationship setter.
                    guard episode.queueItem == nil else { continue }
                    let item = QueueItem(
                        episode: episode,
                        position: targetPositionByKey[entry.key] ?? entry.position
                    )
                    context.insert(item)
                    existingByKey[entry.key] = item
                    keyByItemID[item.persistentModelID] = entry.key
                    changed = true
                }
                if episode.status != .inQueue {
                    episode.status = .inQueue
                    changed = true
                }
            } else if let item = existingByKey.removeValue(forKey: entry.key) {
                context.delete(item)
                if episode.status == .inQueue { episode.status = .newEpisode }
                changed = true
            }
        }

        let projected = existingByKey.compactMap { key, item -> (QueueItem, Int, EpisodeKey)? in
            guard entriesByKey[key] != nil,
                  effectiveQueuedByKey[key] == true else { return nil }
            return (item, targetPositionByKey[key] ?? item.position, key)
        }.sorted {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            return $0.2 < $1.2
        }
        var projectedIndex = 0
        var ordered: [QueueItem] = []
        for item in existing where !item.isDeleted {
            guard let key = keyByItemID[item.persistentModelID], entriesByKey[key] != nil else {
                ordered.append(item)
                continue
            }
            if projected.indices.contains(projectedIndex) {
                ordered.append(projected[projectedIndex].0)
                projectedIndex += 1
            }
        }
        ordered.append(contentsOf: projected.dropFirst(projectedIndex).map(\.0))
        for (position, item) in ordered.enumerated() where item.position != position {
            item.position = position
            changed = true
        }
        return changed
    }

    private func applyRemoteSettings(
        appContext: ModelContext,
        cloudContext: ModelContext
    ) throws -> Bool {
        let followedFeeds = try followedFeedURLs(in: appContext)
        let rows = try cloudContext.fetch(FetchDescriptor<CloudSettingProjection>())
            .filter {
                $0.deletedAt == nil && AppSettingScope.isMirrored($0.key)
                    && Self.settingBelongsToFollowedPodcast(
                        $0.key,
                        followedFeeds: followedFeeds
                    )
            }
        var newestByDevice: [String: CloudSettingProjection] = [:]
        for row in rows.sorted(by: Self.settingProjectionOrder) {
            let key = AppSettingIdentity.canonicalKey(row.key)
            let deviceKey = "\(key)\u{1f}\(row.sourceDeviceID)"
            if newestByDevice[deviceKey] == nil {
                newestByDevice[deviceKey] = row
            } else {
                cloudContext.delete(row)
            }
        }
        let newestByKey = Dictionary(
            grouping: newestByDevice.values,
            by: { AppSettingIdentity.canonicalKey($0.key) }
        )
        var changed = false
        for key in newestByKey.keys.sorted() {
            guard let contributions = newestByKey[key],
                  let remoteValue = Self.mergedSettingValue(key: key, rows: contributions)
            else { continue }
            let localValue = AppSettingIdentity.value(for: key, in: appContext)
            let value: String
            if key == SettingsKey.morningLineup {
                value = QueueLineupIdentityPolicy.mergingRemoteValue(
                    remoteValue,
                    into: localValue ?? "[]",
                    followedFeeds: followedFeeds
                )
            } else {
                value = remoteValue
            }
            guard localValue != value else { continue }
            try AppSettingIdentity.setValue(value, for: key, in: appContext)
            changed = true
        }
        if appContext.hasChanges { try appContext.save() }
        if cloudContext.hasChanges { try cloudContext.save() }
        return changed
    }

    private static func mergedSettingValue(
        key: String,
        rows: [CloudSettingProjection]
    ) -> String? {
        if key == SettingsKey.grandfatheredPodcastCount {
            return rows.compactMap { Int($0.value) }.max().map(String.init)
        }
        if key == SettingsKey.podcastCapGatingIntroduced {
            return rows.contains { ($0.value as NSString).boolValue } ? "true" : "false"
        }
        return rows.sorted(by: settingProjectionOrder).first?.value
    }

    private func applyRemoteBookmarks(
        appContext: ModelContext,
        cloudContext: ModelContext
    ) throws -> Bool {
        let rows = try cloudContext.fetch(FetchDescriptor<CloudBookmarkProjection>())
        var newestByID: [String: CloudBookmarkProjection] = [:]
        for row in rows.sorted(by: Self.bookmarkProjectionOrder) {
            if newestByID[row.bookmarkID] == nil {
                newestByID[row.bookmarkID] = row
            } else {
                cloudContext.delete(row)
            }
        }
        let existing = try appContext.fetch(FetchDescriptor<Bookmark>())
        var localBySemanticKey: [String: Bookmark] = [:]
        for bookmark in existing {
            guard let episode = bookmark.episode,
                  episode.podcast?.isFollowed == true,
                  let feedURL = episode.podcast?.feedURL else { continue }
            let key = Self.bookmarkSemanticKey(
                feedURL: feedURL,
                guid: episode.guid,
                position: bookmark.positionSeconds,
                createdAt: bookmark.createdAt
            )
            if localBySemanticKey[key] == nil { localBySemanticKey[key] = bookmark }
        }
        var changed = false
        var locallyPresentIDs: Set<String> = []
        for row in newestByID.values.sorted(by: Self.bookmarkProjectionOrder) {
            let key = Self.bookmarkSemanticKey(row)
            if row.deletedAt != nil {
                if let bookmark = localBySemanticKey.removeValue(forKey: key) {
                    appContext.delete(bookmark)
                    changed = true
                }
                continue
            }
            guard let episode = applicationEpisodes(matching: [
                EpisodeKey(
                    feedURL: FeedURLIdentity.canonical(row.feedURL),
                    guid: row.episodeGUID
                )
            ]).values.first else { continue }
            if let bookmark = localBySemanticKey[key] {
                locallyPresentIDs.insert(row.bookmarkID)
                if bookmark.note != row.note {
                    bookmark.note = row.note
                    changed = true
                }
            } else {
                appContext.insert(Bookmark(
                    episode: episode,
                    positionSeconds: row.positionSeconds,
                    note: row.note,
                    createdAt: row.createdAt
                ))
                locallyPresentIDs.insert(row.bookmarkID)
                changed = true
            }
        }
        if appContext.hasChanges { try appContext.save() }
        if cloudContext.hasChanges { try cloudContext.save() }
        knownLocalBookmarkIDs = locallyPresentIDs
        return changed
    }

    private func applyRemoteListeningHistory(
        appContext: ModelContext,
        cloudContext: ModelContext
    ) throws -> Bool {
        let rows = try cloudContext.fetch(FetchDescriptor<CloudListeningSessionProjection>())
        var newestByID: [String: CloudListeningSessionProjection] = [:]
        for row in rows.sorted(by: Self.sessionProjectionOrder) {
            if newestByID[row.sessionID] == nil {
                newestByID[row.sessionID] = row
            } else {
                cloudContext.delete(row)
            }
        }
        let local = try resolvedLocalListeningSessions(in: appContext)
        var localByKey: [String: ListeningSession] = [:]
        let followedFeeds = try followedFeedURLs(in: appContext)
        for session in local.sessions where
            followedFeeds.contains(FeedURLIdentity.canonical(session.feedURL)) {
            let key = Self.sessionSemanticKey(
                feedURL: session.feedURL,
                guid: session.episodeGUID,
                duration: session.durationSeconds,
                speed: session.speed,
                date: session.date
            )
            if localByKey[key] == nil { localByKey[key] = session.session }
        }
        let activeRows = newestByID.values.filter { $0.deletedAt == nil }
        let podcastByFeed = try PodcastIdentityService(context: appContext)
            .existingAnyStateByCanonicalFeedURL(for: activeRows.map(\.feedURL))
        let requestedEpisodeKeys = Set(activeRows.compactMap { row -> EpisodeKey? in
            guard let guid = row.episodeGUID else { return nil }
            return EpisodeKey(
                feedURL: FeedURLIdentity.canonical(row.feedURL),
                guid: guid
            )
        })
        let episodeByKey = applicationEpisodes(matching: requestedEpisodeKeys)
        var changed = local.repaired
        var locallyPresentIDs: Set<String> = []
        for row in newestByID.values.sorted(by: Self.sessionProjectionOrder) {
            let key = Self.sessionSemanticKey(row)
            if row.deletedAt != nil {
                if let session = localByKey.removeValue(forKey: key) {
                    appContext.delete(session)
                    changed = true
                }
                continue
            }
            if localByKey[key] != nil {
                locallyPresentIDs.insert(row.sessionID)
                continue
            }
            let feedURL = FeedURLIdentity.canonical(row.feedURL)
            guard let podcast = podcastByFeed[feedURL], podcast.isFollowed else { continue }
            let episode: Episode? = if let guid = row.episodeGUID {
                episodeByKey[EpisodeKey(feedURL: feedURL, guid: guid)]
            } else {
                nil
            }
            appContext.insert(ListeningSession(
                episode: episode,
                podcast: podcast,
                durationSeconds: row.durationSeconds,
                speed: row.speed,
                date: row.date
            ))
            locallyPresentIDs.insert(row.sessionID)
            changed = true
        }
        if appContext.hasChanges { try appContext.save() }
        if cloudContext.hasChanges { try cloudContext.save() }
        knownLocalSessionIDs = locallyPresentIDs
        return changed
    }

    private func applyRemoteFolders(
        appContext: ModelContext,
        cloudContext: ModelContext
    ) throws -> Bool {
        let rows = try cloudContext.fetch(FetchDescriptor<CloudFolderProjection>())
        var newestByID: [String: CloudFolderProjection] = [:]
        for row in rows.sorted(by: Self.folderProjectionOrder) {
            if newestByID[row.folderID] == nil {
                newestByID[row.folderID] = row
            } else {
                cloudContext.delete(row)
            }
        }
        let existingFolders = try appContext.fetch(FetchDescriptor<PodcastFolder>())
        let allPodcastMemberships = try appContext.fetch(FetchDescriptor<FolderMembership>())
        let podcastMembershipsByFolderID = Dictionary(grouping: allPodcastMemberships) {
            $0.folder?.persistentModelID
        }
        var folderByCreatedAt: [UInt64: PodcastFolder] = [:]
        for folder in existingFolders.sorted(by: Self.folderOrder) {
            let key = folder.createdAt.timeIntervalSinceReferenceDate.bitPattern
            if folderByCreatedAt[key] == nil { folderByCreatedAt[key] = folder }
        }
        var folderByCloudID: [String: PodcastFolder] = [:]
        var changed = false
        for row in newestByID.values.sorted(by: Self.folderProjectionOrder) {
            let key = row.createdAt.timeIntervalSinceReferenceDate.bitPattern
            if row.deletedAt != nil {
                if let folder = folderByCreatedAt.removeValue(forKey: key) {
                    appContext.delete(folder)
                    changed = true
                }
                continue
            }
            let folder = folderByCreatedAt[key] ?? {
                let inserted = PodcastFolder(
                    name: row.name,
                    sortOrder: row.sortOrder,
                    queueAgeLimitDays: row.queueAgeLimitDays,
                    createdAt: row.createdAt
                )
                appContext.insert(inserted)
                folderByCreatedAt[key] = inserted
                changed = true
                return inserted
            }()
            folderByCloudID[row.folderID] = folder
            if folder.name != row.name { folder.name = row.name; changed = true }
            if folder.sortOrder != row.sortOrder { folder.sortOrder = row.sortOrder; changed = true }
            if folder.queueAgeLimitDays != row.queueAgeLimitDays {
                folder.queueAgeLimitDays = row.queueAgeLimitDays
                changed = true
            }
        }
        let requestedParents = Dictionary(uniqueKeysWithValues: newestByID.values
            .filter { $0.deletedAt == nil }
            .map { ($0.folderID, $0.parentFolderID) })
        let parentRepair = FolderSyncConflictPolicy.repairCycles(in: requestedParents)
        for row in newestByID.values.sorted(by: Self.folderProjectionOrder)
        where row.deletedAt == nil {
            guard let folder = folderByCloudID[row.folderID] else { continue }
            let parentID = parentRepair.parents[row.folderID] ?? nil
            let parent = parentID.flatMap { folderByCloudID[$0] }
            if folder.parent?.persistentModelID != parent?.persistentModelID,
               !FolderLogic.wouldCreateCycle(moving: folder, under: parent) {
                folder.parent = parent
                changed = true
            }
            let podcastMembers = Self.decodeJSON(
                [CloudFolderPodcastMember].self,
                from: row.podcastMembersJSON
            ) ?? []
            var existingPodcastMembers: [String: FolderMembership] = [:]
            for member in podcastMembershipsByFolderID[folder.persistentModelID, default: []] {
                guard let podcast = member.podcast, podcast.isFollowed else { continue }
                let feedURL = podcast.feedURL
                let feed = FeedURLIdentity.canonical(feedURL)
                if existingPodcastMembers[feed] == nil {
                    existingPodcastMembers[feed] = member
                } else {
                    appContext.delete(member)
                    changed = true
                }
            }
            let desiredFeeds = Set(podcastMembers.map(\.feedURL))
            let removedFeeds = existingPodcastMembers.keys.filter { !desiredFeeds.contains($0) }
            for feed in removedFeeds {
                guard let member = existingPodcastMembers.removeValue(forKey: feed) else { continue }
                appContext.delete(member)
                changed = true
            }
            for member in podcastMembers {
                guard let podcast = try PodcastIdentityService(context: appContext)
                    .existingFollowed(feedURL: member.feedURL) else { continue }
                if let existing = existingPodcastMembers[member.feedURL] {
                    if existing.sortOrder != member.sortOrder {
                        existing.sortOrder = member.sortOrder
                        changed = true
                    }
                } else {
                    appContext.insert(FolderMembership(
                        folder: folder,
                        podcast: podcast,
                        sortOrder: member.sortOrder
                    ))
                    changed = true
                }
            }
            let episodeMembers = Self.decodeJSON(
                [CloudFolderEpisodeMember].self,
                from: row.episodeMembersJSON
            ) ?? []
            let allEpisodeMembers = try appContext.fetch(FetchDescriptor<EpisodeFolderMembership>())
                .filter { $0.folder?.persistentModelID == folder.persistentModelID }
            var existingEpisodeMembers: [EpisodeKey: EpisodeFolderMembership] = [:]
            for member in allEpisodeMembers {
                guard let episode = member.episode,
                      episode.podcast?.isFollowed == true,
                      let key = Self.episodeKey(for: episode),
                      existingEpisodeMembers[key] == nil else { continue }
                existingEpisodeMembers[key] = member
            }
            let desiredEpisodeKeys = Set(episodeMembers.map {
                EpisodeKey(feedURL: FeedURLIdentity.canonical($0.feedURL), guid: $0.guid)
            })
            let removedEpisodeKeys = existingEpisodeMembers.keys.filter {
                !desiredEpisodeKeys.contains($0)
            }
            for key in removedEpisodeKeys {
                guard let member = existingEpisodeMembers.removeValue(forKey: key) else { continue }
                appContext.delete(member)
                changed = true
            }
            let episodes = applicationEpisodes(matching: desiredEpisodeKeys)
            for member in episodeMembers {
                let key = EpisodeKey(
                    feedURL: FeedURLIdentity.canonical(member.feedURL),
                    guid: member.guid
                )
                guard let episode = episodes[key] else { continue }
                if let existing = existingEpisodeMembers[key] {
                    if existing.sortOrder != member.sortOrder {
                        existing.sortOrder = member.sortOrder
                        changed = true
                    }
                } else {
                    appContext.insert(EpisodeFolderMembership(
                        folder: folder,
                        episode: episode,
                        sortOrder: member.sortOrder
                    ))
                    changed = true
                }
            }
        }
        if appContext.hasChanges { try appContext.save() }
        if cloudContext.hasChanges { try cloudContext.save() }
        knownLocalFolderIDs = Set(folderByCloudID.keys)
        if !parentRepair.detachedFolderIDs.isEmpty {
            center.post(name: .earshotFolderSyncConflictRepaired, object: nil)
        }
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
        // This is a feed high-water mark, not ordinary last-writer-wins
        // metadata. A delayed CloudKit row must never rewind a device that has
        // already refreshed farther; doing so left Library's Published order
        // stale and made old feed entries eligible for reconsideration.
        target.lastSeenPubDate = [target.lastSeenPubDate, source.lastSeenPubDate]
            .compactMap { $0 }
            .max()
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
        // Publish the furthest high-water mark observed on either side. This
        // converges devices monotonically even when CloudKit import delivery is
        // delayed or another subscription field was edited independently.
        target.lastSeenPubDate = [target.lastSeenPubDate, source.lastSeenPubDate]
            .compactMap { $0 }
            .max()
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
