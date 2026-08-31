import Foundation
import SwiftData

struct QueueLineupIdentity: Codable, Equatable, Hashable, Sendable {
    let feedURL: String
    let episodeGUID: String
}

/// Keeps catalog lineup identities device-local while the existing followed
/// portion continues to sync. The same codec/filter/merge rules are used by the
/// lineup store and Cloud projection so neither side can drift semantically.
enum QueueLineupIdentityPolicy {
    static func identities(from rawValue: String) -> [QueueLineupIdentity]? {
        if rawValue.isEmpty { return [] }
        guard let data = rawValue.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([QueueLineupIdentity].self, from: data)
        else { return nil }
        return deduplicated(decoded)
    }

    static func encoded(_ identities: [QueueLineupIdentity]) -> String {
        let data = (try? JSONEncoder().encode(deduplicated(identities))) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// Cloud receives only identities owned by followed podcasts. Invalid local
    /// data fails closed rather than leaking an unclassified feed identity.
    static func outboundValue(
        _ rawValue: String,
        followedFeeds: Set<String>
    ) -> String? {
        guard let identities = identities(from: rawValue) else { return nil }
        return encoded(identities.filter {
            followedFeeds.contains(FeedURLIdentity.canonical($0.feedURL))
        })
    }

    /// Remote state replaces only the followed slots. Local catalog identities
    /// retain their relative order and approximate position, so applying a
    /// followed-only projection can never erase richer device-local content.
    static func mergingRemoteValue(
        _ remoteValue: String,
        into localValue: String,
        followedFeeds: Set<String>
    ) -> String {
        guard let remote = identities(from: remoteValue),
              let local = identities(from: localValue) else { return localValue }
        let followedRemote = remote.filter {
            followedFeeds.contains(FeedURLIdentity.canonical($0.feedURL))
        }
        var remoteIndex = 0
        var merged: [QueueLineupIdentity] = []
        for localIdentity in local {
            let feed = FeedURLIdentity.canonical(localIdentity.feedURL)
            if !followedFeeds.contains(feed) {
                merged.append(localIdentity)
            } else if remoteIndex < followedRemote.count {
                merged.append(followedRemote[remoteIndex])
                remoteIndex += 1
            }
        }
        merged.append(contentsOf: followedRemote.dropFirst(remoteIndex))
        return encoded(merged)
    }

    private static func deduplicated(
        _ identities: [QueueLineupIdentity]
    ) -> [QueueLineupIdentity] {
        var seen = Set<QueueLineupIdentity>()
        return identities.compactMap {
            let canonical = QueueLineupIdentity(
                feedURL: FeedURLIdentity.canonical($0.feedURL),
                episodeGUID: $0.episodeGUID
            )
            return seen.insert(canonical).inserted ? canonical : nil
        }
    }
}

struct QueueLineupSaveReport: Equatable {
    let savedCount: Int
    let omittedCount: Int

    var announcement: String {
        if omittedCount == 0 {
            return "Saved lineup with \(savedCount) \(savedCount == 1 ? "episode" : "episodes")"
        }
        return "Saved the first \(savedCount) episodes. \(omittedCount) additional \(omittedCount == 1 ? "episode was" : "episodes were") omitted"
    }
}

struct QueueLineupApplyReport: Equatable {
    let appliedCount: Int
    let skippedCount: Int

    var announcement: String {
        let applied = "Applied \(appliedCount) \(appliedCount == 1 ? "episode" : "episodes")"
        guard skippedCount > 0 else { return applied }
        return "\(applied). Skipped \(skippedCount) unavailable or played \(skippedCount == 1 ? "episode" : "episodes")"
    }
}

/// Stores an on-demand Queue template without adding a schema entity. Stable
/// feed + GUID identities survive store rebuilds and private-iCloud projection.
@MainActor
final class QueueLineupStore {
    nonisolated static let maximumEpisodeCount = 100

    private let context: ModelContext
    private let settings: AppSettingsStore

    init(context: ModelContext) {
        self.context = context
        settings = AppSettingsStore(context: context)
    }

    var savedCount: Int { identities().count }
    var hasSavedLineup: Bool { savedCount > 0 }

    @discardableResult
    func save(_ episodes: [Episode]) -> QueueLineupSaveReport {
        var identities: [QueueLineupIdentity] = []
        for episode in episodes.prefix(Self.maximumEpisodeCount) {
            guard let feedURL = episode.podcast?.feedURL,
                  !feedURL.isEmpty,
                  !episode.guid.isEmpty else { continue }
            identities.append(QueueLineupIdentity(feedURL: feedURL, episodeGUID: episode.guid))
        }
        let encoded = QueueLineupIdentityPolicy.encoded(identities)
        let savedCount = QueueLineupIdentityPolicy.identities(from: encoded)?.count ?? 0
        settings.setRawValue(encoded, for: SettingsKey.morningLineup)
        return QueueLineupSaveReport(
            savedCount: savedCount,
            omittedCount: max(0, episodes.count - savedCount)
        )
    }

    func clear() {
        settings.setRawValue("", for: SettingsKey.morningLineup)
    }

    @discardableResult
    func apply(to queue: QueueRepository) -> QueueLineupApplyReport {
        let saved = identities()
        var resolved: [Episode] = []
        var skipped = 0

        for identity in saved {
            let feedURL = identity.feedURL
            let guid = identity.episodeGUID
            var descriptor = FetchDescriptor<Episode>(
                predicate: #Predicate {
                    $0.guid == guid && $0.podcast?.feedURL == feedURL
                }
            )
            descriptor.fetchLimit = 1
            guard let episode = (try? context.fetch(descriptor))?.first, !episode.isPlayed else {
                skipped += 1
                continue
            }
            resolved.append(episode)
        }

        queue.bringToFront(resolved)
        return QueueLineupApplyReport(appliedCount: resolved.count, skippedCount: skipped)
    }

    private func identities() -> [QueueLineupIdentity] {
        guard let raw = settings.rawValue(SettingsKey.morningLineup),
              !raw.isEmpty,
              let decoded = QueueLineupIdentityPolicy.identities(from: raw)
        else { return [] }
        return Array(decoded.prefix(Self.maximumEpisodeCount))
    }
}
