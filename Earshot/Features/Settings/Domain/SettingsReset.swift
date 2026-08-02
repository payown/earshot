import Foundation
import SwiftData

/// Factory reset: deletes every persisted object and all downloaded files.
enum SettingsReset {
    @MainActor
    static func deleteAllLocalData(context: ModelContext) {
        // Stop and unload the player BEFORE deleting: it may hold the episode
        // being wiped, and its periodic position persist / session flush would
        // write to a deleted instance within seconds (#574). No userInfo means
        // "everything is going away"; PlayerService observes synchronously
        // (`queue: nil`, both sides @MainActor), so the unload completes
        // before the first delete below.
        NotificationCenter.default.post(name: .earshotWillDeleteEpisodes, object: nil)
        deleteAll(Podcast.self, context)        // cascades episodes, queue items, bookmarks, etc.
        deleteAll(Episode.self, context)
        deleteAll(QueueItem.self, context)
        deleteAll(ListeningSession.self, context)
        deleteAll(Bookmark.self, context)
        deleteAll(PodcastFolder.self, context)
        deleteAll(FolderMembership.self, context)
        deleteAll(EpisodeFolderMembership.self, context) // one-way to Episode, no cascade (#756)
        deleteAll(RecentlyExpired.self, context)
        deleteAll(QuickActionConfig.self, context)
        deleteAll(AppSetting.self, context)
        do {
            try context.save()
        } catch {
            AppLog.data.error("Factory reset save failed: \(error.localizedDescription, privacy: .public)")
        }
        deleteDownloadsDirectory()
        deleteArtworkCache()
    }

    private static func deleteAll<T: PersistentModel>(_ type: T.Type, _ context: ModelContext) {
        for object in (try? context.fetch(FetchDescriptor<T>())) ?? [] {
            context.delete(object)
        }
    }

    private static func deleteDownloadsDirectory() {
        guard let dir = try? FileManager.default
            .url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            .appendingPathComponent("Downloads", isDirectory: true)
        else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    /// Drops the disk-backed artwork cache (#385) so a factory reset doesn't
    /// leave stale podcast artwork behind. Clears the live ``URLCache`` and
    /// removes the on-disk cache directory.
    private static func deleteArtworkCache() {
        ArtworkCache.shared.clear()
        guard let dir = ArtworkCache.cacheDirectoryURL() else { return }
        try? FileManager.default.removeItem(at: dir)
    }
}

extension LaunchScreen {
    /// Human-readable name for the Settings launch-screen picker.
    var displayName: String {
        switch self {
        case .inbox: return "Inbox"
        case .queue: return "Queue"
        case .library: return "Library"
        case .downloads: return "Downloads"
        }
    }
}
