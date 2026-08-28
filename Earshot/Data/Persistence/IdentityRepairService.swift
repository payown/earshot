import Foundation
import SwiftData

/// The single feed-URL identity rule used by every subscription entry point.
///
/// HTTP scheme and host names are case-insensitive, default ports do not change
/// the resource, and fragments are never sent to the feed server. Path, query,
/// percent encoding, and their case remain byte-for-byte intact because feeds
/// can legitimately distinguish them.
enum FeedURLIdentity {
    static func canonical(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme,
              let host = components.host
        else { return trimmed }

        let lowercaseScheme = scheme.lowercased()
        components.scheme = lowercaseScheme
        components.host = host.lowercased()
        if (lowercaseScheme == "http" && components.port == 80)
            || (lowercaseScheme == "https" && components.port == 443) {
            components.port = nil
        }
        components.fragment = nil
        return components.string ?? trimmed
    }

    static func matches(_ lhs: String, _ rhs: String) -> Bool {
        canonical(lhs) == canonical(rhs)
    }
}

/// Serializes in-process podcast creation by canonical feed URL. SwiftData's
/// fetch-then-insert sequence cannot be made atomic across independent model
/// contexts once CloudKit compatibility removes the database unique constraint.
/// Holding these keys through the caller's save closes that race; duplicate
/// repair remains necessary for legacy rows and records arriving from sync.
actor PodcastIdentityWriteGate {
    static let shared = PodcastIdentityWriteGate()

    private var heldKeys: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func acquire(feedURLs: [String]) async {
        let keys = Set(feedURLs.map(FeedURLIdentity.canonical)).sorted()
        for key in keys { await acquire(key) }
    }

    func release(feedURLs: [String]) {
        let keys = Set(feedURLs.map(FeedURLIdentity.canonical)).sorted().reversed()
        for key in keys { release(key) }
    }

    private func acquire(_ key: String) async {
        guard heldKeys.contains(key) else {
            heldKeys.insert(key)
            return
        }
        await withCheckedContinuation { continuation in
            waiters[key, default: []].append(continuation)
        }
    }

    private func release(_ key: String) {
        if var queued = waiters[key], !queued.isEmpty {
            let next = queued.removeFirst()
            waiters[key] = queued.isEmpty ? nil : queued
            next.resume()
        } else {
            heldKeys.remove(key)
        }
    }
}

/// Central fetch-or-create behavior for the Podcast natural key. The final
/// recheck is intentionally cheap (Podcast is a small table) and also finds
/// pre-canonical rows written by older builds.
struct PodcastIdentityService {
    let context: ModelContext

    /// Fetches Podcast values without asking Core Data to populate any inverse
    /// relationships. Callers that only need subscription metadata must not make
    /// their cost proportional to the number of Episodes in the library.
    func scalarPodcasts() throws -> [Podcast] {
        var descriptor = FetchDescriptor<Podcast>()
        descriptor.propertiesToFetch = [
            \Podcast.feedURL, \Podcast.title, \Podcast.author,
            \Podcast.podcastDescription, \Podcast.artworkURL, \Podcast.websiteURL,
            \Podcast.language, \Podcast.category, \Podcast.autoQueue,
            \Podcast.notificationEnabled, \Podcast.speedOverride,
            \Podcast.trimSilenceOverride, \Podcast.introSkipSeconds,
            \Podcast.queueAgeLimitDays, \Podcast.inboxMaxEpisodes,
            \Podcast.inboxAgeLimitHours, \Podcast.inboxExcluded,
            \Podcast.inboxIncluded, \Podcast.createdAt, \Podcast.lastSeenPubDate,
        ]
        return try context.fetch(descriptor)
    }

    /// Resolves a whole import against one deliberately narrow fetch. Import used
    /// to call ``existing(feedURL:)`` once per URL; Core Data consequently executed
    /// and populated relationship faults hundreds of times on the actor executor.
    /// Fetch only scalar identity fields once, then classify in memory.
    func existingByCanonicalFeedURL(for feedURLs: [String]) throws -> [String: Podcast] {
        let requested = Set(feedURLs.map(FeedURLIdentity.canonical))
        guard !requested.isEmpty else { return [:] }

        let podcasts = try scalarPodcasts()
        var matches: [String: Podcast] = [:]
        for podcast in podcasts {
            let canonical = FeedURLIdentity.canonical(podcast.feedURL)
            guard requested.contains(canonical) else { continue }
            if let current = matches[canonical] {
                matches[canonical] = Self.deterministicPodcast(in: [current, podcast])
            } else {
                matches[canonical] = podcast
            }
        }
        return matches
    }

    func existing(feedURL: String) throws -> Podcast? {
        let canonical = FeedURLIdentity.canonical(feedURL)
        var exactDescriptor = FetchDescriptor<Podcast>(
            predicate: #Predicate { $0.feedURL == canonical }
        )
        exactDescriptor.propertiesToFetch = [
            \Podcast.feedURL, \Podcast.title, \Podcast.createdAt,
        ]
        let exact = try context.fetch(exactDescriptor)
        if let winner = Self.deterministicPodcast(in: exact) { return winner }

        let legacyMatches = try scalarPodcasts()
            .filter { FeedURLIdentity.canonical($0.feedURL) == canonical }
        return Self.deterministicPodcast(in: legacyMatches)
    }

    func fetchOrCreate(
        feedURL: String,
        create: (_ canonicalFeedURL: String) -> Podcast
    ) throws -> (podcast: Podcast, inserted: Bool) {
        if let existing = try existing(feedURL: feedURL) {
            return (existing, false)
        }
        let podcast = create(FeedURLIdentity.canonical(feedURL))
        context.insert(podcast)
        return (podcast, true)
    }

    private static func deterministicPodcast(in podcasts: [Podcast]) -> Podcast? {
        podcasts.min {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return stableID($0) < stableID($1)
        }
    }
}

/// Deterministic access to settings once the database uniqueness constraint is
/// removed. A caller's explicit write always wins; duplicate stored rows are
/// collapsed in the same save.
enum AppSettingIdentity {
    static func canonicalKey(_ rawKey: String) -> String {
        for prefix in [SettingsKey.podcastFilterPrefix, SettingsKey.podcastInboxCapPrefix]
        where rawKey.hasPrefix(prefix) {
            return prefix + FeedURLIdentity.canonical(String(rawKey.dropFirst(prefix.count)))
        }
        return rawKey
    }

    static func rows(for rawKey: String, in context: ModelContext) throws -> [AppSetting] {
        let key = canonicalKey(rawKey)
        var matches = try context.fetch(
            FetchDescriptor<AppSetting>(predicate: #Predicate { $0.key == key })
        )
        if key.hasPrefix(SettingsKey.podcastFilterPrefix)
            || key.hasPrefix(SettingsKey.podcastInboxCapPrefix) {
            let existingIDs = Set(matches.map(\.persistentModelID))
            matches.append(
                contentsOf: try context.fetch(FetchDescriptor<AppSetting>()).filter {
                    !existingIDs.contains($0.persistentModelID) && canonicalKey($0.key) == key
                }
            )
        }
        return matches.sorted { stableID($0) < stableID($1) }
    }

    static func value(for key: String, in context: ModelContext) -> String? {
        try? rows(for: key, in: context).first?.value
    }

    static func setValue(_ value: String, for rawKey: String, in context: ModelContext) throws {
        let key = canonicalKey(rawKey)
        let matches = try rows(for: key, in: context)
        let survivor: AppSetting
        if let first = matches.first {
            survivor = first
        } else {
            survivor = AppSetting(key: key, value: value)
            context.insert(survivor)
        }
        survivor.key = key
        survivor.value = value
        for duplicate in matches.dropFirst() { context.delete(duplicate) }
    }
}

enum LocalAppSettingIdentity {
    static func rows(for key: String, in context: ModelContext) throws -> [LocalAppSetting] {
        try context.fetch(
            FetchDescriptor<LocalAppSetting>(predicate: #Predicate { $0.key == key })
        ).sorted { stableID($0) < stableID($1) }
    }

    static func value(for key: String, in context: ModelContext) -> String? {
        try? rows(for: key, in: context).first?.value
    }

    static func setValue(_ value: String, for key: String, in context: ModelContext) throws {
        let matches = try rows(for: key, in: context)
        let survivor = matches.first ?? LocalAppSetting(key: key, value: value)
        if matches.isEmpty { context.insert(survivor) }
        survivor.key = key
        survivor.value = value
        for duplicate in matches.dropFirst() { context.delete(duplicate) }
    }
}

struct IdentityRepairReport: Equatable {
    var podcastsInspected = 0
    var settingsInspected = 0
    var episodesInspected = 0
    var podcastsRemoved = 0
    var settingsRemoved = 0
    var episodesRemoved = 0
    var relationshipsRetargeted = 0

    static let none = IdentityRepairReport()

    var didChange: Bool {
        podcastsRemoved > 0 || settingsRemoved > 0 || episodesRemoved > 0
            || relationshipsRetargeted > 0
    }

    mutating func add(_ other: IdentityRepairReport) {
        podcastsInspected += other.podcastsInspected
        settingsInspected += other.settingsInspected
        episodesInspected += other.episodesInspected
        podcastsRemoved += other.podcastsRemoved
        settingsRemoved += other.settingsRemoved
        episodesRemoved += other.episodesRemoved
        relationshipsRetargeted += other.relationshipsRetargeted
    }
}

/// Repairs natural-key duplicates without ever scanning the full Episode table.
/// A launch pass reads only Podcast and AppSetting (both intentionally small),
/// then touches episodes solely for duplicate podcast groups. Callers that know
/// a podcast changed can request a targeted per-podcast episode repair.
struct IdentityRepairService {
    let context: ModelContext

    func repairAll() throws -> IdentityRepairReport {
        var report = try repairPodcastGroups(matching: nil)
        report.add(try repairSettings())
        return report
    }

    func repair(feedURLs: [String]) throws -> IdentityRepairReport {
        let keys = Set(feedURLs.map(FeedURLIdentity.canonical))
        guard !keys.isEmpty else { return .none }
        return try repairPodcastGroups(matching: keys)
    }

    func repairEpisodes(
        in podcast: Podcast,
        matchingGUIDs requestedGUIDs: [String]? = nil
    ) throws -> IdentityRepairReport {
        let podcastID = podcast.persistentModelID
        let episodes: [Episode]
        if let requestedGUIDs {
            guard !requestedGUIDs.isEmpty else { return .none }
            episodes = try context.fetch(
                FetchDescriptor<Episode>(
                    predicate: #Predicate {
                        $0.podcast?.persistentModelID == podcastID
                            && requestedGUIDs.contains($0.guid)
                    }
                )
            )
        } else {
            episodes = try context.fetch(FetchDescriptor<Episode>(
                predicate: #Predicate { $0.podcast?.persistentModelID == podcastID }
            ))
        }
        var report = IdentityRepairReport(episodesInspected: episodes.count)
        try repairEpisodeGroups(episodes, survivorPodcast: podcast, report: &report)
        return report
    }

    private func repairPodcastGroups(
        matching requestedKeys: Set<String>?
    ) throws -> IdentityRepairReport {
        let podcasts = try context.fetch(FetchDescriptor<Podcast>())
        var report = IdentityRepairReport(podcastsInspected: podcasts.count)
        let groups = Dictionary(grouping: podcasts) {
            FeedURLIdentity.canonical($0.feedURL)
        }

        for (canonical, group) in groups.sorted(by: { $0.key < $1.key }) {
            guard requestedKeys == nil || requestedKeys?.contains(canonical) == true else { continue }
            if group.count == 1 {
                // Normalize a lone legacy row without touching its episode graph.
                if group[0].feedURL != canonical {
                    group[0].feedURL = canonical
                    report.relationshipsRetargeted += 1
                }
                continue
            }
            try mergePodcastGroup(group, canonicalFeedURL: canonical, report: &report)
        }
        return report
    }

    private func mergePodcastGroup(
        _ group: [Podcast],
        canonicalFeedURL: String,
        report: inout IdentityRepairReport
    ) throws {
        let ordered = group.sorted(by: podcastOrder)
        guard let survivor = ordered.first else { return }
        let newest = ordered.max(by: podcastOrder) ?? survivor
        let groupIDs = Set(group.map(\.persistentModelID))

        mergePodcastValues(from: group, newest: newest, into: survivor)

        let folderMemberships = try context.fetch(FetchDescriptor<FolderMembership>())
            .filter { membership in
                membership.podcast.map { groupIDs.contains($0.persistentModelID) } ?? false
            }
        for membership in folderMemberships where membership.podcast?.persistentModelID != survivor.persistentModelID {
            membership.podcast = survivor
            report.relationshipsRetargeted += 1
        }
        deduplicatePodcastMemberships(folderMemberships, report: &report)

        for duplicatePodcast in ordered.dropFirst() {
            let duplicateID = duplicatePodcast.persistentModelID
            let sessions = try context.fetch(
                FetchDescriptor<ListeningSession>(
                    predicate: #Predicate { $0.podcast?.persistentModelID == duplicateID }
                )
            )
            for session in sessions {
                session.podcast = survivor
                report.relationshipsRetargeted += 1
            }
        }

        let episodes = group.flatMap { $0.episodes ?? [] }
        report.episodesInspected += episodes.count
        try repairEpisodeGroups(episodes, survivorPodcast: survivor, report: &report)

        for episode in episodes where episode.podcast?.persistentModelID != survivor.persistentModelID {
            episode.podcast = survivor
            report.relationshipsRetargeted += 1
        }
        for duplicatePodcast in ordered.dropFirst() {
            context.delete(duplicatePodcast)
            report.podcastsRemoved += 1
        }
        survivor.feedURL = canonicalFeedURL
        LocalStateStore.setRefreshedAt(survivor.refreshedAt, on: survivor, in: context)
    }

    private func repairEpisodeGroups(
        _ episodes: [Episode],
        survivorPodcast: Podcast,
        report: inout IdentityRepairReport
    ) throws {
        let groups = Dictionary(grouping: episodes, by: \.guid)
        for (_, group) in groups.sorted(by: { $0.key < $1.key }) {
            if group.count == 1 {
                if group[0].podcast?.persistentModelID != survivorPodcast.persistentModelID {
                    group[0].podcast = survivorPodcast
                    report.relationshipsRetargeted += 1
                }
                continue
            }
            try mergeEpisodeGroup(group, survivorPodcast: survivorPodcast, report: &report)
        }
    }

    private func mergeEpisodeGroup(
        _ group: [Episode],
        survivorPodcast: Podcast,
        report: inout IdentityRepairReport
    ) throws {
        let ordered = group.sorted(by: episodeOrder)
        guard let survivor = ordered.first else { return }
        let duplicateIDs = Set(ordered.dropFirst().map(\.persistentModelID))
        if !duplicateIDs.isEmpty {
            // Identity repair can run on a background ModelActor while the
            // player retains one of these rows on the main actor. Release that
            // model before SwiftData invalidates it; the main-queue observer is
            // delivered synchronously before this post returns.
            NotificationCenter.default.post(
                name: .earshotWillDeleteEpisodes,
                object: nil,
                userInfo: [PlayerService.willDeleteEpisodeIDsKey: duplicateIDs]
            )
        }
        let freshest = group.max(by: episodeFreshnessOrder) ?? survivor
        mergeEpisodeValues(from: group, freshest: freshest, into: survivor)
        survivor.podcast = survivorPodcast

        let queueItems = group.compactMap(\.queueItem)
        if let keeper = queueItems.min(by: queueItemOrder) {
            keeper.episode = survivor
            keeper.position = queueItems.map(\.position).min() ?? keeper.position
            keeper.addedAt = queueItems.map(\.addedAt).max() ?? keeper.addedAt
            for extra in queueItems where extra.persistentModelID != keeper.persistentModelID {
                context.delete(extra)
            }
            survivor.status = .inQueue
        }

        let expirations = group.compactMap(\.recentlyExpired)
        if let keeper = expirations.max(by: { $0.expiredAt < $1.expiredAt }) {
            keeper.episode = survivor
            for extra in expirations where extra.persistentModelID != keeper.persistentModelID {
                context.delete(extra)
            }
        }

        for duplicate in ordered.dropFirst() {
            for bookmark in duplicate.bookmarks ?? [] {
                bookmark.episode = survivor
                report.relationshipsRetargeted += 1
            }
            try retargetOneWayEpisodeRelationships(from: duplicate, to: survivor, report: &report)
            context.delete(duplicate)
            report.episodesRemoved += 1
        }

        // This also collapses duplicate active rows and removes them when a
        // preserved local file makes the merged state terminal (.downloaded).
        ActiveDownload.setDownloadStatus(survivor.downloadStatus, on: survivor, in: context)
        try deduplicateEpisodeMemberships(for: survivor, report: &report)
    }

    private func retargetOneWayEpisodeRelationships(
        from duplicate: Episode,
        to survivor: Episode,
        report: inout IdentityRepairReport
    ) throws {
        let duplicateID = duplicate.persistentModelID
        let sessions = try context.fetch(
            FetchDescriptor<ListeningSession>(
                predicate: #Predicate { $0.episode?.persistentModelID == duplicateID }
            )
        )
        for session in sessions {
            session.episode = survivor
            report.relationshipsRetargeted += 1
        }
        let memberships = try context.fetch(
            FetchDescriptor<EpisodeFolderMembership>(
                predicate: #Predicate { $0.episode?.persistentModelID == duplicateID }
            )
        )
        for membership in memberships {
            membership.episode = survivor
            report.relationshipsRetargeted += 1
        }
    }

    private func repairSettings() throws -> IdentityRepairReport {
        let settings = try context.fetch(FetchDescriptor<AppSetting>())
        var report = IdentityRepairReport(settingsInspected: settings.count)
        let groups = Dictionary(grouping: settings) { AppSettingIdentity.canonicalKey($0.key) }
        for (canonical, group) in groups.sorted(by: { $0.key < $1.key }) {
            let ordered = group.sorted { stableID($0) < stableID($1) }
            guard let survivor = ordered.first else { continue }
            if survivor.key != canonical { report.relationshipsRetargeted += 1 }
            survivor.key = canonical
            for duplicate in ordered.dropFirst() {
                context.delete(duplicate)
                report.settingsRemoved += 1
            }
        }
        return report
    }

    private func deduplicatePodcastMemberships(
        _ memberships: [FolderMembership],
        report: inout IdentityRepairReport
    ) {
        let grouped = Dictionary(grouping: memberships) { membership in
            membership.folder.map { stableID($0) } ?? "nil"
        }
        for group in grouped.values where group.count > 1 {
            let ordered = group.sorted {
                if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
                return stableID($0) < stableID($1)
            }
            for duplicate in ordered.dropFirst() {
                context.delete(duplicate)
                report.relationshipsRetargeted += 1
            }
        }
    }

    private func deduplicateEpisodeMemberships(
        for episode: Episode,
        report: inout IdentityRepairReport
    ) throws {
        let episodeID = episode.persistentModelID
        let memberships = try context.fetch(
            FetchDescriptor<EpisodeFolderMembership>(
                predicate: #Predicate { $0.episode?.persistentModelID == episodeID }
            )
        )
        let grouped = Dictionary(grouping: memberships) { membership in
            membership.folder.map { stableID($0) } ?? "nil"
        }
        for group in grouped.values where group.count > 1 {
            let ordered = group.sorted {
                if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
                return stableID($0) < stableID($1)
            }
            for duplicate in ordered.dropFirst() {
                context.delete(duplicate)
                report.relationshipsRetargeted += 1
            }
        }
    }

    private func mergePodcastValues(
        from group: [Podcast], newest: Podcast, into survivor: Podcast
    ) {
        survivor.title = newest.title.isEmpty ? survivor.title : newest.title
        survivor.author = newest.author ?? group.compactMap(\.author).last
        survivor.podcastDescription = newest.podcastDescription ?? group.compactMap(\.podcastDescription).last
        survivor.artworkURL = newest.artworkURL ?? group.compactMap(\.artworkURL).last
        survivor.websiteURL = newest.websiteURL ?? group.compactMap(\.websiteURL).last
        survivor.language = newest.language ?? group.compactMap(\.language).last
        survivor.category = newest.category ?? group.compactMap(\.category).last
        survivor.autoQueue = newest.autoQueue
        survivor.notificationEnabled = newest.notificationEnabled ?? group.compactMap(\.notificationEnabled).last
        survivor.speedOverride = newest.speedOverride ?? group.compactMap(\.speedOverride).last
        survivor.trimSilenceOverride = newest.trimSilenceOverride ?? group.compactMap(\.trimSilenceOverride).last
        survivor.introSkipSeconds = newest.introSkipSeconds ?? group.compactMap(\.introSkipSeconds).last
        survivor.queueAgeLimitDays = newest.queueAgeLimitDays ?? group.compactMap(\.queueAgeLimitDays).last
        survivor.inboxMaxEpisodes = newest.inboxMaxEpisodes ?? group.compactMap(\.inboxMaxEpisodes).last
        survivor.inboxAgeLimitHours = newest.inboxAgeLimitHours ?? group.compactMap(\.inboxAgeLimitHours).last
        survivor.inboxExcluded = newest.inboxExcluded
        survivor.inboxIncluded = newest.inboxIncluded
        survivor.createdAt = group.map(\.createdAt).min() ?? survivor.createdAt
        survivor.refreshedAt = group.compactMap(\.refreshedAt).max()
        survivor.lastSeenPubDate = group.compactMap(\.lastSeenPubDate).max()
    }

    private func mergeEpisodeValues(
        from group: [Episode], freshest: Episode, into survivor: Episode
    ) {
        survivor.title = freshest.title.isEmpty ? survivor.title : freshest.title
        survivor.audioURL = freshest.audioURL.isEmpty ? survivor.audioURL : freshest.audioURL
        survivor.episodeDescription = freshest.episodeDescription ?? group.compactMap(\.episodeDescription).last
        survivor.durationSeconds = freshest.durationSeconds ?? group.compactMap(\.durationSeconds).last
        survivor.pubDate = group.compactMap(\.pubDate).max()
        survivor.artworkURL = freshest.artworkURL ?? group.compactMap(\.artworkURL).last
        survivor.episodeNumber = freshest.episodeNumber ?? group.compactMap(\.episodeNumber).last
        survivor.seasonNumber = freshest.seasonNumber ?? group.compactMap(\.seasonNumber).last
        survivor.chapterURL = freshest.chapterURL ?? group.compactMap(\.chapterURL).last
        survivor.transcriptURL = freshest.transcriptURL ?? group.compactMap(\.transcriptURL).last
        survivor.positionSeconds = group.map(\.positionSeconds).max() ?? survivor.positionSeconds
        survivor.playedAt = group.compactMap(\.playedAt).max()
        survivor.inboxDismissed = group.contains(where: \.inboxDismissed)
        survivor.createdAt = group.map(\.createdAt).min() ?? survivor.createdAt

        if let download = group
            .filter({ ($0.downloadPath?.isEmpty == false) })
            .max(by: episodeFreshnessOrder) {
            survivor.downloadPath = download.downloadPath
            survivor.downloadStatus = .downloaded
        } else {
            let state = group.max {
                let left = downloadRank($0.downloadStatus)
                let right = downloadRank($1.downloadStatus)
                return left == right ? episodeFreshnessOrder($0, $1) : left < right
            }
            survivor.downloadPath = nil
            survivor.downloadStatus = state?.downloadStatus ?? .none
        }

        if group.contains(where: { $0.status == .played }) {
            survivor.status = .played
        } else {
            survivor.status = freshest.status
        }
    }
}

private func stableID<T: PersistentModel>(_ model: T) -> String {
    String(describing: model.persistentModelID)
}

private func podcastOrder(_ lhs: Podcast, _ rhs: Podcast) -> Bool {
    if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
    return stableID(lhs) < stableID(rhs)
}

private func episodeOrder(_ lhs: Episode, _ rhs: Episode) -> Bool {
    if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
    return stableID(lhs) < stableID(rhs)
}

private func episodeFreshnessOrder(_ lhs: Episode, _ rhs: Episode) -> Bool {
    let leftDate = lhs.pubDate ?? lhs.createdAt
    let rightDate = rhs.pubDate ?? rhs.createdAt
    if leftDate != rightDate { return leftDate < rightDate }
    return episodeOrder(lhs, rhs)
}

private func queueItemOrder(_ lhs: QueueItem, _ rhs: QueueItem) -> Bool {
    if lhs.position != rhs.position { return lhs.position < rhs.position }
    if lhs.addedAt != rhs.addedAt { return lhs.addedAt > rhs.addedAt }
    return stableID(lhs) < stableID(rhs)
}

private func downloadRank(_ status: DownloadStatus) -> Int {
    switch status {
    case .downloaded: 5
    case .downloading: 4
    case .pending: 3
    case .failed: 2
    case .none: 1
    }
}
