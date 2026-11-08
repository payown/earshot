import Foundation

enum PairedQueueTransportError: Error { case invalidContribution, unreadableCache }

/// Build 311 and 312 were killed by iOS code-signing validation when their
/// immediate paired queue snapshot path ran on physical hardware. Keep the
/// durable CloudKit queue projection active while this transport is isolated.
enum PairedQueueTransportPolicy {
    static let immediateSnapshotsEnabled = false
    static let unavailableStatus = "Immediate paired Queue refresh is unavailable. Queue changes sync through iCloud when available."
}

/// The existing compact CloudKit queue contribution, encoded for a prompt
/// paired-device exchange. Each device still writes only its own contribution.
struct PairedQueueContribution: Codable, Sendable, Equatable {
    let feedURL: String
    let guid: String
    let sourceDeviceID: String
    let isQueued: Bool
    let position: Int
    let membershipUpdatedAt: Date
    let modifiedAt: Date
    let deletedAt: Date?
    let title: String?
    let podcastTitle: String?
    let audioURL: String?
    let summary: String?
    let durationSeconds: Int?
    let pubDate: Date?
    let artworkURL: String?
    let episodeNumber: Int?
    let seasonNumber: Int?
    let chapterURL: String?
    let transcriptURL: String?

    init(_ row: CloudQueueItemProjection, podcastTitle: String? = nil) {
        feedURL = FeedURLIdentity.canonical(row.feedURL)
        guid = row.episodeGUID
        sourceDeviceID = row.sourceDeviceID
        isQueued = row.isQueued
        position = row.position
        membershipUpdatedAt = row.membershipUpdatedAt
        modifiedAt = row.modifiedAt
        deletedAt = row.deletedAt
        title = row.episodeTitle
        self.podcastTitle = podcastTitle
        audioURL = row.episodeAudioURL
        // Full notes remain in the CloudKit projection. The paired transport
        // needs only enough text to render a useful queue shell promptly.
        summary = row.episodeDescription.map { String($0.prefix(2_000)) }
        durationSeconds = row.episodeDurationSeconds
        pubDate = row.episodePubDate
        artworkURL = row.episodeArtworkURL
        episodeNumber = row.episodeNumber
        seasonNumber = row.episodeSeasonNumber
        chapterURL = row.episodeChapterURL
        transcriptURL = row.episodeTranscriptURL
    }

    var key: String { feedURL + "\u{001f}" + guid + "\u{001f}" + sourceDeviceID }
    var isValid: Bool {
        guard !feedURL.isEmpty, !guid.isEmpty, !sourceDeviceID.isEmpty,
              feedURL.count <= 4_096, guid.count <= 2_048,
              sourceDeviceID.count <= 128, (0...100_000).contains(position) else { return false }
        guard (title?.count ?? 0) <= 4_096,
              (audioURL?.count ?? 0) <= 8_192,
              (podcastTitle?.count ?? 0) <= 4_096,
              (summary?.count ?? 0) <= 2_000,
              (artworkURL?.count ?? 0) <= 8_192,
              (chapterURL?.count ?? 0) <= 8_192,
              (transcriptURL?.count ?? 0) <= 8_192 else { return false }
        let latestAllowedUpdate = Date.now.addingTimeInterval(300)
        return modifiedAt <= latestAllowedUpdate && membershipUpdatedAt <= latestAllowedUpdate
    }

    /// Merge clocks independently. A delayed order update cannot revive a
    /// newer removal, and a delayed membership update cannot rewind order.
    @discardableResult
    func merge(into row: CloudQueueItemProjection) -> Bool {
        guard isValid else { return false }
        let priorMembership = row.membershipUpdatedAt == .distantPast
            ? row.modifiedAt : row.membershipUpdatedAt
        let incomingMembership = membershipUpdatedAt == .distantPast
            ? modifiedAt : membershipUpdatedAt
        let membershipChanged = row.sourceDeviceID.isEmpty || incomingMembership > priorMembership
        let orderChanged = row.sourceDeviceID.isEmpty || modifiedAt > row.modifiedAt
        if membershipChanged {
            row.isQueued = isQueued
            row.membershipUpdatedAt = incomingMembership
        }
        if orderChanged {
            row.position = position
            row.modifiedAt = modifiedAt
            row.episodeTitle = title ?? row.episodeTitle
            row.episodeAudioURL = audioURL ?? row.episodeAudioURL
            row.episodeDescription = summary ?? row.episodeDescription
            row.episodeDurationSeconds = durationSeconds ?? row.episodeDurationSeconds
            row.episodePubDate = pubDate ?? row.episodePubDate
            row.episodeArtworkURL = artworkURL ?? row.episodeArtworkURL
            row.episodeNumber = episodeNumber ?? row.episodeNumber
            row.episodeSeasonNumber = seasonNumber ?? row.episodeSeasonNumber
            row.episodeChapterURL = chapterURL ?? row.episodeChapterURL
            row.episodeTranscriptURL = transcriptURL ?? row.episodeTranscriptURL
        } else {
            // An older contribution can still supply metadata that a legacy
            // row lacks, without changing its newer queue decision or order.
            if row.episodeTitle == nil { row.episodeTitle = title }
            if row.episodeAudioURL == nil { row.episodeAudioURL = audioURL }
        }
        if let deletedAt, deletedAt > (row.deletedAt ?? .distantPast),
           deletedAt >= max(incomingMembership, modifiedAt) {
            row.deletedAt = deletedAt
        } else if membershipChanged || orderChanged {
            row.deletedAt = nil
        }
        return membershipChanged || orderChanged
    }

    func unmanagedRow() -> CloudQueueItemProjection {
        let row = CloudQueueItemProjection()
        merge(into: row)
        row.feedURL = feedURL
        row.episodeGUID = guid
        row.sourceDeviceID = sourceDeviceID
        return row
    }
}

/// A local-only cache of already versioned queue contributions received over
/// Watch Connectivity. No peer-created SwiftData row enters the CloudKit store.
/// The cache survives a relaunch until the original CloudKit record arrives.
struct PairedQueueOverlay {
    private struct Archive: Codable { let version: Int; let rows: [PairedQueueContribution] }
    private let url: URL?
    private var byKey: [String: PairedQueueContribution] = [:]
    private let unreadable: Bool

    init(url: URL?, loadCachedRows: Bool = true) {
        self.url = url
        // Keep the on-disk cache untouched for a later repaired transport.
        // CloudKit's owned rows continue to drive the visible queue meanwhile.
        guard loadCachedRows else {
            unreadable = false
            return
        }
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            unreadable = false
            return
        }
        guard let data = try? Data(contentsOf: url), data.count <= 20_000_000,
              let archive = try? JSONDecoder().decode(Archive.self, from: data),
              archive.version == PairedQueuePage.version,
              archive.rows.count <= 10_000, archive.rows.allSatisfy(\.isValid) else {
            unreadable = true
            return
        }
        byKey = Dictionary(archive.rows.map { ($0.key, $0) },
                           uniquingKeysWith: { first, _ in first })
        unreadable = false
    }

    var rows: [PairedQueueContribution] { byKey.values.sorted { $0.key < $1.key } }

    mutating func accept(_ incoming: [PairedQueueContribution], excluding ownDeviceID: String) throws {
        guard !unreadable else { throw PairedQueueTransportError.unreadableCache }
        guard incoming.count <= 10_000, incoming.allSatisfy(\.isValid) else {
            throw PairedQueueTransportError.invalidContribution
        }
        var mergedByKey = byKey
        for contribution in incoming where contribution.sourceDeviceID != ownDeviceID {
            if let previous = mergedByKey[contribution.key] {
                let row = previous.unmanagedRow()
                contribution.merge(into: row)
                mergedByKey[contribution.key] = PairedQueueContribution(
                    row, podcastTitle: contribution.podcastTitle ?? previous.podcastTitle
                )
            } else {
                mergedByKey[contribution.key] = contribution
            }
        }
        guard mergedByKey.count <= 10_000 else { throw PairedQueueTransportError.invalidContribution }
        if let url {
            let archive = Archive(version: PairedQueuePage.version,
                                  rows: mergedByKey.values.sorted { $0.key < $1.key })
            let data = try JSONEncoder().encode(archive)
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
        byKey = mergedByKey
    }

    func mergedRows(with cloudRows: [CloudQueueItemProjection]) -> [CloudQueueItemProjection] {
        var result: [String: CloudQueueItemProjection] = [:]
        for row in cloudRows {
            let key = PairedQueueContribution(row).key
            if let previous = result[key] {
                if row.modifiedAt > previous.modifiedAt
                    || (row.modifiedAt == previous.modifiedAt
                        && row.membershipUpdatedAt > previous.membershipUpdatedAt) {
                    result[key] = row
                }
            } else {
                result[key] = row
            }
        }
        for contribution in byKey.values {
            if let cloud = result[contribution.key] {
                // Never mutate the managed CloudKit row while examining a
                // faster paired update. Only the local application sees this.
                let merged = PairedQueueContribution(cloud).unmanagedRow()
                contribution.merge(into: merged)
                result[contribution.key] = merged
            } else {
                result[contribution.key] = contribution.unmanagedRow()
            }
        }
        return Array(result.values)
    }
}

struct PairedQueuePage: Codable, Sendable {
    static let version = 1
    static let maximumPageSize = 20
    let version: Int
    let offset: Int
    let total: Int
    let rows: [PairedQueueContribution]

    init(rows: [PairedQueueContribution], offset: Int) {
        version = Self.version
        self.offset = offset
        total = rows.count
        var selected: [PairedQueueContribution] = []
        for row in rows.dropFirst(offset).prefix(Self.maximumPageSize) {
            let candidate = selected + [row]
            if !selected.isEmpty,
               ((try? JSONEncoder().encode(candidate).count) ?? Int.max) > 48_000 { break }
            selected.append(row)
        }
        self.rows = selected
    }

    var nextOffset: Int? { offset + rows.count < total ? offset + rows.count : nil }
    var isValid: Bool {
        version == Self.version && offset >= 0 && total >= 0 && total <= 10_000 &&
        rows.count <= Self.maximumPageSize && rows.allSatisfy(\.isValid) &&
        ((try? JSONEncoder().encode(self).count) ?? .max) <= 65_000
    }
}
