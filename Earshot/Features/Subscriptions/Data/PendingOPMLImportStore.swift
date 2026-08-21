import CryptoKit
import Foundation

enum PendingOPMLImportStoreError: Error, Equatable, Sendable {
    case unsupportedFormat(Int)
    case invalidContentFileName
    case contentMissing
    case contentSizeMismatch
    case contentHashMismatch
}

/// Stores one retryable OPML document in Application Support.
///
/// Content is written under its SHA-256 name before an atomic manifest commit.
/// Until that commit succeeds, an older manifest continues pointing to its valid
/// document. A force-quit therefore leaves either the old pending import or the
/// new one, never a manifest that names partially-written bytes.
actor PendingOPMLImportStore {
    private static let directoryName = "Pending OPML Import"
    private static let documentsDirectoryName = "Documents"
    private static let manifestName = "pending.json"

    private let rootURL: URL
    private let documentsURL: URL
    private let manifestURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL
        documentsURL = rootURL.appending(path: Self.documentsDirectoryName, directoryHint: .isDirectory)
        manifestURL = rootURL.appending(path: Self.manifestName, directoryHint: .notDirectory)
    }

    static func applicationSupportStore(fileManager: FileManager = .default) throws -> PendingOPMLImportStore {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return PendingOPMLImportStore(
            rootURL: applicationSupport.appending(path: directoryName, directoryHint: .isDirectory)
        )
    }

    @discardableResult
    func stage(
        _ data: Data,
        displayName: String,
        createdAt: Date = .now
    ) throws -> PendingOPMLImport {
        try prepareDirectories()

        let hash = Self.sha256(data)
        // ISO-8601 manifests intentionally store whole seconds. Normalize before
        // returning so the in-memory value is byte-for-byte equal after relaunch.
        let stableCreatedAt = Date(timeIntervalSince1970: floor(createdAt.timeIntervalSince1970))
        let metadata = PendingOPMLImport(
            displayName: Self.safeDisplayName(displayName),
            createdAt: stableCreatedAt,
            contentSHA256: hash,
            byteCount: data.count
        )
        let contentURL = documentsURL.appending(path: metadata.contentFileName, directoryHint: .notDirectory)

        if !FileManager.default.fileExists(atPath: contentURL.path) {
            try data.write(to: contentURL, options: [.atomic, .completeFileProtection])
        }
        // Reassert attributes even when content-addressing reuses existing bytes;
        // an interrupted restore or external file operation may have changed them.
        try applyCompleteProtection(contentURL)
        try excludeFromBackup(contentURL)

        try writeManifest(metadata)
        removeUnreferencedDocuments(keeping: metadata.contentFileName)
        return metadata
    }

    func load() throws -> StagedOPMLImport? {
        guard let metadata = try loadMetadata() else { return nil }
        let data = try validatedData(for: metadata)
        return StagedOPMLImport(metadata: metadata, data: data)
    }

    /// Restores launch state without mapping or hashing the document. Full content
    /// verification remains mandatory in ``load()`` immediately before retry.
    func loadMetadata() throws -> PendingOPMLImport? {
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            removeUnreferencedDocuments(keeping: nil)
            return nil
        }

        let metadata = try readManifest()
        let contentURL = documentsURL.appending(
            path: metadata.contentFileName,
            directoryHint: .notDirectory
        )
        guard FileManager.default.fileExists(atPath: contentURL.path) else {
            throw PendingOPMLImportStoreError.contentMissing
        }
        let values = try contentURL.resourceValues(forKeys: [.fileSizeKey])
        guard values.fileSize == metadata.byteCount else {
            throw PendingOPMLImportStoreError.contentSizeMismatch
        }
        removeUnreferencedDocuments(keeping: metadata.contentFileName)
        return metadata
    }

    @discardableResult
    func record(
        _ result: OPMLImportResultCounts,
        stopReason: OPMLImportStopReason
    ) throws -> PendingOPMLImport {
        let staged = try requirePending()
        var metadata = staged.metadata
        metadata.latestResult = result
        metadata.stopReason = stopReason
        try writeManifest(metadata)
        return metadata
    }

    func discard() throws {
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            try FileManager.default.removeItem(at: manifestURL)
        }
        removeUnreferencedDocuments(keeping: nil)
    }

    private func requirePending() throws -> StagedOPMLImport {
        guard let staged = try load() else { throw PendingOPMLImportStoreError.contentMissing }
        return staged
    }

    private func prepareDirectories() throws {
        try FileManager.default.createDirectory(at: documentsURL, withIntermediateDirectories: true)
        try applyCompleteProtection(rootURL)
        try applyCompleteProtection(documentsURL)
        try excludeFromBackup(rootURL)
    }

    private func writeManifest(_ metadata: PendingOPMLImport) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(metadata).write(
            to: manifestURL,
            options: [.atomic, .completeFileProtection]
        )
        try excludeFromBackup(manifestURL)
    }

    private func readManifest() throws -> PendingOPMLImport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(PendingOPMLImport.self, from: Data(contentsOf: manifestURL))
        guard metadata.formatVersion == PendingOPMLImport.currentFormatVersion else {
            throw PendingOPMLImportStoreError.unsupportedFormat(metadata.formatVersion)
        }
        let isLowercaseASCIIHex = metadata.contentSHA256.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
        guard metadata.contentFileName == "\(metadata.contentSHA256).opml",
              metadata.contentSHA256.utf8.count == 64,
              isLowercaseASCIIHex else {
            throw PendingOPMLImportStoreError.invalidContentFileName
        }
        return metadata
    }

    private func validatedData(for metadata: PendingOPMLImport) throws -> Data {
        let url = documentsURL.appending(path: metadata.contentFileName, directoryHint: .notDirectory)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PendingOPMLImportStoreError.contentMissing
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count == metadata.byteCount else {
            throw PendingOPMLImportStoreError.contentSizeMismatch
        }
        guard Self.sha256(data) == metadata.contentSHA256 else {
            throw PendingOPMLImportStoreError.contentHashMismatch
        }
        return data
    }

    private func removeUnreferencedDocuments(keeping fileName: String?) {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: documentsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for url in urls where url.lastPathComponent != fileName {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func applyCompleteProtection(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
    }

    private func excludeFromBackup(_ url: URL) throws {
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutableURL.setResourceValues(values)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func safeDisplayName(_ value: String) -> String {
        let lastComponent = URL(fileURLWithPath: value).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = lastComponent.isEmpty ? "Subscriptions.opml" : lastComponent
        return String(fallback.prefix(255))
    }
}
