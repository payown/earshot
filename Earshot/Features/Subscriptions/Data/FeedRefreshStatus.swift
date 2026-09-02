import Foundation
import Observation
import SwiftData

enum FeedRefreshStatusState: String, Codable, Equatable, Sendable {
    case never
    case running
    case completed
    case completedWithErrors
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
    var failureDetails: [FeedRefreshFailure] = []

    private enum CodingKeys: String, CodingKey {
        case state, trigger, scheduledAt, startedAt, endedAt, lastCompletedAt
        case lastSkippedAt, lastSkippedTrigger, checked, total, newEpisodes
        case unchangedFeeds, failedFeeds, failureDetails
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        state = try values.decodeIfPresent(FeedRefreshStatusState.self, forKey: .state) ?? .never
        trigger = try values.decodeIfPresent(FeedRefreshTrigger.self, forKey: .trigger) ?? .unspecified
        scheduledAt = try values.decodeIfPresent(Date.self, forKey: .scheduledAt)
        startedAt = try values.decodeIfPresent(Date.self, forKey: .startedAt)
        endedAt = try values.decodeIfPresent(Date.self, forKey: .endedAt)
        lastCompletedAt = try values.decodeIfPresent(Date.self, forKey: .lastCompletedAt)
        lastSkippedAt = try values.decodeIfPresent(Date.self, forKey: .lastSkippedAt)
        lastSkippedTrigger = try values.decodeIfPresent(FeedRefreshTrigger.self, forKey: .lastSkippedTrigger)
        checked = try values.decodeIfPresent(Int.self, forKey: .checked) ?? 0
        total = try values.decodeIfPresent(Int.self, forKey: .total) ?? 0
        newEpisodes = try values.decodeIfPresent(Int.self, forKey: .newEpisodes) ?? 0
        unchangedFeeds = try values.decodeIfPresent(Int.self, forKey: .unchangedFeeds) ?? 0
        failedFeeds = try values.decodeIfPresent(Int.self, forKey: .failedFeeds) ?? 0
        failureDetails = try values.decodeIfPresent([FeedRefreshFailure].self, forKey: .failureDetails) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(state, forKey: .state)
        try values.encode(trigger, forKey: .trigger)
        try values.encodeIfPresent(scheduledAt, forKey: .scheduledAt)
        try values.encodeIfPresent(startedAt, forKey: .startedAt)
        try values.encodeIfPresent(endedAt, forKey: .endedAt)
        try values.encodeIfPresent(lastCompletedAt, forKey: .lastCompletedAt)
        try values.encodeIfPresent(lastSkippedAt, forKey: .lastSkippedAt)
        try values.encodeIfPresent(lastSkippedTrigger, forKey: .lastSkippedTrigger)
        try values.encode(checked, forKey: .checked)
        try values.encode(total, forKey: .total)
        try values.encode(newEpisodes, forKey: .newEpisodes)
        try values.encode(unchangedFeeds, forKey: .unchangedFeeds)
        try values.encode(failedFeeds, forKey: .failedFeeds)
        try values.encode(failureDetails, forKey: .failureDetails)
    }
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
            if wasRunningAttemptSkipped {
                restoreStateBeforeSkippedAttempt()
            } else {
                snapshot.state = .interrupted
                snapshot.endedAt = now
            }
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
        // Compatibility for builds that marked a wake as running before the
        // throttle check. A skipped wake did no feed work and must not remain
        // visible as either running or interrupted.
        if snapshot.state == .running, wasRunningAttemptSkipped {
            restoreStateBeforeSkippedAttempt()
        }
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
        // Keep the last actionable failures available until this run finishes.
        // If iOS terminates a background refresh, users can still identify the
        // feeds that needed attention before the interrupted run began.
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
        // The feed actor already made this content durable. Saving a diagnostic
        // status row after every actor batch doubles SwiftData save notifications
        // and invalidates every live @Query in the tab tree. Keep live progress
        // in memory; start and finish (including cancellation) remain persisted.
    }

    func finish(_ report: SubscriptionRefreshReport, now: Date = Date()) {
        snapshot.state = switch report.completion {
        case .full: .completed
        case .completedWithErrors: .completedWithErrors
        case .partial: .interrupted
        case .failure: .failed
        }
        snapshot.endedAt = now
        switch report.completion {
        case .full, .completedWithErrors:
            snapshot.lastCompletedAt = now
        case .partial, .failure:
            break
        }
        snapshot.checked = report.attempted
        snapshot.total = report.total
        snapshot.newEpisodes = report.newEpisodes
        snapshot.unchangedFeeds = report.unchangedFeeds
        snapshot.failedFeeds = report.failed
        snapshot.failureDetails = report.failures
        persist()
    }

    func removeFailure(feedURL: String) {
        let canonical = FeedURLIdentity.canonical(feedURL)
        snapshot.failureDetails.removeAll {
            FeedURLIdentity.canonical($0.feedURL) == canonical
        }
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

    private var wasRunningAttemptSkipped: Bool {
        guard let startedAt = snapshot.startedAt,
              let skippedAt = snapshot.lastSkippedAt else { return false }
        return skippedAt >= startedAt
    }

    private func restoreStateBeforeSkippedAttempt() {
        snapshot.state = snapshot.lastCompletedAt == nil ? .never : .completed
        snapshot.startedAt = nil
        snapshot.endedAt = snapshot.lastCompletedAt
    }
}

enum FeedRefreshStatusPresentation {
    enum EntryFocus: Equatable {
        case heading
        case refreshStatus
    }

    static func entryFocus(_ snapshot: FeedRefreshStatusSnapshot) -> EntryFocus {
        snapshot.state == .running ? .refreshStatus : .heading
    }

    static func status(_ state: FeedRefreshStatusState) -> String {
        switch state {
        case .never: "Not refreshed yet"
        case .running: "Refreshing"
        case .completed: "Completed"
        case .completedWithErrors: "Completed with errors"
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
        case .completedWithErrors:
            let when = snapshot.endedAt.map(dateText) ?? "at an unknown time"
            let feedNoun = snapshot.failedFeeds == 1 ? "feed" : "feeds"
            return "Last \(automatic) refresh completed with errors \(when). Checked \(snapshot.checked) of \(snapshot.total) podcasts. Found \(snapshot.newEpisodes) new episodes. \(snapshot.failedFeeds) \(feedNoun) failed."
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
