import Foundation
import SwiftData

struct MediaTransportSnapshot: Codable, Equatable, Sendable {
    enum Trigger: String, Codable, Sendable {
        case fullRefresh = "full-refresh"
        case bulkImport = "bulk-import"
    }

    let recordedAt: Date
    let trigger: Trigger
    let totalEpisodes: Int
    let cleartextHTTPEpisodes: Int
    let secureHTTPSEpisodes: Int

    var otherEpisodes: Int {
        max(0, totalEpisodes - cleartextHTTPEpisodes - secureHTTPSEpisodes)
    }
}

/// Bounded, telemetry-free evidence for removing the ATS media exception.
/// Records aggregate scheme counts only: never a URL, host, podcast, or episode.
struct MediaTransportDiagnosticStore {
    static let defaultURL = URL.applicationSupportDirectory
        .appending(path: "media-transport-diagnostics.json")
    static let defaultRecordLimit = 40

    let url: URL
    let recordLimit: Int
    private let fileManager: FileManager

    init(
        url: URL = Self.defaultURL,
        recordLimit: Int = Self.defaultRecordLimit,
        fileManager: FileManager = .default
    ) {
        self.url = url
        self.recordLimit = max(1, recordLimit)
        self.fileManager = fileManager
    }

    func record(_ snapshot: MediaTransportSnapshot) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var snapshots = (try? load()) ?? []
        snapshots.append(snapshot)
        if snapshots.count > recordLimit {
            snapshots.removeFirst(snapshots.count - recordLimit)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(snapshots).write(to: url, options: .atomic)
    }

    func load() throws -> [MediaTransportSnapshot] {
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode(
            [MediaTransportSnapshot].self,
            from: Data(contentsOf: url)
        )
    }
}

@MainActor
enum MediaTransportDiagnostics {
    static func capture(
        in context: ModelContext,
        trigger: MediaTransportSnapshot.Trigger,
        at date: Date = Date(),
        store: MediaTransportDiagnosticStore = MediaTransportDiagnosticStore()
    ) throws -> MediaTransportSnapshot {
        let cleartext = FetchDescriptor<Episode>(
            predicate: #Predicate { $0.audioURL.starts(with: "http://") }
        )
        let secure = FetchDescriptor<Episode>(
            predicate: #Predicate { $0.audioURL.starts(with: "https://") }
        )
        let snapshot = try MediaTransportSnapshot(
            recordedAt: date,
            trigger: trigger,
            totalEpisodes: context.fetchCount(FetchDescriptor<Episode>()),
            cleartextHTTPEpisodes: context.fetchCount(cleartext),
            secureHTTPSEpisodes: context.fetchCount(secure)
        )
        try store.record(snapshot)
        AppLog.networking.notice(
            "Media transport sample trigger=\(trigger.rawValue, privacy: .public) totalEpisodes=\(snapshot.totalEpisodes) cleartextHTTPEpisodes=\(snapshot.cleartextHTTPEpisodes) secureHTTPSEpisodes=\(snapshot.secureHTTPSEpisodes) otherEpisodes=\(snapshot.otherEpisodes) (#709)"
        )
        return snapshot
    }
}
