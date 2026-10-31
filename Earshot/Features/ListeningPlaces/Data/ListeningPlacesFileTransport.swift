import Foundation

actor ListeningPlacesFileTransport {
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

        Earshot writes this device's episode positions and played state to one file in "devices". Other compatible apps can use these files. Earshot does not import changes from other devices through this folder.

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
        try withFolder(bookmarkData: bookmarkData) { folder in
            _ = try prepareLayout(in: folder)
        }
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
            try Data(Self.readme.utf8).write(to: readmeURL, options: .atomic)
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
                if let coordinationError { throw coordinationError }
                if let creationError { throw creationError }
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
        var stale = false
        let folder = try URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        guard !stale else { throw ListeningPlacesFileError.staleBookmark }
        let accessed = folder.startAccessingSecurityScopedResource()
        defer { if accessed { folder.stopAccessingSecurityScopedResource() } }
        return try operation(folder)
    }
}

enum ListeningPlacesFileError: LocalizedError {
    case staleBookmark
    case couldNotCreateDirectory(String)
    case expectedDirectory(String)
    case deviceFileChanged

    var errorDescription: String? {
        switch self {
        case .staleBookmark: "The selected folder permission expired. Choose the folder again."
        case .couldNotCreateDirectory(let name):
            "The folder “\(name)” could not be created. Check that the selected location is available, then try again."
        case .expectedDirectory(let name):
            "A file named “\(name)” already exists where Earshot needs a folder. Rename or remove that file, then try again."
        case .deviceFileChanged:
            "The Listening Places file changed in its folder. Earshot left it untouched. Choose the folder again to review the current file before sharing."
        }
    }
}
