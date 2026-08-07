import Foundation
import SwiftData

/// Crash-safe, file-level Settings reset. The caller releases the live
/// container and process services on the main actor; this transaction performs
/// all persistence and filesystem work away from that actor.
enum SettingsReset {
    private struct Entry: Codable, Sendable {
        let source: String
        let staged: String
    }

    private struct Journal: Codable, Sendable {
        enum Phase: String, Codable, Sendable { case moving, committed }
        let phase: Phase
        let quarantine: String
        let entries: [Entry]
    }

    private struct Paths: Sendable {
        let applicationSupport: URL
        let primary: URL
        let local: URL
        let downloads: URL
        let artwork: URL?
        let backups: URL
        let journal: URL
    }

    /// Performs the authorized all-local-data reset. A false result means no
    /// success announcement or navigation may be emitted by the caller.
    static func performFileReset() async -> Bool {
        return await performFileReset(
            applicationSupport: .applicationSupportDirectory,
            documents: .documentsDirectory,
            caches: .cachesDirectory
        )
    }

    /// Test seam for a fully disposable directory tree; production always uses
    /// the process's Application Support, Documents, and Caches roots above.
    static func performFileReset(
        applicationSupport: URL, documents: URL, caches: URL
    ) async -> Bool {
        let primary = applicationSupport.appending(path: "default.store")
        let paths = Paths(
            applicationSupport: applicationSupport,
            primary: primary,
            local: StoreMigration.localStoreURL(for: primary),
            downloads: documents.appending(path: "Downloads", directoryHint: .isDirectory),
            artwork: caches.appending(path: ArtworkCache.directoryName, directoryHint: .isDirectory),
            backups: MigrationBackupManager.backupRoot(for: primary),
            journal: applicationSupport.appending(path: "settings-reset-transaction.json")
        )
        return await Task.detached(priority: .userInitiated) {
            do {
                try recover(paths)
                try transact(paths)
                return true
            } catch {
                AppLog.data.error("Settings reset failed: \(error.localizedDescription, privacy: .public)")
                return false
            }
        }.value
    }

    private static func transact(_ paths: Paths) throws {
        let fm = FileManager.default
        let quarantineName = "settings-reset-quarantine-\(UUID().uuidString)"
        let quarantine = paths.applicationSupport.appending(path: quarantineName, directoryHint: .isDirectory)
        try fm.createDirectory(at: quarantine, withIntermediateDirectories: false)
        var candidates = storeFiles(paths.primary) + storeFiles(paths.local)
        candidates += [paths.backups, paths.downloads]
        if let artwork = paths.artwork { candidates.append(artwork) }
        let existing = candidates.filter { fm.fileExists(atPath: $0.path) }
        let entries = existing.enumerated().map {
            Entry(source: $0.element.path, staged: "\($0.offset)-\($0.element.lastPathComponent)")
        }
        var journal = Journal(phase: .moving, quarantine: quarantineName, entries: entries)
        try write(journal, at: paths.journal)
        for entry in entries {
            try fm.moveItem(at: URL(fileURLWithPath: entry.source),
                            to: quarantine.appending(path: entry.staged))
        }
        journal = Journal(phase: .committed, quarantine: quarantineName, entries: entries)
        try write(journal, at: paths.journal)
        try fm.removeItem(at: quarantine)
        try fm.removeItem(at: paths.journal)
    }

    private static func recover(_ paths: Paths) throws {
        guard FileManager.default.fileExists(atPath: paths.journal.path) else { return }
        let journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: paths.journal))
        let quarantine = paths.applicationSupport.appending(path: journal.quarantine, directoryHint: .isDirectory)
        if journal.phase == .moving {
            for entry in journal.entries {
                let staged = quarantine.appending(path: entry.staged)
                let source = URL(fileURLWithPath: entry.source)
                guard FileManager.default.fileExists(atPath: staged.path) else { continue }
                try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: source)
                try FileManager.default.moveItem(at: staged, to: source)
            }
        }
        try? FileManager.default.removeItem(at: quarantine)
        try FileManager.default.removeItem(at: paths.journal)
    }

    private static func write(_ journal: Journal, at url: URL) throws {
        try JSONEncoder().encode(journal).write(to: url, options: .atomic)
    }

    private static func storeFiles(_ store: URL) -> [URL] {
        [store, URL(fileURLWithPath: store.path + "-wal"), URL(fileURLWithPath: store.path + "-shm"), URL(fileURLWithPath: store.path + "-journal")]
    }

    #if DEBUG
    /// Compatibility seam for existing in-memory unit tests. The application
    /// reset flow never calls this row-deletion path.
    @MainActor
    static func deleteAllLocalData(context: ModelContext) {
        NotificationCenter.default.post(name: .earshotWillDeleteEpisodes, object: nil)
        delete(Podcast.self, context); delete(Episode.self, context)
        delete(QueueItem.self, context); delete(ListeningSession.self, context)
        delete(Bookmark.self, context); delete(PodcastFolder.self, context)
        delete(FolderMembership.self, context); delete(EpisodeFolderMembership.self, context)
        delete(RecentlyExpired.self, context); delete(QuickActionConfig.self, context)
        delete(AppSetting.self, context)
        try? context.save()
        let fm = FileManager.default
        if let downloads = try? fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            .appending(path: "Downloads", directoryHint: .isDirectory) {
            try? fm.removeItem(at: downloads)
        }
        ArtworkCache.shared.clear()
        if let artwork = ArtworkCache.cacheDirectoryURL() { try? fm.removeItem(at: artwork) }
    }

    private static func delete<T: PersistentModel>(_ type: T.Type, _ context: ModelContext) {
        for object in (try? context.fetch(FetchDescriptor<T>())) ?? [] { context.delete(object) }
    }
    #endif
}

extension LaunchScreen {
    var displayName: String {
        switch self { case .inbox: return "Inbox"; case .queue: return "Queue"; case .library: return "Library"; case .downloads: return "Downloads" }
    }
}
