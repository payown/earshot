import Foundation
import SwiftData

enum ActiveDownloadState: String, CaseIterable {
    case pending
    case downloading

    init?(_ status: DownloadStatus) {
        switch status {
        case .pending: self = .pending
        case .downloading: self = .downloading
        case .none, .downloaded, .failed: return nil
        }
    }
}

struct EpisodeLocalKey: Hashable, Sendable {
    let feedURL: String
    let guid: String

    init(feedURL: String, guid: String) {
        self.feedURL = FeedURLIdentity.canonical(feedURL)
        self.guid = guid
    }
}

/// Scalar-keyed access to per-device state. Local rows never relate to mirrored
/// models, so a future CloudKit configuration cannot upload paths or transfers.
enum LocalStateStore {
    static func key(for episode: Episode) -> EpisodeLocalKey? {
        guard let feedURL = episode.podcast?.feedURL else { return nil }
        return EpisodeLocalKey(feedURL: feedURL, guid: episode.guid)
    }

    static func episodeRows(for key: EpisodeLocalKey, in context: ModelContext) -> [LocalEpisodeState] {
        (try? episodeRowsThrowing(for: key, in: context)) ?? []
    }

    static func episodeRowsThrowing(
        for key: EpisodeLocalKey, in context: ModelContext
    ) throws -> [LocalEpisodeState] {
        let guid = key.guid
        return try context.fetch(
            FetchDescriptor<LocalEpisodeState>(predicate: #Predicate { $0.episodeGUID == guid })
        ).filter { FeedURLIdentity.canonical($0.podcastFeedURL) == key.feedURL }
    }

    static func episode(matching key: EpisodeLocalKey, in context: ModelContext) -> Episode? {
        try? episodes(matching: [key], in: context)[key]
    }

    /// Resolves a bounded local-state result set with one mirrored-store query,
    /// then applies the composite natural key in memory. This is the list-screen
    /// path; it must not issue one SwiftData fetch per download row.
    static func episodes(
        matching keys: [EpisodeLocalKey], in context: ModelContext
    ) throws -> [EpisodeLocalKey: Episode] {
        guard !keys.isEmpty else { return [:] }
        let requested = Set(keys)
        let guids = Array(Set(keys.map(\.guid)))
        let candidates = try context.fetch(
            FetchDescriptor<Episode>(predicate: #Predicate { guids.contains($0.guid) })
        ).sorted { stableLocalID($0) < stableLocalID($1) }
        var result: [EpisodeLocalKey: Episode] = [:]
        for episode in candidates {
            guard let key = key(for: episode), requested.contains(key), result[key] == nil else {
                continue
            }
            result[key] = episode
        }
        return result
    }

    static func setDownloadStatus(
        _ status: DownloadStatus, on episode: Episode, in context: ModelContext
    ) {
        episode.downloadStatus = status
        persist(episode, in: context)
    }

    static func setDownloadPath(
        _ path: String?, on episode: Episode, in context: ModelContext
    ) {
        episode.downloadPath = path
        persist(episode, in: context)
    }

    static func persist(_ episode: Episode, in context: ModelContext) {
        guard let key = key(for: episode) else { return }
        let rows = episodeRows(for: key, in: context)
        if episode.downloadStatus == .none && episode.downloadPath == nil
            && rows.allSatisfy({ $0.volumeBoost == nil }) {
            LocalRuntimeState.shared.removeEpisode(episode.persistentModelID)
            for row in rows { context.delete(row) }
            return
        }
        let row = rows.first ?? LocalEpisodeState(
            podcastFeedURL: key.feedURL,
            episodeGUID: key.guid
        )
        if rows.isEmpty { context.insert(row) }
        row.podcastFeedURL = key.feedURL
        row.episodeGUID = key.guid
        row.downloadStatus = episode.downloadStatus
        row.downloadPath = episode.downloadPath
        for duplicate in rows.dropFirst() { context.delete(duplicate) }
    }

    static func setRefreshedAt(_ date: Date?, on podcast: Podcast, in context: ModelContext) {
        podcast.refreshedAt = date
        let feed = FeedURLIdentity.canonical(podcast.feedURL)
        let rows = ((try? context.fetch(
            FetchDescriptor<LocalPodcastState>(predicate: #Predicate { $0.feedURL == feed })
        )) ?? []).sorted { stableLocalID($0) < stableLocalID($1) }
        if date == nil {
            for row in rows { context.delete(row) }
            return
        }
        let row = rows.first ?? LocalPodcastState(feedURL: feed)
        if rows.isEmpty { context.insert(row) }
        row.feedURL = feed
        row.refreshedAt = date
        for duplicate in rows.dropFirst() { context.delete(duplicate) }
    }

    /// Collapses scalar-key duplicates deterministically before hydration. These
    /// tables are intentionally bounded by device-local activity, and no repair
    /// fetch touches the full Episode table.
    static func repair(in context: ModelContext) throws {
        let podcastGroups = Dictionary(
            grouping: try context.fetch(FetchDescriptor<LocalPodcastState>())
        ) { FeedURLIdentity.canonical($0.feedURL) }
        for (feed, group) in podcastGroups {
            let ordered = group.sorted { stableLocalID($0) < stableLocalID($1) }
            guard let survivor = ordered.first else { continue }
            survivor.feedURL = feed
            survivor.refreshedAt = group.compactMap(\.refreshedAt).max()
            for duplicate in ordered.dropFirst() { context.delete(duplicate) }
        }

        let episodeGroups = Dictionary(
            grouping: try context.fetch(FetchDescriptor<LocalEpisodeState>())
        ) { EpisodeLocalKey(feedURL: $0.podcastFeedURL, guid: $0.episodeGUID) }
        for (key, group) in episodeGroups {
            let ordered = group.sorted { stableLocalID($0) < stableLocalID($1) }
            guard let survivor = ordered.first else { continue }
            let downloaded = DownloadPaths.preferredExistingDownload(
                from: group.filter { $0.downloadStatus == .downloaded },
                storedValue: \LocalEpisodeState.downloadPath,
                stableID: stableLocalID
            )
            let preferred = ordered.filter { $0.downloadStatus != .downloaded }.max {
                let left = localDownloadRank($0.downloadStatus)
                let right = localDownloadRank($1.downloadStatus)
                return left == right
                    ? stableLocalID($0) > stableLocalID($1)
                    : left < right
            }
            survivor.podcastFeedURL = key.feedURL
            survivor.episodeGUID = key.guid
            survivor.downloadStatus = downloaded == nil
                ? (preferred?.downloadStatus ?? .none)
                : .downloaded
            survivor.downloadPath = downloaded?.downloadPath
            survivor.volumeBoostRaw = ordered.compactMap(\.volumeBoostRaw).first
            for duplicate in ordered.dropFirst() { context.delete(duplicate) }
        }

        let settingGroups = Dictionary(
            grouping: try context.fetch(FetchDescriptor<LocalAppSetting>()), by: \.key
        )
        for group in settingGroups.values {
            let ordered = group.sorted { stableLocalID($0) < stableLocalID($1) }
            for duplicate in ordered.dropFirst() { context.delete(duplicate) }
        }
    }

    /// Projects only rows represented in the small local tables into transient
    /// runtime state. Migration completion also repairs those bounded tables;
    /// an ordinary current-schema reopen trusts their durable invariants and does no repair.
    static func hydrate(in context: ModelContext, repairing: Bool = true) throws {
        LocalRuntimeState.shared.clear()
        if repairing { try repair(in: context) }

        for row in try context.fetch(FetchDescriptor<LocalPodcastState>()) {
            LocalRuntimeState.shared.setRefreshedAt(
                row.refreshedAt, feedURL: row.feedURL
            )
        }

        let rows = try context.fetch(FetchDescriptor<LocalEpisodeState>())
        let keys = rows.map { EpisodeLocalKey(feedURL: $0.podcastFeedURL, guid: $0.episodeGUID) }
        let matches = try episodes(matching: keys, in: context)
        for (row, key) in zip(rows, keys) {
            guard let episode = matches[key] else { continue }
            episode.downloadStatus = row.downloadStatus
            episode.downloadPath = row.downloadPath
        }
    }

    static func removeRows(forEpisodesOf podcast: Podcast, in context: ModelContext) {
        let feed = FeedURLIdentity.canonical(podcast.feedURL)
        for row in (try? context.fetch(FetchDescriptor<LocalEpisodeState>())) ?? []
        where FeedURLIdentity.canonical(row.podcastFeedURL) == feed {
            context.delete(row)
        }
        for row in (try? context.fetch(FetchDescriptor<LocalPodcastState>())) ?? []
        where FeedURLIdentity.canonical(row.feedURL) == feed {
            context.delete(row)
        }
    }


    static func volumeBoost(for episode: Episode, in context: ModelContext) -> VolumeBoostLevel? {
        guard let key = key(for: episode) else { return nil }
        return episodeRows(for: key, in: context)
            .sorted { stableLocalID($0) < stableLocalID($1) }
            .compactMap(\.volumeBoost)
            .first
    }

    static func setVolumeBoost(
        _ boost: VolumeBoostLevel?, on episode: Episode, in context: ModelContext
    ) {
        guard let key = key(for: episode) else { return }
        let rows = episodeRows(for: key, in: context)
            .sorted { stableLocalID($0) < stableLocalID($1) }
        if boost == nil,
           rows.allSatisfy({ $0.downloadStatus == .none && $0.downloadPath == nil }) {
            for row in rows { context.delete(row) }
            try? context.save()
            return
        }
        let row = rows.first ?? LocalEpisodeState(
            podcastFeedURL: key.feedURL,
            episodeGUID: key.guid
        )
        if rows.isEmpty { context.insert(row) }
        row.podcastFeedURL = key.feedURL
        row.episodeGUID = key.guid
        row.volumeBoost = boost
        for duplicate in rows.dropFirst() { context.delete(duplicate) }
        try? context.save()
    }
}

/// Compatibility name retained for existing download call sites. V8 contains no
/// `ActiveDownload` model; active work is queried from `LocalEpisodeState`.
enum ActiveDownload {
    static func setDownloadStatus(
        _ status: DownloadStatus, on episode: Episode, in context: ModelContext
    ) {
        LocalStateStore.setDownloadStatus(status, on: episode, in: context)
    }

    static func rows(for episode: Episode, in context: ModelContext) -> [LocalEpisodeState] {
        guard let key = LocalStateStore.key(for: episode) else { return [] }
        return LocalStateStore.episodeRows(for: key, in: context)
    }

    static func removeRows(forEpisodesOf podcast: Podcast, in context: ModelContext) {
        LocalStateStore.removeRows(forEpisodesOf: podcast, in: context)
    }
}

private func stableLocalID<T: PersistentModel>(_ model: T) -> String {
    String(describing: model.persistentModelID)
}

private func localDownloadRank(_ status: DownloadStatus) -> Int {
    switch status {
    case .none: 0
    case .failed: 1
    case .pending: 2
    case .downloading: 3
    case .downloaded: 4
    }
}
