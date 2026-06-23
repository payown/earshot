import Foundation
import SwiftData

/// Setting keys, mirroring the Flutter `app_settings` table keys. Kept as
/// String constants so they match exactly.
enum SettingsKey {
    static let autoDownloadCount = "auto_download_count"
    static let historyRetentionDays = "history_retention_days"
    static let downloadRetentionDays = "download_retention_days"
    static let onboardingComplete = "onboarding_complete"
    static let crashReportingEnabled = "crash_reporting_enabled"
    static let analyticsEnabled = "analytics_enabled"
    // skip_silence_enabled: retained for data compatibility only. The feature
    // requires MTAudioProcessingTap (Decision F14) and is not implemented. The
    // SettingsStore property and Settings UI toggle have been removed (#369).
    static let skipSilenceEnabled = "skip_silence_enabled"
    static let voiceEnhanceEnabled = "voice_enhance_enabled"
    static let globalSpeed = "global_speed"
    static let skipForwardSeconds = "skip_forward_seconds"
    static let skipBackSeconds = "skip_back_seconds"
    static let directTouchEnabled = "direct_touch_enabled"
    static let inboxOptInOnly = "inbox_opt_in_only"
    static let wifiOnlyDownloads = "wifi_only_downloads"
    static let groupQueueEpisodes = "group_queue_episodes"
    static let defaultLaunchScreen = "default_launch_screen"
    static let lastPlayingEpisodeID = "last_playing_episode_id"
    static let statsStreaksEnabled = "stats_streaks_enabled"
    // Flutter→SwiftUI one-time subscription import.
    static let flutterMigrationComplete = "flutter_migration_complete"
    // Count of launches where the import attempted but the Flutter database
    // yielded no subscriptions. Bounds retries so a transient first-launch miss
    // recovers while a genuinely empty install stops looping (#426).
    static let flutterMigrationAttempts = "flutter_migration_attempts"
    // Whether the post-import per-episode state overlay (played / inbox /
    // position) and queue-order restore completed without error. Set only on
    // success, so a migration that imported show shells but failed (or never
    // reached) the overlay can self-heal a state-only re-restore on a later
    // launch instead of stranding the user with shows but no history (#426).
    static let flutterEpisodeStateRestored = "flutter_episode_state_restored"
    // Timestamp (epoch seconds) of the last completed feed refresh. Used by
    // FeedRefreshPolicy to throttle background refreshes (#381).
    static let lastFeedRefresh = "last_feed_refresh"
}

/// Documented defaults for settings not yet written by the user.
enum SettingsDefault {
    static let autoDownloadCount = 3
    static let historyRetentionDays = 90
    static let crashReportingEnabled = true
    static let analyticsEnabled = true
    static let skipSilenceEnabled = false  // retained; not read by SettingsStore (#369)
    static let globalSpeed = 1.0
    static let skipForwardSeconds = 30
    static let skipBackSeconds = 15
    static let wifiOnlyDownloads = true
    static let directTouchEnabled = false
    static let inboxOptInOnly = false
    static let groupQueueEpisodes = false
    static let onboardingComplete = false
    static let launchScreen: LaunchScreen = .inbox
    static let statsStreaksEnabled = false
}

/// Typed access to the generic ``AppSetting`` key/value store. The full
/// settings UI (#344) builds on this; F2 provides the storage + typed helpers.
@MainActor
final class AppSettingsStore {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    // MARK: Raw access

    func rawValue(_ key: String) -> String? {
        var descriptor = FetchDescriptor<AppSetting>(
            predicate: #Predicate { $0.key == key }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first?.value
    }

    func setRawValue(_ value: String, for key: String) {
        var descriptor = FetchDescriptor<AppSetting>(
            predicate: #Predicate { $0.key == key }
        )
        descriptor.fetchLimit = 1
        if let existing = (try? context.fetch(descriptor))?.first {
            existing.value = value
        } else {
            context.insert(AppSetting(key: key, value: value))
        }
        save()
    }

    // MARK: Typed helpers

    func bool(_ key: String, default fallback: Bool) -> Bool {
        guard let raw = rawValue(key) else { return fallback }
        return (raw as NSString).boolValue
    }

    func setBool(_ value: Bool, for key: String) {
        setRawValue(value ? "true" : "false", for: key)
    }

    func int(_ key: String, default fallback: Int) -> Int {
        guard let raw = rawValue(key), let v = Int(raw) else { return fallback }
        return v
    }

    func setInt(_ value: Int, for key: String) {
        setRawValue(String(value), for: key)
    }

    func double(_ key: String, default fallback: Double) -> Double {
        guard let raw = rawValue(key), let v = Double(raw) else { return fallback }
        return v
    }

    func setDouble(_ value: Double, for key: String) {
        setRawValue(String(value), for: key)
    }

    /// Reads an optional Int where the stored string `"null"` means "no limit".
    func optionalInt(_ key: String) -> Int? {
        guard let raw = rawValue(key), raw != "null" else { return nil }
        return Int(raw)
    }

    func setOptionalInt(_ value: Int?, for key: String) {
        setRawValue(value.map(String.init) ?? "null", for: key)
    }

    /// Reads a Date stored as epoch seconds, or `nil` if unset/unparseable.
    func date(_ key: String) -> Date? {
        guard let raw = rawValue(key), let seconds = TimeInterval(raw) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    func setDate(_ value: Date, for key: String) {
        setRawValue(String(value.timeIntervalSince1970), for: key)
    }

    func launchScreen() -> LaunchScreen {
        guard let raw = rawValue(SettingsKey.defaultLaunchScreen),
              let screen = LaunchScreen(rawValue: raw)
        else { return SettingsDefault.launchScreen }
        return screen
    }

    func setLaunchScreen(_ screen: LaunchScreen) {
        setRawValue(screen.rawValue, for: SettingsKey.defaultLaunchScreen)
    }

    private func save() {
        do {
            try context.save()
        } catch {
            AppLog.data.error("Failed to save setting: \(error.localizedDescription, privacy: .public)")
        }
    }
}
