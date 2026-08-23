import Foundation

struct CompactProjectionSeedMarkerRecord: Codable, Equatable {
    enum Kind: String, Codable {
        case start
        case complete
        case failure
    }

    let recordedAt: Date
    let kind: Kind
    let runID: String
    let durationSeconds: Double?
    let counts: CompactProjectionSeedCounts?
    let error: String?

    init(marker: CompactProjectionSeedMarker, recordedAt: Date) {
        self.recordedAt = recordedAt
        switch marker {
        case .start(let runID):
            kind = .start
            self.runID = runID
            durationSeconds = nil
            counts = nil
            error = nil
        case .complete(let runID, let durationSeconds, let counts):
            kind = .complete
            self.runID = runID
            self.durationSeconds = durationSeconds
            self.counts = counts
            error = nil
        case .failure(let runID, let durationSeconds, let error):
            kind = .failure
            self.runID = runID
            self.durationSeconds = durationSeconds
            counts = nil
            self.error = error
        }
    }
}

/// A small, bounded diagnostic journal for projection seed timing. Unified-log
/// retention is not reliable enough for collection after a physical-device run.
/// The journal contains only run metadata and aggregate entity counts.
struct CompactProjectionSeedMarkerStore {
    static let defaultURL = URL.applicationSupportDirectory
        .appending(path: "compact-projection-seed-markers.json")
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

    func record(_ marker: CompactProjectionSeedMarker, at date: Date = Date()) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var records = (try? load()) ?? []
        records.append(CompactProjectionSeedMarkerRecord(marker: marker, recordedAt: date))
        if records.count > recordLimit {
            records.removeFirst(records.count - recordLimit)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(records).write(to: url, options: .atomic)
    }

    func load() throws -> [CompactProjectionSeedMarkerRecord] {
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode(
            [CompactProjectionSeedMarkerRecord].self,
            from: Data(contentsOf: url)
        )
    }
}
