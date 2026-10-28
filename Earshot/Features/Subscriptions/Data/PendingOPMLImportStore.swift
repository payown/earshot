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
    private let afterManifestCommit: (@Sendable (URL) throws -> Void)?

    init(rootURL: URL, afterManifestCommit: (@Sendable (URL) throws -> Void)? = nil) {
        self.rootURL = rootURL
        self.afterManifestCommit = afterManifestCommit
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

    /// Production store. `URL.applicationSupportDirectory` is process-local and
    /// avoids making the app runtime initializer throwable.
    static func live() -> PendingOPMLImportStore {
        PendingOPMLImportStore(
            rootURL: URL.applicationSupportDirectory
                .appending(path: directoryName, directoryHint: .isDirectory)
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

        // A same-name file may itself be damaged. Verify bytes rather than
        // trusting the content-addressed name before reusing it.
        let existing: Data?
        do {
            existing = try Data(contentsOf: contentURL, options: .mappedIfSafe)
        } catch where Self.isMissingFile(error) {
            existing = nil
        }
        if existing != data {
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
        let metadata: PendingOPMLImport
        do {
            metadata = try readManifest()
        } catch where Self.isMissingFile(error) {
            // An absent manifest is not permission to delete orphaned content.
            do {
                let contents = try FileManager.default.contentsOfDirectory(
                    at: documentsURL, includingPropertiesForKeys: nil
                )
                if !contents.isEmpty { throw PendingOPMLImportStoreError.contentMissing }
            } catch where Self.isMissingFile(error) {
                // A fresh install has no documents directory yet.
            }
            return nil
        }
        let contentURL = documentsURL.appending(
            path: metadata.contentFileName,
            directoryHint: .notDirectory
        )
        let values: URLResourceValues
        do {
            values = try contentURL.resourceValues(forKeys: [.fileSizeKey])
        } catch where Self.isMissingFile(error) {
            throw PendingOPMLImportStoreError.contentMissing
        }
        guard values.fileSize == metadata.byteCount else {
            throw PendingOPMLImportStoreError.contentSizeMismatch
        }
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

    /// Keep the entire original directory before replacing an unreadable record.
    /// Copying first leaves the original untouched if storage or access fails.
    func preserveUnreadableImport() throws {
        let archiveRoot = rootURL.deletingLastPathComponent()
            .appending(path: "Pending OPML Recovery", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: archiveRoot, withIntermediateDirectories: true)
        try applyCompleteProtection(archiveRoot)
        try excludeFromBackup(archiveRoot)
        let archive = archiveRoot.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        do {
            try FileManager.default.copyItem(at: rootURL, to: archive)
            try applyCompleteProtection(archive)
        } catch {
            try? FileManager.default.removeItem(at: archive)
            throw error
        }
    }

    private static func isMissingFile(_ error: Error) -> Bool {
        let nsError = error as NSError
        return (nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError)
            || (nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOENT))
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
        // The atomic write is the commit point. The root directory was already
        // excluded before staging, so a failure to repeat the attribute on the
        // manifest cannot turn a successful commit into a reported failure.
        do {
            if let afterManifestCommit {
                try afterManifestCommit(manifestURL)
            } else {
                try excludeFromBackup(manifestURL)
            }
        } catch {
            AppLog.data.error("OPML manifest backup attribute failed after commit: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func readManifest() throws -> PendingOPMLImport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: manifestURL)
        // Check the version before decoding the remaining fields. A future
        // version may have a different shape and must not be called corrupt.
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let version = object["formatVersion"] as? Int,
           version != PendingOPMLImport.currentFormatVersion {
            throw PendingOPMLImportStoreError.unsupportedFormat(version)
        }
        let metadata = try decoder.decode(PendingOPMLImport.self, from: data)
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
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch where Self.isMissingFile(error) {
            throw PendingOPMLImportStoreError.contentMissing
        }
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
