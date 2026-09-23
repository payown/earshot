import Foundation
import SwiftData
import UserNotifications

/// Badge permission is device-local and requested only by the opt-in control.
protocol AppIconBadging: Sendable {
    func requestPermission() async throws -> Bool
    func setCount(_ count: Int) async throws
}

struct SystemAppIconBadge: AppIconBadging {
    func requestPermission() async throws -> Bool {
        let current = await UNUserNotificationCenter.current().notificationSettings()
        if current.badgeSetting == .enabled { return true }
        guard current.authorizationStatus == .notDetermined else { return false }
        _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.badge])
        return await UNUserNotificationCenter.current().notificationSettings().badgeSetting == .enabled
    }

    func setCount(_ count: Int) async throws {
        try await UNUserNotificationCenter.current().setBadgeCount(count)
    }
}

enum AppIconBadgeCount {
    /// Fetch only completed device-local download keys, never the whole library.
    /// Models stay on this worker; only the scalar result crosses back to UI.
    @concurrent
    static func load(container: ModelContainer) async throws -> TabBadgeSnapshot {
        try loadSynchronously(container: container)
    }

    private static func loadSynchronously(container: ModelContainer) throws -> TabBadgeSnapshot {
        let context = ModelContext(container)
        let onMain = Thread.isMainThread
        let downloaded = DownloadStatus.downloaded.rawValue
        let rows = try context.fetch(FetchDescriptor<LocalEpisodeState>(
            predicate: #Predicate { $0.downloadPath != nil && $0.downloadStatusRaw == downloaded }
        ))
        let keys = Array(Set(rows.map {
            EpisodeLocalKey(feedURL: $0.podcastFeedURL, guid: $0.episodeGUID)
        }))
        let matches = try LocalStateStore.episodes(matching: keys, in: context)
        return TabBadgeSnapshot(
            count: matches.values.filter { $0.playedAt == nil && !$0.isPlayed }.count,
            executedStoreWorkOnMainThread: onMain || Thread.isMainThread
        )
    }

    /// Inspect save metadata only. Position saves must not trigger a query.
    static func downloadsChanged(_ notification: Notification) -> Bool {
        let info = notification.userInfo ?? [:]
        for key in [ModelContext.NotificationKey.insertedIdentifiers, .updatedIdentifiers, .deletedIdentifiers] {
            let value = info[key] ?? info[key.rawValue]
            let ids = (value as? [PersistentIdentifier]) ?? Array(value as? Set<PersistentIdentifier> ?? [])
            if ids.contains(where: { $0.entityName == "LocalEpisodeState" }) { return true }
        }
        return false
    }
}

/// One writer drains the newest requested state. If opt-out happens during an
/// in-flight system write, clearing follows it; an old result cannot win last.
@MainActor
final class AppIconBadgeController {
    static let shared = AppIconBadgeController { 0 }

    private let badge: any AppIconBadging
    private var load: @Sendable () async throws -> Int
    private var revision = 0
    private var enabled = false
    private var worker: Task<Void, Never>?

    init(badge: any AppIconBadging = SystemAppIconBadge(), load: @escaping @Sendable () async throws -> Int) {
        self.badge = badge
        self.load = load
    }

    func configure(container: ModelContainer) {
        load = { try await AppIconBadgeCount.load(container: container).count }
    }

    func refresh(enabled: Bool) {
        self.enabled = enabled
        revision += 1
        guard worker == nil else { return }
        worker = Task { await drain() }
    }

    func waitUntilIdle() async { await worker?.value }

    private func drain() async {
        while true {
            let requested = revision
            do {
                let count = enabled ? try await load() : 0
                if requested != revision { continue }
                try await badge.setCount(count)
            } catch {
                // Retain the last badge on a transient failure; the next real
                // change or foreground event retries. Never report a false zero.
                AppLog.notifications.error("App icon badge update failed")
            }
            if requested == revision { break }
        }
        worker = nil
    }
}
