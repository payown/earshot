import CryptoKit
import Foundation
import UniformTypeIdentifiers

struct PersonalAudioCopyProgress: Sendable, Equatable {
    let copiedBytes: Int64
    let totalBytes: Int64?
}

struct PersonalAudioStagedCopy: Sendable, Equatable {
    let id: String
    let stagingFilename: String
    let fileExtension: String
    let byteSize: Int64
    let contentHash: String
    let typeIdentifier: String
}

/// App-owned media storage. Filenames are generated from the item's stable UUID;
/// database rows store only basenames so app-container relocation is harmless.
struct PersonalAudioStorage: Sendable {
    static let subdirectoryName = "PersonalAudio"
    static let copyChunkSize = 1_048_576
    static let progressIntervalBytes: Int64 = 4 * 1_048_576
    private static let currentProcessStagingPrefix = ".staging-\(UUID().uuidString)-"

    let rootURL: URL

    init(rootURL: URL? = nil) {
        self.rootURL = rootURL ?? URL.applicationSupportDirectory
            .appending(path: Self.subdirectoryName, directoryHint: .isDirectory)
    }

    func prepare() throws {
        try FileManager.default.createDirectory(
            at: rootURL, withIntermediateDirectories: true
        )
        // This is user-provided source material, unlike re-downloadable podcast
        // media. Explicitly clear a possible inherited exclusion.
        var values = URLResourceValues()
        values.isExcludedFromBackup = false
        var directory = rootURL
        try directory.setResourceValues(values)
    }

    func stageCopy(
        from sourceURL: URL,
        id: String,
        progress: (@Sendable (PersonalAudioCopyProgress) -> Void)? = nil
    ) throws -> PersonalAudioStagedCopy {
        try prepare()
        let fileExtension = Self.safeAudioExtension(sourceURL.pathExtension)
        let type = UTType(filenameExtension: fileExtension)
        guard let type, type.conforms(to: .audio) else {
            throw PersonalAudioStorageError.unsupportedType
        }
        // Keep the real extension last so AVFoundation recognizes the staged
        // file while it is still hidden from model-backed library queries.
        let stagingFilename = "\(Self.currentProcessStagingPrefix)\(id).partial.\(fileExtension)"
        let stagingURL = url(for: stagingFilename)
        try? FileManager.default.removeItem(at: stagingURL)

        let sourceAttributes = try? FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let expectedSize = (sourceAttributes?[.size] as? NSNumber)?.int64Value
        if let expectedSize,
           let available = try? rootURL.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]
           ).volumeAvailableCapacityForImportantUsage,
           available >= 0, expectedSize > available {
            throw PersonalAudioStorageError.insufficientStorage
        }

        var copiedBytes: Int64 = 0
        var lastReportedBytes: Int64 = 0
        var hasher = SHA256()
        var coordinationError: NSError?
        var copyError: Error?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(readingItemAt: sourceURL, options: [], error: &coordinationError) {
            coordinatedURL in
            do {
                let input = try FileHandle(forReadingFrom: coordinatedURL)
                defer { try? input.close() }
                guard FileManager.default.createFile(atPath: stagingURL.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                let output = try FileHandle(forWritingTo: stagingURL)
                defer { try? output.close() }

                while true {
                    try Task.checkCancellation()
                    guard let chunk = try input.read(upToCount: Self.copyChunkSize),
                          !chunk.isEmpty else { break }
                    hasher.update(data: chunk)
                    try output.write(contentsOf: chunk)
                    copiedBytes += Int64(chunk.count)
                    if copiedBytes - lastReportedBytes >= Self.progressIntervalBytes {
                        lastReportedBytes = copiedBytes
                        progress?(PersonalAudioCopyProgress(
                            copiedBytes: copiedBytes,
                            totalBytes: expectedSize
                        ))
                    }
                }
                try output.synchronize()
            } catch {
                copyError = error
            }
        }

        if let coordinationError { copyError = coordinationError }
        if let copyError {
            try? FileManager.default.removeItem(at: stagingURL)
            throw copyError
        }
        guard copiedBytes > 0 else {
            try? FileManager.default.removeItem(at: stagingURL)
            throw PersonalAudioStorageError.emptyFile
        }
        if let expectedSize, expectedSize != copiedBytes {
            try? FileManager.default.removeItem(at: stagingURL)
            throw PersonalAudioStorageError.sourceChangedDuringCopy
        }
        progress?(PersonalAudioCopyProgress(copiedBytes: copiedBytes, totalBytes: expectedSize))
        let fingerprint = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return PersonalAudioStagedCopy(
            id: id,
            stagingFilename: stagingFilename,
            fileExtension: fileExtension,
            byteSize: copiedBytes,
            contentHash: fingerprint,
            typeIdentifier: type.identifier
        )
    }

    func writeStagedArtwork(_ data: Data, id: String) throws -> String {
        try prepare()
        let filename = "\(Self.currentProcessStagingPrefix)\(id)-artwork.partial"
        try data.write(to: url(for: filename), options: .atomic)
        return filename
    }

    func finalize(_ staged: PersonalAudioStagedCopy, artworkStagingFilename: String?) throws
        -> (mediaFilename: String, artworkFilename: String?) {
        let mediaFilename = "\(staged.id).\(staged.fileExtension)"
        let mediaURL = url(for: mediaFilename)
        try FileManager.default.moveItem(at: url(for: staged.stagingFilename), to: mediaURL)
        var finalizedArtworkURL: URL?
        do {
            try includeInBackup(mediaURL)
            var artworkFilename: String?
            if let artworkStagingFilename {
                let filename = "\(staged.id)-artwork.jpg"
                let artworkURL = url(for: filename)
                try FileManager.default.moveItem(at: url(for: artworkStagingFilename), to: artworkURL)
                finalizedArtworkURL = artworkURL
                try includeInBackup(artworkURL)
                artworkFilename = filename
            }
            return (mediaFilename, artworkFilename)
        } catch {
            try? FileManager.default.removeItem(at: mediaURL)
            if let finalizedArtworkURL {
                try? FileManager.default.removeItem(at: finalizedArtworkURL)
            }
            throw error
        }
    }

    func discardStaged(_ staged: PersonalAudioStagedCopy, artworkFilename: String?) {
        try? FileManager.default.removeItem(at: url(for: staged.stagingFilename))
        if let artworkFilename { try? FileManager.default.removeItem(at: url(for: artworkFilename)) }
    }

    func removeManagedFiles(mediaFilename: String, artworkFilename: String?) throws {
        try removeBasename(mediaFilename)
        if let artworkFilename { try removeBasename(artworkFilename) }
    }

    func resolve(_ relativeFilename: String) -> URL? {
        guard Self.isSafeBasename(relativeFilename) else { return nil }
        return url(for: relativeFilename)
    }

    /// Removes staging files from earlier processes and generated final files
    /// with no model record. Current-process staging may still belong to an
    /// import or duplicate confirmation on another instance of the screen.
    /// Call only after the local SwiftData store has opened successfully.
    func reconcile(keeping filenames: Set<String>) throws {
        try prepare()
        for entry in try FileManager.default.contentsOfDirectory(
            at: rootURL, includingPropertiesForKeys: nil
        ) {
            let name = entry.lastPathComponent
            if name.hasPrefix(".staging-") {
                if !name.hasPrefix(Self.currentProcessStagingPrefix) {
                    try FileManager.default.removeItem(at: entry)
                }
                continue
            }
            guard Self.isGeneratedFinalFilename(name), !filenames.contains(name) else { continue }
            try FileManager.default.removeItem(at: entry)
        }
    }

    private func includeInBackup(_ url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = false
        var mutableURL = url
        try mutableURL.setResourceValues(values)
    }

    private func removeBasename(_ filename: String) throws {
        guard Self.isSafeBasename(filename) else { throw PersonalAudioStorageError.invalidFilename }
        let url = url(for: filename)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func url(for filename: String) -> URL {
        rootURL.appending(path: filename)
    }

    private static func safeAudioExtension(_ ext: String) -> String {
        let normalized = ext.lowercased()
        guard !normalized.isEmpty,
              normalized.utf8.count <= 12,
              normalized.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else {
            return ""
        }
        return normalized
    }

    private static func isSafeBasename(_ filename: String) -> Bool {
        !filename.isEmpty && filename == URL(fileURLWithPath: filename).lastPathComponent
            && !filename.contains("..") && !filename.hasPrefix("/")
    }

    private static func isGeneratedFinalFilename(_ filename: String) -> Bool {
        guard isSafeBasename(filename) else { return false }
        let stem = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "-artwork", with: "")
        return UUID(uuidString: stem) != nil
    }
}

enum PersonalAudioStorageError: Error, Equatable {
    case unsupportedType
    case insufficientStorage
    case emptyFile
    case sourceChangedDuringCopy
    case invalidFilename
}
