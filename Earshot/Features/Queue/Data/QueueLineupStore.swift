import Foundation
import SwiftData

struct QueueLineupIdentity: Codable, Equatable, Sendable {
    let feedURL: String
    let episodeGUID: String
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
        let encoded = (try? JSONEncoder().encode(identities)).flatMap {
            String(data: $0, encoding: .utf8)
        } ?? "[]"
        settings.setRawValue(encoded, for: SettingsKey.morningLineup)
        return QueueLineupSaveReport(
            savedCount: identities.count,
            omittedCount: max(0, episodes.count - identities.count)
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
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([QueueLineupIdentity].self, from: data)
        else { return [] }
        return Array(decoded.prefix(Self.maximumEpisodeCount))
    }
}
