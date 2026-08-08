import Foundation
import SwiftData

extension Notification.Name {
    static let earshotCloudProjectionDidApply = Notification.Name(
        "earshotCloudProjectionDidApply"
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
    private var reconcileTask: Task<Void, Never>?

    init(
        applicationContainer: ModelContainer,
        projectionContainer: ModelContainer,
        center: NotificationCenter = .default
    ) {
        self.applicationContainer = applicationContainer
        self.projectionContainer = projectionContainer
        self.center = center
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
        try reconcile()
    }

    func stop() async {
        if let importObserver {
            center.removeObserver(importObserver)
            self.importObserver = nil
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
        let appContext = applicationContainer.mainContext
        let cloudContext = projectionContainer.mainContext
        let cloudRows = try cloudContext.fetch(FetchDescriptor<CloudPodcastProjection>())
        var cloudByFeed: [String: CloudPodcastProjection] = [:]
        for row in cloudRows.sorted(by: Self.projectionOrder) {
            let key = FeedURLIdentity.canonical(row.feedURL)
            if cloudByFeed[key] == nil { cloudByFeed[key] = row }
        }

        var applicationChanged = false
        for row in cloudByFeed.values.sorted(by: Self.projectionOrder) {
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
            if value(podcast) != value(row) {
                copy(podcast, to: row)
            }
        }
        if cloudContext.hasChanges { try cloudContext.save() }
        if applicationChanged {
            center.post(name: .earshotCloudProjectionDidApply, object: nil)
        }
    }

    private static func projectionOrder(
        _ lhs: CloudPodcastProjection,
        _ rhs: CloudPodcastProjection
    ) -> Bool {
        if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt > rhs.modifiedAt }
        return FeedURLIdentity.canonical(lhs.feedURL) < FeedURLIdentity.canonical(rhs.feedURL)
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
    }
}
