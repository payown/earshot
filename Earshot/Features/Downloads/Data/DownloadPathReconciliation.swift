import Darwin
import Foundation
import SwiftData

/// Reads device-local scalars and checks files away from the UI executor. No
/// SwiftData models cross back, and healthy downloads require no main-store fetch.
enum DownloadPathReconciliation {
    struct DirectoryIdentity: Equatable, Sendable {
        let device: dev_t
        let inode: ino_t
    }

    enum FilePresence: Equatable { case present, missing, unknown }

    /// Holds an existing directory open without creating or modifying it.
    private struct DirectoryProbe {
        let url: URL
        let descriptor: Int32
        let identity: DirectoryIdentity

        init?(_ url: URL) {
            let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard descriptor >= 0 else { return nil }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_nlink > 0 else {
                close(descriptor)
                return nil
            }
            self.url = url
            self.descriptor = descriptor
            self.identity = DirectoryIdentity(device: info.st_dev, inode: info.st_ino)
        }

        func isStillCurrent() -> Bool {
            var openInfo = stat()
            var pathInfo = stat()
            guard fstat(descriptor, &openInfo) == 0, openInfo.st_nlink > 0,
                  stat(url.path, &pathInfo) == 0 else { return false }
            return identity == DirectoryIdentity(device: openInfo.st_dev, inode: openInfo.st_ino)
                && identity == DirectoryIdentity(device: pathInfo.st_dev, inode: pathInfo.st_ino)
        }

        func isCurrentPath() -> Bool {
            var pathInfo = stat()
            guard stat(url.path, &pathInfo) == 0 else { return false }
            return identity == DirectoryIdentity(device: pathInfo.st_dev, inode: pathInfo.st_ino)
        }

        func presence(name: String) -> FilePresence {
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.utf8.contains(0) else { return .unknown }
            var info = stat()
            if fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { return .present }
            return DownloadPathReconciliation.classifyFailedLookup(errno: errno)
        }

        func closeDescriptor() { close(descriptor) }
    }

    static func classifyFailedLookup(errno: Int32) -> FilePresence {
        errno == ENOENT ? .missing : .unknown
    }

    struct Correction: Sendable {
        let key: EpisodeLocalKey
        let originalPath: String
        let originalStatus: String
        let replacementName: String?
        let checkedURL: URL?
        let directoryIdentity: DirectoryIdentity?
    }

    private static func existingDownloadsDirectory() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Downloads", isDirectory: true)
    }

    @concurrent
    static func scan(
        container: ModelContainer,
        directoryURL: URL? = existingDownloadsDirectory(),
        presenceOverride: @Sendable (String) -> FilePresence? = { _ in nil }
    ) async throws -> [Correction] {
        try Task.checkCancellation()
        let context = ModelContext(container)
        let rows = try context.fetch(FetchDescriptor<LocalEpisodeState>(
            predicate: #Predicate { $0.downloadPath != nil }
        ))
        let directory = directoryURL.flatMap(DirectoryProbe.init)
        defer { directory?.closeDescriptor() }
        var corrections: [Correction] = []
        for row in rows {
            try Task.checkCancellation()
            guard let path = row.downloadPath else { continue }
            let url: URL?
            let replacement: String?
            if let name = DownloadPaths.storedFileName(path) {
                guard let directory else { continue }
                url = directory.url.appendingPathComponent(name)
                switch presenceOverride(name) ?? directory.presence(name: name) {
                case .present:
                    guard path != name else { continue }
                    replacement = name
                case .missing:
                    replacement = nil
                case .unknown:
                    continue
                }
            } else {
                url = nil
                replacement = nil
            }
            corrections.append(Correction(
                key: EpisodeLocalKey(feedURL: row.podcastFeedURL, guid: row.episodeGUID),
                originalPath: path,
                originalStatus: row.downloadStatusRaw,
                replacementName: replacement,
                checkedURL: url,
                directoryIdentity: url == nil ? nil : directory?.identity
            ))
        }
        // A folder replaced or removed during the scan cannot prove anything
        // about its former contents. Empty-path repairs do not depend on it.
        if let directory, !directory.isStillCurrent() {
            corrections.removeAll { $0.checkedURL != nil }
        }
        return corrections
    }

    /// Verify and apply each candidate without suspension. Per-file lookup and
    /// folder identity validation remain immediately adjacent to the mutation.
    static func verifyAndApplyBatch(
        _ corrections: [Correction],
        presenceOverride: (String) -> FilePresence? = { _ in nil },
        beforePathValidation: () -> Void = {},
        apply: (Correction) -> Void
    ) {
        let candidates = corrections.filter { $0.checkedURL != nil }
        guard let first = candidates.first, let firstURL = first.checkedURL,
              let expected = first.directoryIdentity,
              let directory = DirectoryProbe(firstURL.deletingLastPathComponent()) else {
            for correction in corrections where correction.checkedURL == nil { apply(correction) }
            return
        }
        defer { directory.closeDescriptor() }
        guard directory.identity == expected, directory.isStillCurrent(),
              candidates.allSatisfy({ candidate in
                  candidate.checkedURL?.deletingLastPathComponent() == directory.url
                      && candidate.directoryIdentity == expected
              }) else {
            for correction in corrections where correction.checkedURL == nil { apply(correction) }
            return
        }
        for correction in corrections {
            guard let url = correction.checkedURL else { apply(correction); continue }
            if correction.replacementName == nil,
               (presenceOverride(url.lastPathComponent) ?? directory.presence(name: url.lastPathComponent)) != .missing { continue }
            beforePathValidation()
            // Checking the current path after each lookup prevents a replaced
            // directory from authorizing a mutation based on its old descriptor.
            guard directory.isCurrentPath() else { continue }
            apply(correction)
        }
    }
}
