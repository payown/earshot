import Foundation
import SwiftData
import CoreData
import Observation
import Accessibility

struct WatchFolderSnapshot: Identifiable {
    struct Member: Codable { let feedURL: String; let sortOrder: Int }
    let id: String
    let name: String
    let sortOrder: Int
    let members: [Member]
}

enum WatchProgressResolution {
    /// Mirrors the phone projection's explicit-reset and max-progress rule.
    static func resolve(_ rows: [CloudEpisodeStateProjection],
                        localPosition: Int, localUpdatedAt: Date) -> (position: Int, updatedAt: Date) {
        let reset = rows.compactMap { row in row.positionResetAt.map { ($0, row.positionSeconds) } }
            .max { $0.0 < $1.0 }
        let eligible = rows.filter { reset == nil || $0.positionUpdatedAt > reset!.0 }
        let newest = eligible.map(\.positionUpdatedAt).max() ?? reset?.0 ?? .distantPast
        let merged = max(0, eligible.map(\.positionSeconds).max() ?? reset?.1 ?? 0)
        // The cached local value may itself include a pre-reset maximum. Local
        // edits have already been flushed into `rows` before reconciliation.
        if let reset { return (merged, max(newest, reset.0)) }
        return (max(localPosition, merged), max(localUpdatedAt, newest))
    }
}

enum WatchQueueResolution {
    static let legacyMembershipDate = Date.distantPast.addingTimeInterval(1)

    static func membershipClock(_ row: CloudQueueItemProjection) -> Date {
        row.membershipUpdatedAt == .distantPast ? row.modifiedAt : row.membershipUpdatedAt
    }

    static func membership(_ rows: [CloudQueueItemProjection]) -> CloudQueueItemProjection? {
        rows.max {
            let lhs = membershipClock($0), rhs = membershipClock($1)
            if lhs != rhs { return lhs < rhs }
            if $0.modifiedAt != $1.modifiedAt {
                return $0.modifiedAt < $1.modifiedAt
            }
            return $0.sourceDeviceID > $1.sourceDeviceID
        }
    }

    static func order(_ rows: [CloudQueueItemProjection]) -> CloudQueueItemProjection? {
        rows.filter(\.isQueued).max {
            if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt < $1.modifiedAt }
            return $0.sourceDeviceID > $1.sourceDeviceID
        }
    }
}

enum WatchFolderResolution {
    static func liveLatest(_ rows: [CloudFolderProjection]) -> [CloudFolderProjection] {
        Dictionary(grouping: rows, by: \.folderID).compactMap { _, versions in
            versions.max { lhs, rhs in
                lhs.modifiedAt == rhs.modifiedAt
                    ? lhs.sourceDeviceID < rhs.sourceDeviceID
                    : lhs.modifiedAt < rhs.modifiedAt
            }
        }
        .filter { $0.deletedAt == nil }
    }
}

/// Uses Earshot's existing compact projection schema in a separate watch store.
/// The phone and watch never open one another's application store. Local watch
/// edits remain in WatchPendingSyncEvent until projection storage accepts them.
@MainActor
@Observable
final class WatchCloudSync {
    private let library: WatchLibrary
    private let container: ModelContainer
    private let context: ModelContext
    private let deviceID: String
    private var importObserver: NSObjectProtocol?
    private(set) var lastError: String?
    private(set) var folders: [WatchFolderSnapshot] = []
    private(set) var conflicts: [String] = []

    init(library: WatchLibrary, inMemory: Bool = false) throws {
        self.library = library
        let schema = Schema([
            CloudPodcastProjection.self, CloudEpisodeStateProjection.self,
            CloudQueueItemProjection.self, CloudSettingProjection.self,
            CloudBookmarkProjection.self, CloudListeningSessionProjection.self,
            CloudFolderProjection.self
        ])
        let store = URL.applicationSupportDirectory.appending(path: "WatchCloudProjection.sqlite")
        #if targetEnvironment(simulator)
        let database: ModelConfiguration.CloudKitDatabase = .none
        #else
        let database = CloudKitLaunchPolicy.projectionDatabase()
        #endif
        let config = inMemory
            ? ModelConfiguration("WatchCloudProjectionTest", schema: schema,
                                 isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            : ModelConfiguration("WatchCloudProjection", schema: schema,
                                 url: store, cloudKitDatabase: database)
        container = try ModelContainer(for: schema, configurations: config)
        context = container.mainContext
        if let saved = UserDefaults.standard.string(forKey: "watchProjectionDeviceID") {
            deviceID = saved
        } else {
            let generated = UUID().uuidString
            UserDefaults.standard.set(generated, forKey: "watchProjectionDeviceID")
            deviceID = generated
        }
        conflicts = UserDefaults.standard.stringArray(forKey: "watchSyncConflicts") ?? []
        #if !targetEnvironment(simulator)
        if !inMemory && CloudKitLaunchPolicy.isMirroringEnabled() {
            importObserver = NotificationCenter.default.addObserver(
                forName: NSPersistentCloudKitContainer.eventChangedNotification,
                object: nil, queue: .main
            ) { [weak self] notification in
                guard let event = notification.userInfo?[
                    NSPersistentCloudKitContainer.eventNotificationUserInfoKey
                ] as? NSPersistentCloudKitContainer.Event,
                    event.type == .import, event.endDate != nil, event.succeeded else { return }
                Task { @MainActor [weak self] in self?.reconcile() }
            }
        }
        #endif
    }

    isolated deinit {
        if let importObserver { NotificationCenter.default.removeObserver(importObserver) }
    }

    func reconcile() {
        library.isApplyingCloud = true
        defer { library.isApplyingCloud = false }
        do {
            try flushPending()
            try pullSubscriptions()
            try pullQueue()
            try pullEpisodeStates()
            try pullBookmarks()
            try pullSettings()
            try loadFolders()
            if library.context.hasChanges { library.persist() }
            lastError = nil
        } catch {
            let description = error.localizedDescription
            if lastError != description {
                library.report("Watch synchronization will retry when available. Local changes remain saved.")
            }
            lastError = description
            AppLog.data.error("Watch projection sync failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func flushPending() throws {
        let events = try library.context.fetch(FetchDescriptor<WatchPendingSyncEvent>(
            sortBy: [SortDescriptor(\.createdAt)]))
        for event in events {
            let payload = try JSONDecoder().decode(WatchSyncPayload.self, from: event.payload)
            switch event.kind {
            case "follow", "unfollow": try publishSubscription(event, payload: payload)
            case "episode": try publishEpisode(event, payload: payload)
            case "queue": try publishQueue(event, payload: payload)
            case "bookmark", "removeBookmark": try publishBookmark(event, payload: payload)
            case "setting": try publishSetting(event, payload: payload)
            default: continue
            }
            if context.hasChanges { try context.save() }
            library.context.delete(event)
            try library.context.save()
        }
    }

    private func publishSubscription(_ event: WatchPendingSyncEvent, payload: WatchSyncPayload) throws {
        let feed = payload.feedURL
        let rows = try context.fetch(FetchDescriptor<CloudPodcastProjection>(predicate: #Predicate { $0.feedURL == feed }))
        let row = rows.max(by: { $0.modifiedAt < $1.modifiedAt }) ?? CloudPodcastProjection()
        if row.modelContext == nil { context.insert(row) }
        // A newer remote action wins, and pullSubscriptions reports the change.
        guard row.modifiedAt <= event.createdAt else {
            if (row.deletedAt == nil) != (event.kind == "follow") {
                recordConflict("Subscription changed on another device: \(payload.title). Review Library and choose again if needed.")
            }
            return
        }
        row.feedURL = feed
        row.title = payload.title
        row.author = payload.author
        row.podcastDescription = payload.summary
        row.artworkURL = payload.artworkURL
        row.modifiedAt = event.createdAt
        row.deletedAt = event.kind == "unfollow" ? event.createdAt : nil
        row.sourceDeviceID = deviceID
    }

    private func publishEpisode(_ event: WatchPendingSyncEvent, payload: WatchSyncPayload) throws {
        let feed = payload.feedURL, guid = payload.guid, source = deviceID
        let rows = try context.fetch(FetchDescriptor<CloudEpisodeStateProjection>(predicate: #Predicate {
            $0.feedURL == feed && $0.episodeGUID == guid && $0.sourceDeviceID == source
        }))
        let row = rows.first ?? CloudEpisodeStateProjection()
        if row.modelContext == nil { context.insert(row) }
        row.feedURL = feed
        row.episodeGUID = guid
        row.sourceDeviceID = deviceID
        if let reset = payload.positionResetAt,
           reset > (row.positionResetAt ?? .distantPast) { row.positionResetAt = reset }
        if payload.positionUpdatedAt > row.positionUpdatedAt {
            row.positionSeconds = max(0, payload.position)
            row.positionUpdatedAt = payload.positionUpdatedAt
        }
        if payload.playedUpdatedAt > row.playedUpdatedAt {
            row.isPlayed = payload.isPlayed
            row.playedUpdatedAt = payload.playedUpdatedAt
        }
        if payload.inboxUpdatedAt > row.inboxDismissedUpdatedAt {
            row.inboxDismissed = payload.inboxDismissed
            row.inboxDismissedUpdatedAt = payload.inboxUpdatedAt
        }
        row.modifiedAt = max(row.modifiedAt, event.createdAt)
        row.deletedAt = nil
    }

    private func publishQueue(_ event: WatchPendingSyncEvent, payload: WatchSyncPayload) throws {
        let feed = payload.feedURL, guid = payload.guid, source = deviceID
        let rows = try context.fetch(FetchDescriptor<CloudQueueItemProjection>(predicate: #Predicate {
            $0.feedURL == feed && $0.episodeGUID == guid && $0.sourceDeviceID == source
        }))
        let row = rows.first ?? CloudQueueItemProjection()
        if row.modelContext == nil { context.insert(row) }
        row.feedURL = feed
        row.episodeGUID = guid
        row.sourceDeviceID = deviceID
        row.episodeTitle = payload.title
        row.episodeAudioURL = payload.audioURL
        row.episodeDescription = payload.summary
        if payload.membershipUpdatedAt > row.membershipUpdatedAt {
            row.isQueued = payload.isQueued
            row.membershipUpdatedAt = payload.membershipUpdatedAt
        }
        if payload.orderUpdatedAt > row.modifiedAt {
            row.position = payload.queuePosition
            row.modifiedAt = payload.orderUpdatedAt
        }
        row.deletedAt = nil
    }

    private func publishBookmark(_ event: WatchPendingSyncEvent, payload: WatchSyncPayload) throws {
        let identifier = payload.bookmarkID
        let rows = try context.fetch(FetchDescriptor<CloudBookmarkProjection>(predicate: #Predicate { $0.bookmarkID == identifier }))
        let row = rows.max(by: { $0.modifiedAt < $1.modifiedAt }) ?? CloudBookmarkProjection()
        if row.modelContext == nil { context.insert(row) }
        guard row.modifiedAt <= event.createdAt else { return }
        row.bookmarkID = identifier
        row.feedURL = payload.feedURL
        row.episodeGUID = payload.guid
        row.positionSeconds = payload.bookmarkPosition
        row.createdAt = row.createdAt == .distantPast ? event.createdAt : row.createdAt
        row.modifiedAt = event.createdAt
        row.deletedAt = event.kind == "removeBookmark" ? event.createdAt : nil
        row.sourceDeviceID = deviceID
    }

    private func publishSetting(_ event: WatchPendingSyncEvent, payload: WatchSyncPayload) throws {
        let key = payload.settingKey, source = deviceID
        let rows = try context.fetch(FetchDescriptor<CloudSettingProjection>(predicate: #Predicate {
            $0.key == key && $0.sourceDeviceID == source
        }))
        let row = rows.first ?? CloudSettingProjection()
        if row.modelContext == nil { context.insert(row) }
        guard row.modifiedAt <= event.createdAt else { return }
        row.key = key
        row.value = payload.settingValue
        row.sourceDeviceID = source
        row.modifiedAt = event.createdAt
        row.deletedAt = nil
    }

    private func pullSubscriptions() throws {
        let rows = try context.fetch(FetchDescriptor<CloudPodcastProjection>())
        let latest = Dictionary(grouping: rows, by: { FeedURLIdentity.canonical($0.feedURL) })
            .compactMapValues { $0.max { $0.modifiedAt < $1.modifiedAt } }
        for (feed, row) in latest {
            let local = library.podcasts.first { FeedURLIdentity.matches($0.feedURL, feed) }
            if let deleted = row.deletedAt {
                if let local, deleted >= local.modifiedAt {
                    library.context.delete(local)
                    recordConflict("Podcast unfollowed on another device: \(local.title). Review Library and follow again if needed.")
                }
            } else if let local {
                if row.modifiedAt > local.modifiedAt {
                    local.title = row.title
                    local.author = row.author ?? ""
                    local.summary = row.podcastDescription ?? ""
                    local.artworkURL = row.artworkURL
                    local.modifiedAt = row.modifiedAt
                }
            } else {
                if row.sourceDeviceID != deviceID {
                    recordConflict("Podcast followed on another device: \(row.title). Review Library if unexpected.")
                }
                let podcast = WatchPodcast(feedURL: feed, title: row.title,
                                           author: row.author ?? "", summary: row.podcastDescription ?? "",
                                           artworkURL: row.artworkURL)
                podcast.modifiedAt = row.modifiedAt
                library.context.insert(podcast)
            }
        }
        library.reload()
    }

    private func pullEpisodeStates() throws {
        var rows: [CloudEpisodeStateProjection] = []
        for (feed, episodes) in Dictionary(grouping: library.episodes, by: \.feedURL) {
            let guids = episodes.map(\.guid)
            rows += try context.fetch(FetchDescriptor<CloudEpisodeStateProjection>(predicate: #Predicate {
                $0.feedURL == feed && guids.contains($0.episodeGUID)
            }))
        }
        rows = rows.filter { $0.deletedAt == nil && !$0.episodeGUID.isEmpty }
        let grouped = Dictionary(grouping: rows, by: { WatchEpisode.key(feedURL: $0.feedURL, guid: $0.episodeGUID) })
        for episode in library.episodes {
            guard let contributions = grouped[episode.identity] else { continue }
            let played = contributions.max {
                $0.playedUpdatedAt == $1.playedUpdatedAt ? $0.sourceDeviceID > $1.sourceDeviceID : $0.playedUpdatedAt < $1.playedUpdatedAt
            }
            if let played, played.playedUpdatedAt > episode.playedUpdatedAt {
                if episode.playedUpdatedAt != .distantPast, played.isPlayed != episode.isPlayed,
                   played.sourceDeviceID != deviceID {
                    recordConflict("Played status changed on another device: \(episode.title).")
                }
                episode.isPlayed = played.isPlayed
                episode.playedUpdatedAt = played.playedUpdatedAt
            }
            let dismissed = contributions.filter { $0.inboxDismissedUpdatedAt != .distantPast }.max {
                $0.inboxDismissedUpdatedAt == $1.inboxDismissedUpdatedAt ? $0.sourceDeviceID > $1.sourceDeviceID : $0.inboxDismissedUpdatedAt < $1.inboxDismissedUpdatedAt
            }
            if let dismissed, dismissed.inboxDismissedUpdatedAt > episode.inboxDismissedUpdatedAt {
                episode.inboxDismissed = dismissed.inboxDismissed
                episode.inboxDismissedUpdatedAt = dismissed.inboxDismissedUpdatedAt
            }
            let merged = WatchProgressResolution.resolve(contributions,
                                                         localPosition: Int(episode.positionSeconds),
                                                         localUpdatedAt: episode.positionUpdatedAt)
            episode.positionSeconds = episode.isPlayed ? 0 : Double(merged.position)
            episode.positionUpdatedAt = merged.updatedAt
            episode.positionResetAt = contributions.compactMap(\.positionResetAt).max()
        }
    }

    private func pullQueue() throws {
        let rows = try context.fetch(FetchDescriptor<CloudQueueItemProjection>())
            .filter { $0.deletedAt == nil && !$0.episodeGUID.isEmpty }
        let grouped = Dictionary(grouping: rows, by: { WatchEpisode.key(feedURL: $0.feedURL, guid: $0.episodeGUID) })
        for (key, contributions) in grouped {
            let membership = WatchQueueResolution.membership(contributions)
            guard let membership else { continue }
            let order = WatchQueueResolution.order(contributions) ?? membership
            let existing = library.episodes.first { $0.identity == key }
            guard membership.isQueued || existing != nil else { continue }
            let episode = existing ?? {
                guard let title = order.episodeTitle, let audio = order.episodeAudioURL else { return nil }
                let podcastTitle = library.podcasts.first { $0.feedURL == order.feedURL }?.title ?? "Podcast"
                return library.playablePhoneEpisode(feedURL: order.feedURL, guid: order.episodeGUID,
                                                    title: title, podcastTitle: podcastTitle, audioURL: audio)
            }()
            guard let episode else { continue }
            let membershipDate = WatchQueueResolution.membershipClock(membership)
            if membershipDate > episode.queueMembershipUpdatedAt {
                if episode.queueMembershipUpdatedAt != .distantPast,
                   membership.isQueued != (episode.queuePosition != nil),
                   membership.sourceDeviceID != deviceID {
                    recordConflict("Queue membership changed on another device: \(episode.title).")
                }
                episode.queuePosition = membership.isQueued ? order.position : nil
                episode.queueMembershipUpdatedAt = membershipDate
                episode.queueOrderUpdatedAt = order.modifiedAt
            } else if membership.isQueued, order.modifiedAt > episode.queueOrderUpdatedAt {
                if episode.queueOrderUpdatedAt != .distantPast,
                   episode.queuePosition != order.position, order.sourceDeviceID != deviceID {
                    recordConflict("Queue order changed on another device: \(episode.title).")
                }
                episode.queuePosition = order.position
                episode.queueOrderUpdatedAt = order.modifiedAt
            }
        }
    }

    private func pullBookmarks() throws {
        let rows = try context.fetch(FetchDescriptor<CloudBookmarkProjection>())
        let latest = Dictionary(grouping: rows, by: \.bookmarkID).compactMapValues { $0.max { $0.modifiedAt < $1.modifiedAt } }
        for (identifier, row) in latest {
            if let existing = library.bookmarks.first(where: { $0.id == identifier }) {
                if row.deletedAt != nil {
                    if row.sourceDeviceID != deviceID {
                        recordConflict("Bookmark removed on another device: \(existing.episodeTitle).")
                    }
                    library.context.delete(existing)
                }
            } else if row.deletedAt == nil,
                      let episode = library.episodes.first(where: { $0.identity == WatchEpisode.key(feedURL: row.feedURL, guid: row.episodeGUID) }) {
                let bookmark = WatchBookmark(episode: episode)
                bookmark.id = identifier
                bookmark.positionSeconds = Double(row.positionSeconds)
                bookmark.createdAt = row.createdAt
                library.context.insert(bookmark)
            }
        }
    }

    private func loadFolders() throws {
        let rows = try context.fetch(FetchDescriptor<CloudFolderProjection>())
        folders = WatchFolderResolution.liveLatest(rows)
            .compactMap { row in
                guard let data = row.podcastMembersJSON.data(using: .utf8),
                      let members = try? JSONDecoder().decode([WatchFolderSnapshot.Member].self, from: data) else {
                    return nil
                }
                return WatchFolderSnapshot(id: row.folderID, name: row.name,
                                           sortOrder: row.sortOrder, members: members)
            }
            .sorted { $0.sortOrder == $1.sortOrder ? $0.name < $1.name : $0.sortOrder < $1.sortOrder }
    }

    private func pullSettings() throws {
        let rows = try context.fetch(FetchDescriptor<CloudSettingProjection>())
            .filter { $0.deletedAt == nil }
        for (key, contributions) in Dictionary(grouping: rows, by: \.key) {
            guard let winner = contributions.max(by: { $0.modifiedAt < $1.modifiedAt }),
                  let value = Int(winner.value) else { continue }
            switch key {
            case "skip_back_seconds" where (5...60).contains(value): library.skipBackward = value
            case "skip_forward_seconds" where (5...120).contains(value): library.skipForward = value
            default: break
            }
        }
    }

    func clearConflicts() {
        conflicts = []
        UserDefaults.standard.removeObject(forKey: "watchSyncConflicts")
    }

    private func recordConflict(_ message: String) {
        guard !conflicts.contains(message) else { return }
        conflicts.append(message)
        conflicts = Array(conflicts.suffix(20))
        UserDefaults.standard.set(conflicts, forKey: "watchSyncConflicts")
        AccessibilityNotification.Announcement(message).post()
    }

#if DEBUG
    func episodeContributionCountForTesting() throws -> Int {
        try context.fetchCount(FetchDescriptor<CloudEpisodeStateProjection>())
    }

    func insertForTesting(_ row: CloudQueueItemProjection) throws {
        context.insert(row)
        try context.save()
    }

    func insertForTesting(_ row: CloudEpisodeStateProjection) throws {
        context.insert(row)
        try context.save()
    }
#endif
}
