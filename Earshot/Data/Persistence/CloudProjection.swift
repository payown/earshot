import Foundation
import SwiftData

extension Notification.Name {
    static let earshotCloudProjectionDidApply = Notification.Name(
        "earshotCloudProjectionDidApply"
    )
    static let earshotSubscriptionsDidChange = Notification.Name(
        "earshotSubscriptionsDidChange"
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

@MainActor
final class CloudProjectionCoordinator {
    private struct Value: Equatable {
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

    private let applicationContainer: ModelContainer
    private let projectionContainer: ModelContainer
    private let center: NotificationCenter
    private var importObserver: NSObjectProtocol?
    private var subscriptionObserver: NSObjectProtocol?
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
        let schema = Schema([CloudPodcastProjection.self])
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
        if applicationChanged {
            center.post(name: .earshotCloudProjectionDidApply, object: nil)
        }
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
        let rows = try context.fetch(FetchDescriptor<CloudPodcastProjection>())
        for row in rows where row.deletedAt == nil {
            row.deletedAt = now
            row.modifiedAt = now
            row.sourceDeviceID = deviceID
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

    private func value(_ source: CloudPodcastProjection) -> Value {
        Value(
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

    private func value(_ source: Podcast) -> Value {
        Value(
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
