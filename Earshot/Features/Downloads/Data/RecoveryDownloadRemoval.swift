import Foundation
import SwiftData

enum RecoveryDownloadDeletionOutcome: Equatable, Sendable {
    case complete
    case partial
    case none
}

struct RecoveryStorageState: Equatable, Sendable {
    let requiredBytes: Int64
    var availableBytes: Int64
    var downloadBytes: Int64?
    var freedBytes: Int64?
    var deletionOutcome: RecoveryDownloadDeletionOutcome?

    var remainingBytes: Int64 { max(0, requiredBytes - availableBytes) }
    var hasEnoughSpace: Bool { remainingBytes == 0 }
}

struct RecoveryDownloadRemovalResult: Equatable, Sendable {
    let freedBytes: Int64
    let availableBytes: Int64
    let remainingDownloadBytes: Int64
    let failedItemCount: Int

    var outcome: RecoveryDownloadDeletionOutcome {
        if freedBytes == 0 { return .none }
        return failedItemCount == 0 && remainingDownloadBytes == 0 ? .complete : .partial
    }
}

/// Filesystem transaction used when the SwiftData store is unavailable. The
/// marker is the durable intent: background callbacks and later launches must
/// honor it until the final store reconciliation has saved successfully.
enum RecoveryDownloadRemoval {
    enum InjectedFailurePoint: Equatable {
        case afterMarkerCreation
        case afterFileDeletion
        case afterStoreSave
        case beforeMarkerRemoval
    }

    struct InjectedFailure: Error, Equatable {
        let point: InjectedFailurePoint
    }

    #if DEBUG
    nonisolated(unsafe) static var injectedFailurePoint: InjectedFailurePoint?
    #endif

    private struct Marker: Codable {
        let version: Int
        let createdAt: Date
    }

    static let markerURL = URL.applicationSupportDirectory
        .appending(path: "download-removal-pending.json")

    static var isPending: Bool { isPending(at: markerURL) }

    static func isPending(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    static func begin(at url: URL = markerURL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(Marker(version: 1, createdAt: .now))
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try failIfInjected(at: .afterMarkerCreation)
    }

    static func finish(at url: URL = markerURL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    static func allocatedBytes(in directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [
                .isRegularFileKey, .totalFileAllocatedSizeKey,
                .fileAllocatedSizeKey, .fileSizeKey,
            ],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey, .totalFileAllocatedSizeKey,
                .fileAllocatedSizeKey, .fileSizeKey,
            ]), values.isRegularFile == true else { continue }
            total += Int64(
                values.totalFileAllocatedSize
                    ?? values.fileAllocatedSize
                    ?? values.fileSize
                    ?? 0
            )
        }
        return total
    }

    static func removeContents(
        of directory: URL,
        removeItem: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) -> (freedBytes: Int64, remainingBytes: Int64, failedItemCount: Int) {
        let before = allocatedBytes(in: directory)
        let children = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var failures = 0
        for child in children {
            do {
                try removeItem(child)
            } catch {
                if FileManager.default.fileExists(atPath: child.path) { failures += 1 }
            }
        }
        let after = allocatedBytes(in: directory)
        return (max(0, before - after), after, failures)
    }

    /// Idempotently aligns the bounded local-state table with the files that
    /// survived deletion. The marker is removed only after the store save and
    /// terminal-event journal acknowledgement both succeed.
    @MainActor
    static func reconcileStoreIfNeeded(
        container: ModelContainer,
        markerURL: URL = markerURL,
        journal: DownloadEventJournal = .shared
    ) throws {
        guard isPending(at: markerURL) else { return }
        let context = container.mainContext
        for row in try context.fetch(FetchDescriptor<LocalEpisodeState>()) {
            if let name = DownloadPaths.storedFileName(row.downloadPath),
               let url = DownloadPaths.resolveLocalURL(storedValue: name),
               FileManager.default.fileExists(atPath: url.path) {
                row.downloadPath = name
                row.downloadStatus = .downloaded
            } else {
                context.delete(row)
            }
        }
        try context.save()
        try failIfInjected(at: .afterStoreSave)
        try journal.acknowledgeAllForRecovery()
        try LocalStateStore.hydrate(in: context, repairing: false)
        try failIfInjected(at: .beforeMarkerRemoval)
        try finish(at: markerURL)
    }

    static func failIfInjected(at point: InjectedFailurePoint) throws {
        #if DEBUG
        if injectedFailurePoint == point { throw InjectedFailure(point: point) }
        #endif
    }
}
