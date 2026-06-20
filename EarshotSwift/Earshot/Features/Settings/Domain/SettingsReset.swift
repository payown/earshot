import Foundation
import SwiftData

/// Factory reset: deletes every persisted object and all downloaded files.
enum SettingsReset {
    @MainActor
    static func deleteAllLocalData(context: ModelContext) {
        deleteAll(Podcast.self, context)        // cascades episodes, queue items, bookmarks, etc.
        deleteAll(Episode.self, context)
        deleteAll(QueueItem.self, context)
        deleteAll(ListeningSession.self, context)
        deleteAll(Bookmark.self, context)
        deleteAll(PodcastFolder.self, context)
        deleteAll(FolderMembership.self, context)
        deleteAll(RecentlyExpired.self, context)
        deleteAll(QuickActionConfig.self, context)
        deleteAll(AppSetting.self, context)
        do {
            try context.save()
        } catch {
            AppLog.data.error("Factory reset save failed: \(error.localizedDescription, privacy: .public)")
        }
        deleteDownloadsDirectory()
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
}

extension LaunchScreen {
    /// Human-readable name for the Settings launch-screen picker.
    var displayName: String {
        switch self {
        case .inbox: return "Inbox"
        case .queue: return "Queue"
        case .library: return "Podcasts"
        case .downloads: return "Downloads"
        }
    }
}
