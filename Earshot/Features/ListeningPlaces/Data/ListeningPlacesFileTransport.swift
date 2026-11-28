import Darwin
import Foundation

/// Disposable Playback staging only. This filters this device's file; it does
/// not inspect, edit, or delete another app's file.
#if DEBUG
enum ListeningPlacesOwnedFileFilter {
    enum FilterError: Error { case invalidFile, fileTooLarge }
    private static let maximumBytes = 2 * 1_024 * 1_024

    static func filtered(
        _ data: Data, shareEpisodes: Bool, now: Date = .now
    ) throws -> Data {
        guard data.count <= maximumBytes,
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              root["format"] as? String == ListeningPlacesFormat.identifier,
              let rows = root["records"] as? [[String: Any]] else {
            throw FilterError.invalidFile
        }
        let allowed = rows.filter { row in
            guard let id = row["id"] as? String else { return false }
            // This staging slice never enables follow or folder exchange.
            return shareEpisodes && id.hasPrefix("episode:")
        }
        guard allowed.count != rows.count else { return data }
        root["records"] = allowed
        root["written_at"] = ISO8601DateFormatter().string(from: now)
        let filtered = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        guard filtered.count <= maximumBytes else { throw FilterError.fileTooLarge }
        return filtered
    }
}
#endif

/// Bounded bytes from a different writer. Parsing and applying are separate:
/// the transport never trusts metadata in a file or mutates another device's file.
struct ListeningPlacesOtherDeviceRead: Sendable {
    struct File: Sendable {
        let fileName: String
        let data: Data
    }

    struct Skip: Sendable {
        enum Reason: Sendable, Equatable {
            case invalidName
            case notRegularFile
            case tooLarge
            case totalBudget
            case fileLimit
            case directoryLimit
            case unavailable
        }

        /// Nil for unsafe names and directory-wide failures. Never use an
        /// unvalidated provider name directly in a spoken status message.
        let fileName: String?
        let reason: Reason
    }

    let files: [File]
    let skipped: [Skip]
}

actor ListeningPlacesFileTransport {
    #if DEBUG
    enum ConsentError: Error { case staleScope, foreignOwnedFile }
    struct ConsentToken: Sendable { let revision: UInt64 }
    struct ScopeResult: Sendable {
        let token: ConsentToken
        let ownedFile: Data?
        let scrubbed: Bool
    }
    private var scopeRevision: UInt64 = 0
    private var shareEpisodes = false

    /// Consent and coordinated file replacement share one actor boundary.
    /// A caller acknowledges Off only after this returns or reports failure.
    func setDisposablePlaybackScopeAndScrub(
        bookmarkData: Data, deviceID: String,
        episodes: Bool, now: Date = .now
    ) throws -> ScopeResult {
        scopeRevision &+= 1
        shareEpisodes = episodes
        if let observed = try readDeviceFile(bookmarkData: bookmarkData, deviceID: deviceID) {
            guard let root = (try? JSONSerialization.jsonObject(with: observed)) as? [String: Any],
                  root["device"] as? String == deviceID,
                  (root["app"] as? String)?.hasPrefix("earshot/") == true else {
                throw ConsentError.foreignOwnedFile
            }
            let filtered = try ListeningPlacesOwnedFileFilter.filtered(
                observed, shareEpisodes: episodes, now: now
            )
            let changed = filtered != observed
            if changed {
                try replaceDeviceFile(bookmarkData: bookmarkData, deviceID: deviceID,
                    expected: observed, with: filtered)
            }
            return ScopeResult(token: ConsentToken(revision: scopeRevision),
                ownedFile: filtered, scrubbed: changed)
        }
        return ScopeResult(token: ConsentToken(revision: scopeRevision),
            ownedFile: nil, scrubbed: false)
    }

    func replaceDisposablePlaybackFileWithConsent(
        bookmarkData: Data, deviceID: String, expected: Data?,
        with data: Data, token: ConsentToken, now: Date = .now
    ) throws {
        guard token.revision == scopeRevision else { throw ConsentError.staleScope }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              root["device"] as? String == deviceID,
              (root["app"] as? String)?.hasPrefix("earshot/") == true else {
            throw ConsentError.foreignOwnedFile
        }
        let filtered = try ListeningPlacesOwnedFileFilter.filtered(
            data, shareEpisodes: shareEpisodes, now: now
        )
        try replaceDeviceFile(bookmarkData: bookmarkData, deviceID: deviceID,
            expected: expected, with: filtered)
    }
    #endif

    private static let maximumOtherDeviceFileBytes = 2 * 1_024 * 1_024
    private static let maximumOtherDeviceTotalBytes = 16 * 1_024 * 1_024
    private static let maximumOtherDeviceFiles = 64
    private static let maximumDirectoryEntries = 256

    private static let legacyReadme = """
        Listening Places
        ================

        This folder is how your audio apps remember where you got to, across your devices, without an account and without anybody's server.

        Each device writes exactly one file in "devices" and reads the others. Nothing here is audio -- these are only positions, a few hundred kilobytes at most. The ids are hashed, so this folder does not list what you listen to in readable form.

        You can delete this folder at any time. Nothing breaks: every app still knows your place on the device you are using. It just stops being shared.

        Format: listening-places/1
        """

    private static let readme = """
        Listening Places
        ================

        Earshot can write this device's episode positions and played state to one file in "devices" when sharing is on. Other compatible apps can use that file. If receiving is separately on, Earshot can read eligible public podcast playback places from other device files when you choose Sync Playback Now. It does not import follows or folders.

        Earshot's iCloud Sync separately syncs your Earshot library and listening progress between your devices through your private iCloud account. Listening Places does not require iCloud Sync or an Earshot account.

        These files contain no audio. Episode identifiers are hashed. Readable podcast and episode names are excluded unless you enable them in Earshot. Your chosen folder provider may store and sync these files.

        You can delete this folder at any time. Your listening progress stays in Earshot on this device; Listening Places sharing stops.

        Format: listening-places/1
        """

    func readDeviceFile(bookmarkData: Data, deviceID: String) throws -> Data? {
        try withFolder(bookmarkData: bookmarkData) { folder in
            let target = deviceFile(in: folder, deviceID: deviceID)
            var coordinationError: NSError?
            var readError: Error?
            var result: Data?
            NSFileCoordinator().coordinate(readingItemAt: target, options: [], error: &coordinationError) { url in
                do { result = try Data(contentsOf: url) }
                catch {
                    if (error as NSError).code != NSFileReadNoSuchFileError { readError = error }
                }
            }
            if let coordinationError { throw coordinationError }
            if let readError { throw readError }
            return result
        }
    }

    /// Reads only existing other-device files. Unlike the writer paths this
    /// must not call `prepareLayout`: a read never creates the README or any
    /// directory, and a missing shared folder simply has no places to import.
    /// Each file is coordinated and capped before the parser sees its bytes.
    func readOtherDeviceFiles(
        bookmarkData: Data,
        excludingDeviceID ownDeviceID: String
    ) throws -> ListeningPlacesOtherDeviceRead {
        try withFolder(bookmarkData: bookmarkData) { folder in
            let places = folder.appending(path: "Listening Places", directoryHint: .isDirectory)
            let devices = places.appending(path: "devices", directoryHint: .isDirectory)
            guard try Self.existingDirectory(at: places),
                  try Self.existingDirectory(at: devices) else {
                return ListeningPlacesOtherDeviceRead(files: [], skipped: [])
            }

            var enumerationFailed = false
            guard let enumerator = FileManager.default.enumerator(
                at: devices,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsSubdirectoryDescendants, .skipsPackageDescendants],
                errorHandler: { _, _ in enumerationFailed = true; return false }
            ) else {
                return ListeningPlacesOtherDeviceRead(files: [], skipped: [
                    .init(fileName: nil, reason: .unavailable)
                ])
            }
            var candidates: [URL] = []
            var directoryLimitReached = false
            while let url = enumerator.nextObject() as? URL {
                try Task.checkCancellation()
                guard candidates.count < Self.maximumDirectoryEntries else {
                    directoryLimitReached = true
                    break
                }
                candidates.append(url)
            }
            var files: [ListeningPlacesOtherDeviceRead.File] = []
            var skipped: [ListeningPlacesOtherDeviceRead.Skip] = []
            var remainingBytes = Self.maximumOtherDeviceTotalBytes
            var eligibleCount = 0

            for url in candidates.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                try Task.checkCancellation()
                let name = url.lastPathComponent
                guard name.hasSuffix(".json"),
                      name.caseInsensitiveCompare("\(ownDeviceID).json") != .orderedSame else { continue }
                guard Self.safeDeviceFileName(name) else {
                    skipped.append(.init(fileName: nil, reason: .invalidName))
                    continue
                }
                let values: URLResourceValues
                do { values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]) }
                catch {
                    skipped.append(.init(fileName: name, reason: .unavailable))
                    continue
                }
                guard values.isSymbolicLink != true,
                      values.isDirectory != true,
                      values.isRegularFile != false else {
                    skipped.append(.init(fileName: name, reason: .notRegularFile))
                    continue
                }
                eligibleCount += 1
                guard eligibleCount <= Self.maximumOtherDeviceFiles else {
                    skipped.append(.init(fileName: name, reason: .fileLimit))
                    continue
                }
                guard remainingBytes > 0 else {
                    skipped.append(.init(fileName: name, reason: .totalBudget))
                    continue
                }
                let limit = min(Self.maximumOtherDeviceFileBytes, remainingBytes)
                switch Self.coordinatedRead(at: url, limit: limit) {
                case .data(let data):
                    remainingBytes -= data.count
                    files.append(.init(fileName: name, data: data))
                case .exceeded:
                    skipped.append(.init(fileName: name, reason: limit < Self.maximumOtherDeviceFileBytes
                        ? .totalBudget : .tooLarge))
                case .unavailable:
                    skipped.append(.init(fileName: name, reason: .unavailable))
                }
            }
            if directoryLimitReached { skipped.append(.init(fileName: nil, reason: .directoryLimit)) }
            if enumerationFailed { skipped.append(.init(fileName: nil, reason: .unavailable)) }
            return ListeningPlacesOtherDeviceRead(files: files, skipped: skipped)
        }
    }

    private enum BoundedRead {
        case data(Data)
        case exceeded
        case unavailable
    }

    private static func coordinatedRead(at target: URL, limit: Int) -> BoundedRead {
        var result: BoundedRead = .unavailable
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: target, options: [], error: &coordinationError) { url in
            do {
                // Recheck inside coordination, then open without following a
                // final-component symlink if a shared-folder peer replaces it
                // between enumeration and the coordinated read.
                let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                guard values.isSymbolicLink != true, values.isDirectory != true else { return }
                let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard descriptor >= 0 else { return }
                var metadata = stat()
                guard Darwin.fstat(descriptor, &metadata) == 0,
                      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
                    _ = Darwin.close(descriptor)
                    return
                }
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                defer { try? handle.close() }
                var data = Data()
                while data.count <= limit {
                    let amount = min(64 * 1_024, limit + 1 - data.count)
                    guard let chunk = try handle.read(upToCount: amount), !chunk.isEmpty else {
                        result = .data(data)
                        return
                    }
                    data.append(chunk)
                }
                result = .exceeded
            } catch {
                result = .unavailable
            }
        }
        return coordinationError == nil ? result : .unavailable
    }

    private static func existingDirectory(at url: URL) throws -> Bool {
        do {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw ListeningPlacesFileError.expectedDirectory(url.lastPathComponent)
            }
            return true
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError {
                return false
            }
            throw error
        }
    }

    private static func safeDeviceFileName(_ name: String) -> Bool {
        guard name.hasSuffix(".json") else { return false }
        let stem = name.dropLast(5)
        return (1 ... 64).contains(stem.utf8.count)
            && stem.utf8.allSatisfy { byte in
                (48 ... 57).contains(byte) || (65 ... 90).contains(byte)
                    || (97 ... 122).contains(byte) || byte == 45 || byte == 95
            }
    }

    /// Replaces the device file only if its contents still match the last
    /// coordinated observation. `expected == nil` means the file was absent.
    func replaceDeviceFile(bookmarkData: Data, deviceID: String, expected: Data?, with data: Data) throws {
        try withFolder(bookmarkData: bookmarkData) { folder in
            let (_, devices) = try prepareLayout(in: folder)
            let target = devices.appending(path: "\(deviceID).json")
            var coordinationError: NSError?
            var operationError: Error?
            NSFileCoordinator().coordinate(writingItemAt: target, options: .forReplacing, error: &coordinationError) { url in
                do {
                    let actual: Data?
                    do { actual = try Data(contentsOf: url) }
                    catch {
                        guard (error as NSError).code == NSFileReadNoSuchFileError else { throw error }
                        actual = nil
                    }
                    guard actual == expected else { throw ListeningPlacesFileError.deviceFileChanged }
                    try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                } catch { operationError = error }
            }
            if let coordinationError { throw coordinationError }
            if let operationError { throw operationError }
        }
    }

    /// Confirm the observed bytes under a coordinated read. Unreadable or
    /// changed files must not be identified as the previously observed file.
    func confirmsDeviceFile(bookmarkData: Data, deviceID: String, expected: Data) throws -> Bool {
        try withFolder(bookmarkData: bookmarkData) { folder in
            let target = deviceFile(in: folder, deviceID: deviceID)
            var coordinationError: NSError?
            var matches = false
            NSFileCoordinator().coordinate(readingItemAt: target, options: [], error: &coordinationError) { url in
                do {
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    var actual = Data()
                    // One extra byte distinguishes an exact match from a longer file.
                    while actual.count <= expected.count {
                        guard let chunk = try handle.read(upToCount: min(64 * 1024, expected.count + 1 - actual.count)),
                              !chunk.isEmpty else { break }
                        actual.append(chunk)
                    }
                    matches = actual == expected
                } catch {
                    matches = false
                }
            }
            if let coordinationError { throw coordinationError }
            return matches
        }
    }

    func prepareFolder(bookmarkData: Data) throws {
        do {
            try withFolder(bookmarkData: bookmarkData) { folder in
                _ = try prepareLayout(in: folder)
            }
        } catch {
            logFailure("prepare folder", error)
            throw error
        }
    }

    /// Compares the resolved filesystem targets, so alternate bookmarks for
    /// the same directory (for example, a symlink) are recognized as one
    /// device-file location.
    func refersToSameFolder(_ firstBookmark: Data, as secondBookmark: Data) throws -> Bool {
        let firstFolder = try resolveFolder(firstBookmark)
        let firstAccessed = firstFolder.startAccessingSecurityScopedResource()
        defer { if firstAccessed { firstFolder.stopAccessingSecurityScopedResource() } }
        let secondFolder = try resolveFolder(secondBookmark)
        let secondAccessed = secondFolder.startAccessingSecurityScopedResource()
        defer { if secondAccessed { secondFolder.stopAccessingSecurityScopedResource() } }
        let first = firstFolder.standardizedFileURL.resolvingSymlinksInPath()
        let second = secondFolder.standardizedFileURL.resolvingSymlinksInPath()
        return first == second
    }

    func writeDeviceFile(bookmarkData: Data, deviceID: String, data: Data) throws {
        try withFolder(bookmarkData: bookmarkData) { folder in
            let (_, devices) = try prepareLayout(in: folder)

            let target = devices.appending(path: "\(deviceID).json")
            var coordinationError: NSError?
            var writeError: Error?
            NSFileCoordinator().coordinate(
                writingItemAt: target,
                options: .forReplacing,
                error: &coordinationError
            ) { coordinatedURL in
                do {
                    try data.write(to: coordinatedURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                } catch {
                    writeError = error
                }
            }
            if let coordinationError { throw coordinationError }
            if let writeError { throw writeError }
        }
    }

    func removeDeviceFile(bookmarkData: Data, deviceID: String) throws {
        try withFolder(bookmarkData: bookmarkData) { folder in
            let target = deviceFile(in: folder, deviceID: deviceID)
            guard FileManager.default.fileExists(atPath: target.path) else { return }
            var coordinationError: NSError?
            var removalError: Error?
            NSFileCoordinator().coordinate(
                writingItemAt: target,
                options: .forDeleting,
                error: &coordinationError
            ) { coordinatedURL in
                do { try FileManager.default.removeItem(at: coordinatedURL) }
                catch { removalError = error }
            }
            if let coordinationError { throw coordinationError }
            if let removalError { throw removalError }
        }
    }

    /// Removes the device file only when it still matches the last observed
    /// contents. An absent observation permits only an absent file.
    func removeDeviceFileIfUnchanged(bookmarkData: Data, deviceID: String, expected: Data?) throws {
        try withFolder(bookmarkData: bookmarkData) { folder in
            let target = deviceFile(in: folder, deviceID: deviceID)
            var coordinationError: NSError?
            var operationError: Error?
            NSFileCoordinator().coordinate(writingItemAt: target, options: .forDeleting, error: &coordinationError) { url in
                do {
                    let actual: Data?
                    do { actual = try Data(contentsOf: url) }
                    catch {
                        guard (error as NSError).code == NSFileReadNoSuchFileError else { throw error }
                        actual = nil
                    }
                    guard actual == expected else { throw ListeningPlacesFileError.deviceFileChanged }
                    guard actual != nil else { return }
                    try FileManager.default.removeItem(at: url)
                } catch { operationError = error }
            }
            if let coordinationError { throw coordinationError }
            if let operationError { throw operationError }
        }
    }

    private func deviceFile(in folder: URL, deviceID: String) -> URL {
        folder
            .appending(path: "Listening Places", directoryHint: .isDirectory)
            .appending(path: "devices", directoryHint: .isDirectory)
            .appending(path: "\(deviceID).json")
    }

    private func prepareLayout(in folder: URL) throws -> (places: URL, devices: URL) {
        let places = try ensureSubdirectory(named: "Listening Places", in: folder)
        let devices = try ensureSubdirectory(named: "devices", in: places)

        let readmeURL = places.appending(path: "README.txt")
        if !FileManager.default.fileExists(atPath: readmeURL.path) {
            try createReadmeIfMissing(in: places)
        } else if (try? Data(contentsOf: readmeURL)) == Data(Self.legacyReadme.utf8) {
            // Update only the exact text generated by older Earshot versions.
            // The comparison happens inside coordination so edited files survive.
            var coordinationError: NSError?
            NSFileCoordinator().coordinate(
                writingItemAt: readmeURL, options: .forMerging, error: &coordinationError
            ) { url in
                guard (try? Data(contentsOf: url)) == Data(Self.legacyReadme.utf8) else { return }
                try? Data(Self.readme.utf8).write(to: url, options: .atomic)
            }
        }
        return (places, devices)
    }

    private func createReadmeIfMissing(in places: URL) throws {
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(
            writingItemAt: places,
            options: .forMerging,
            error: &coordinationError
        ) { coordinatedPlaces in
            let readmeURL = coordinatedPlaces.appending(path: "README.txt")
            guard !FileManager.default.fileExists(atPath: readmeURL.path) else { return }
            do {
                try Data(Self.readme.utf8).write(to: readmeURL, options: .atomic)
            } catch {
                writeError = error
            }
        }
        if let coordinationError {
            logFailure("coordinate README creation", coordinationError)
            throw coordinationError
        }
        if let writeError {
            logFailure("create README", writeError)
            throw writeError
        }
    }

    private func ensureSubdirectory(named name: String, in parent: URL) throws -> URL {
        let requestedURL = parent.appending(path: name, directoryHint: .isDirectory)
        if try isDirectory(requestedURL) { return requestedURL }

        // Coordinate the existing parent because the requested directory does
        // not exist yet. File Provider extensions such as Dropbox use this to
        // materialize the selected location and authorize creation. Create one
        // level at a time so the provider can publish each new parent.
        var lastError: Error?
        for attempt in 1 ... 4 {
            do {
                var coordinationError: NSError?
                var creationError: Error?
                NSFileCoordinator().coordinate(
                    writingItemAt: parent,
                    options: .forMerging,
                    error: &coordinationError
                ) { coordinatedParent in
                    do {
                        let coordinatedURL = coordinatedParent.appending(
                            path: name,
                            directoryHint: .isDirectory
                        )
                        try FileManager.default.createDirectory(
                            at: coordinatedURL,
                            withIntermediateDirectories: false
                        )
                    } catch {
                        creationError = error
                    }
                }
                if let coordinationError {
                    logFailure("coordinate directory \(name)", coordinationError)
                    throw coordinationError
                }
                if let creationError {
                    logFailure("create directory \(name)", creationError)
                    throw creationError
                }
                guard try isDirectory(requestedURL) else {
                    throw ListeningPlacesFileError.couldNotCreateDirectory(name)
                }
                return requestedURL
            } catch {
                if (try? isDirectory(requestedURL)) == true { return requestedURL }
                lastError = error
                if attempt < 4 {
                    Thread.sleep(forTimeInterval: Double(attempt) * 0.15)
                }
            }
        }
        throw lastError ?? ListeningPlacesFileError.couldNotCreateDirectory(name)
    }

    private func isDirectory(_ url: URL) throws -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }
        guard isDirectory.boolValue else {
            throw ListeningPlacesFileError.expectedDirectory(url.lastPathComponent)
        }
        return true
    }

    private func withFolder<T>(
        bookmarkData: Data,
        operation: (URL) throws -> T
    ) throws -> T {
        let folder: URL
        do {
            folder = try resolveFolder(bookmarkData)
        } catch {
            logFailure("resolve folder bookmark", error)
            throw error
        }
        let accessed = folder.startAccessingSecurityScopedResource()
        if !accessed {
            // An app-owned URL may need no scope. Keep the original operation
            // error, but identify a possible permission failure in diagnostics.
            AppLog.data.warning("Listening Places resolved folder did not start security-scoped access")
        }
        defer { if accessed { folder.stopAccessingSecurityScopedResource() } }
        return try operation(folder)
    }

    private func logFailure(_ stage: String, _ error: Error) {
        let nsError = error as NSError
        AppLog.data.error(
            "Listening Places \(stage, privacy: .public) failed [\(nsError.domain, privacy: .public) \(nsError.code, privacy: .public)]"
        )
    }

    private func resolveFolder(_ bookmarkData: Data) throws -> URL {
        var stale = false
        let folder = try URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        guard !stale else { throw ListeningPlacesFileError.staleBookmark }
        return folder
    }
}

enum ListeningPlacesFileError: LocalizedError {
    case staleBookmark
    case couldNotCreateDirectory(String)
    case expectedDirectory(String)
    case deviceFileChanged
    case unrecognizedDeviceFile

    var errorDescription: String? {
        switch self {
        case .staleBookmark: "The selected folder permission expired. Choose the folder again."
        case .couldNotCreateDirectory(let name):
            "The folder “\(name)” could not be created. Check that the selected location is available, then try again."
        case .expectedDirectory(let name):
            "A file named “\(name)” already exists where Earshot needs a folder. Rename or remove that file, then try again."
        case .deviceFileChanged:
            "The Listening Places file changed in its folder. Earshot left it untouched. Choose the folder again to review the current file before sharing."
        case .unrecognizedDeviceFile:
            "A different or invalid Listening Places device file is in this folder. Earshot left it untouched. Choose another folder before sharing."
        }
    }
}
