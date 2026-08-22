import Foundation

actor ListeningPlacesFileTransport {
    private static let readme = """
        Listening Places
        ================

        This folder is how your audio apps remember where you got to, across your devices, without an account and without anybody's server.

        Each device writes exactly one file in "devices" and reads the others. Nothing here is audio -- these are only positions, a few hundred kilobytes at most. The ids are hashed, so this folder does not list what you listen to in readable form.

        You can delete this folder at any time. Nothing breaks: every app still knows your place on the device you are using. It just stops being shared.

        Format: listening-places/1
        """

    func readDeviceFile(bookmarkData: Data, deviceID: String) throws -> Data? {
        try withFolder(bookmarkData: bookmarkData) { folder in
            let target = deviceFile(in: folder, deviceID: deviceID)
            guard FileManager.default.fileExists(atPath: target.path) else { return nil }
            return try Data(contentsOf: target)
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

    var errorDescription: String? {
        switch self {
        case .staleBookmark: "The selected folder permission expired. Choose the folder again."
        case .couldNotCreateDirectory(let name):
            "The folder “\(name)” could not be created. Check that the selected location is available, then try again."
        case .expectedDirectory(let name):
            "A file named “\(name)” already exists where Earshot needs a folder. Rename or remove that file, then try again."
        }
    }
}
