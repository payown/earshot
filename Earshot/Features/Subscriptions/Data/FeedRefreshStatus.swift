import Foundation
import Observation
import SwiftData

enum FeedRefreshStatusState: String, Codable, Equatable, Sendable {
    case never
    case running
    case completed
    case interrupted
    case failed
}

struct FeedRefreshStatusSnapshot: Codable, Equatable, Sendable {
    var state: FeedRefreshStatusState = .never
    var trigger: FeedRefreshTrigger = .unspecified
    var scheduledAt: Date?
    var startedAt: Date?
    var endedAt: Date?
    var lastCompletedAt: Date?
    var lastSkippedAt: Date?
    var lastSkippedTrigger: FeedRefreshTrigger?
    var checked = 0
    var total = 0
    var newEpisodes = 0
    var unchangedFeeds = 0
    var failedFeeds = 0
}

struct FeedRefreshStatusCheckpoint: Sendable, Equatable {
    let checked: Int
    let newEpisodes: Int
    let unchangedFeeds: Int
}

enum FeedRefreshStatusStore {
    private struct Envelope: Codable {
        let version: Int
        let snapshot: FeedRefreshStatusSnapshot
    }

    private static let key = "feed_refresh_status"
    private static let version = 1

    static func load(from context: ModelContext) -> FeedRefreshStatusSnapshot? {
        guard let raw = LocalAppSettingIdentity.value(for: key, in: context),
              let data = raw.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.version == version else { return nil }
        return envelope.snapshot
    }

    static func save(_ snapshot: FeedRefreshStatusSnapshot, in context: ModelContext) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Envelope(version: version, snapshot: snapshot))
        guard let raw = String(data: data, encoding: .utf8) else { return }
        try LocalAppSettingIdentity.setValue(raw, for: key, in: context)
        try context.save()
    }
}

@MainActor
@Observable
final class FeedRefreshStatusMonitor {
    static let shared = FeedRefreshStatusMonitor()

    private(set) var snapshot = FeedRefreshStatusSnapshot()
    private var context: ModelContext?
    private var durableChecked = 0

    func configure(context: ModelContext, now: Date = Date()) {
        self.context = context
        snapshot = FeedRefreshStatusStore.load(from: context) ?? FeedRefreshStatusSnapshot()
        durableChecked = snapshot.checked
        if snapshot.state == .running {
            snapshot.state = .interrupted
            snapshot.endedAt = now
            persist()
        }
    }

    func releasePersistence() {
        context = nil
    }

    func recordScheduled(at date: Date) {
        snapshot.scheduledAt = date
        persist()
    }

    func recordSkipped(trigger: FeedRefreshTrigger, now: Date = Date()) {
        snapshot.lastSkippedAt = now
        snapshot.lastSkippedTrigger = trigger
        persist()
    }

    func start(trigger: FeedRefreshTrigger, total: Int = 0, now: Date = Date()) {
        snapshot.state = .running
        snapshot.trigger = trigger
        snapshot.startedAt = now
        snapshot.endedAt = nil
        snapshot.checked = 0
        snapshot.total = total
        snapshot.newEpisodes = 0
        snapshot.unchangedFeeds = 0
        snapshot.failedFeeds = 0
        durableChecked = 0
        persist()
    }

    func progress(checked: Int, total: Int) {
        snapshot.checked = checked
        snapshot.total = total
    }

    func checkpoint(_ checkpoint: FeedRefreshStatusCheckpoint) {
        durableChecked += checkpoint.checked
        snapshot.checked = max(snapshot.checked, durableChecked)
        snapshot.newEpisodes += checkpoint.newEpisodes
        snapshot.unchangedFeeds += checkpoint.unchangedFeeds
        persist()
    }

    func finish(_ report: SubscriptionRefreshReport, now: Date = Date()) {
        snapshot.state = switch report.completion {
        case .full: .completed
        case .partial: .interrupted
        case .failure: .failed
        }
        snapshot.endedAt = now
        if report.completion == .full { snapshot.lastCompletedAt = now }
        snapshot.checked = report.attempted
        snapshot.total = report.total
        snapshot.newEpisodes = report.newEpisodes
        snapshot.unchangedFeeds = report.unchangedFeeds
        snapshot.failedFeeds = report.failed
        persist()
    }

    private func persist() {
        guard let context else { return }
        do {
            try FeedRefreshStatusStore.save(snapshot, in: context)
        } catch {
            AppLog.data.error(
                "Could not save feed refresh status: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}

enum FeedRefreshStatusPresentation {
    static func status(_ state: FeedRefreshStatusState) -> String {
        switch state {
        case .never: "Not refreshed yet"
        case .running: "Refreshing"
        case .completed: "Completed"
        case .interrupted: "Interrupted"
        case .failed: "Failed"
        }
    }

    static func trigger(_ trigger: FeedRefreshTrigger) -> String {
        switch trigger {
        case .manualToolbar, .manualPullToRefresh: "Manual"
        case .coldLaunch: "App launch"
        case .foreground: "App opened"
        case .backgroundTask: "Background"
        case .unspecified: "Unknown"
        }
    }

    static func summary(
        _ snapshot: FeedRefreshStatusSnapshot,
        dateText: (Date) -> String
    ) -> String {
        let automatic = switch snapshot.trigger {
        case .manualToolbar, .manualPullToRefresh: "manual"
        default: "automatic"
        }
        switch snapshot.state {
        case .never:
            return "Automatic refresh has not run on this device."
        case .running:
            return "Refreshing podcasts. \(snapshot.checked) of \(snapshot.total) checked. \(snapshot.newEpisodes) new episodes found."
        case .completed:
            let when = snapshot.endedAt.map(dateText) ?? "at an unknown time"
            return "Last \(automatic) refresh completed \(when). Checked \(snapshot.checked) of \(snapshot.total) podcasts. Found \(snapshot.newEpisodes) new episodes. \(snapshot.unchangedFeeds) feeds were unchanged."
        case .interrupted:
            let when = snapshot.endedAt.map(dateText) ?? "at an unknown time"
            return "Last \(automatic) refresh was interrupted \(when). Checked \(snapshot.checked) of \(snapshot.total) podcasts. Found \(snapshot.newEpisodes) new episodes. Earshot will resume with the least recently checked podcasts."
        case .failed:
            let when = snapshot.endedAt.map(dateText) ?? "at an unknown time"
            return "Last \(automatic) refresh failed \(when). Checked \(snapshot.checked) of \(snapshot.total) podcasts. \(snapshot.failedFeeds) feeds failed."
        }
    }

    static func scheduled(_ date: Date?, dateText: (Date) -> String) -> String {
        guard let date else { return "No background check is currently requested." }
        return "Next background check requested after \(dateText(date)). iOS decides when Earshot runs."
    }
}
