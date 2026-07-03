import Foundation
import SwiftData

/// Setting keys, mirroring the Flutter `app_settings` table keys. Kept as
/// String constants so they match exactly.
enum SettingsKey {
    static let autoDownloadCount = "auto_download_count"
    static let historyRetentionDays = "history_retention_days"
    static let downloadRetentionDays = "download_retention_days"
    static let onboardingComplete = "onboarding_complete"
    // crash_reporting_enabled / analytics_enabled: retained for data
    // compatibility only. No crash reporter or analytics SDK ships in the app;
    // the SettingsStore properties and Settings UI toggles were removed so the
    // App Store privacy label ("Data Not Collected") matches reality.
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
    // Whether the Previous/Next chapter buttons flanking the chapter name in the
    // player are shown. Default true (#515). Turning it off hides only the two
    // buttons; the chapter-name button and the artwork VoiceOver rotor
    // Previous/Next chapter actions stay available regardless.
    static let chapterNavButtonsVisible = "chapter_nav_buttons_visible"
    static let inboxOptInOnly = "inbox_opt_in_only"
    static let wifiOnlyDownloads = "wifi_only_downloads"
    static let groupQueueEpisodes = "group_queue_episodes"
    static let showEpisodeNumbers = "show_episode_numbers"
    // Whether playing an episode (the "Play now" default row action) also opens
    // the full player screen. Default true (#562).
    static let openPlayerOnPlay = "open_player_on_play"
    // Auto-advance boundary gates (#446). Both default true (existing behavior).
    // continueAfterEpisode off → stop at every episode boundary.
    // continueAfterGroupEnds off → stop when the next queue item is a different
    // podcast. Checked tightest-first at the on-complete handler.
    static let continueAfterEpisode = "continue_after_episode"
    static let continueAfterGroupEnds = "continue_after_group_ends"
    static let defaultLaunchScreen = "default_launch_screen"
    // Library list order (alphabetical / last published). SwiftUI-only preference,
    // stored as the ``LibrarySortOrder`` raw value.
    static let librarySortOrder = "library_sort_order"
    static let lastPlayingEpisodeID = "last_playing_episode_id"
    static let statsStreaksEnabled = "stats_streaks_enabled"
    // How many of a newly-added podcast's most-recent episodes to seed into the
    // inbox on subscribe. Mirrors Flutter's getInboxDefaultMaxEpisodes()
    // (default 3). 0 = seed none (the whole backlog is pre-dismissed);
    // ``SettingsDefault/inboxDefaultCountAll`` (-1) = seed the entire backlog.
    static let inboxDefaultCount = "inbox_default_count"
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
    // Outcome of the most recent Flutter→SwiftUI import attempt (notAttempted /
    // succeeded / failed). Surfaced in Settings → Data so the user can see
    // whether their older data came across, and re-run the import on demand
    // (#429). Stored as the ``MigrationStatus`` raw value.
    static let migrationStatus = "migration_status"
    // Timestamp (epoch seconds) of the most recent import attempt, set on every
    // run (automatic launch import or manual re-import). nil until the first
    // attempt (#429).
    static let migrationLastAttemptDate = "migration_last_attempt_date"
    // Appearance (#461): manual theme override, accent color, and layout
    // density. SwiftUI-only preferences, stored as the ``ThemeOverride`` /
    // ``AccentChoice`` / ``LayoutDensity`` raw values.
    static let themeOverride = "theme_override"
    static let accentColor = "accent_color"
    static let layoutDensity = "layout_density"
    // Prefix for the per-podcast episode-list filter (Unheard / All). The full
    // key is `podcast_filter_<feedURL>`, built by ``podcastFilter(feedURL:)``.
    // Keyed by the podcast's unique feed URL so the choice survives store
    // rebuilds and OPML re-import with no SwiftData schema change (#489).
    static let podcastFilterPrefix = "podcast_filter_"

    /// The full per-podcast filter key for a given feed URL (#489).
    static func podcastFilter(feedURL: String) -> String {
        podcastFilterPrefix + feedURL
    }
}

/// Outcome of the most recent Flutter→SwiftUI data import (#429). Persisted as a
/// String raw value under ``SettingsKey/migrationStatus`` so Settings → Data can
/// show the user whether their older data came across. Defaults to
/// ``notAttempted`` when unset or unparseable.
enum MigrationStatus: String {
    /// No import has run yet on this install.
    case notAttempted = "not_attempted"
    /// The last import completed: shells imported and the state/queue overlay
    /// finished without throwing.
    case succeeded
    /// The last import errored — either an import failure or the overlay threw.
    case failed
}

/// Documented defaults for settings not yet written by the user.
enum SettingsDefault {
    static let autoDownloadCount = 3
    static let historyRetentionDays = 90
    static let crashReportingEnabled = true  // retained; not read by SettingsStore (no telemetry ships)
    static let analyticsEnabled = true  // retained; not read by SettingsStore (no telemetry ships)
    static let skipSilenceEnabled = false  // retained; not read by SettingsStore (#369)
    static let globalSpeed = 1.0
    static let skipForwardSeconds = 30
    static let skipBackSeconds = 15
    static let wifiOnlyDownloads = true
    static let directTouchEnabled = false
    /// Chapter navigation buttons shown by default; users who prefer the artwork
    /// VoiceOver rotor can turn them off (#515).
    static let chapterNavButtonsVisible = true
    static let inboxOptInOnly = false
    static let groupQueueEpisodes = false
    /// Season/episode numbering in rows is OFF by default: most feeds don't set
    /// these, and users who don't care shouldn't have it read out (#452).
    static let showEpisodeNumbers = false
    /// Playing an episode opens the full player by default (#562); users who
    /// prefer to keep browsing can turn it off and use the mini player.
    static let openPlayerOnPlay = true
    // Auto-advance defaults true: preserves today's unconditional auto-advance
    // until the user opts to stop at a boundary (#446).
    static let continueAfterEpisode = true
    static let continueAfterGroupEnds = true
    static let onboardingComplete = false
    static let launchScreen: LaunchScreen = .inbox
    static let librarySortOrder: LibrarySortOrder = .alphabetical
    /// Per-podcast episode-list filter default: hide played episodes (#489).
    static let episodeListFilter: EpisodeListFilter = .unheard
    // Appearance defaults (#461): follow the system everywhere until the user
    // explicitly overrides.
    static let themeOverride: ThemeOverride = .followSystem
    static let accentColor: AccentChoice = .systemDefault
    static let layoutDensity: LayoutDensity = .comfortable
    static let statsStreaksEnabled = false
    /// Default number of most-recent episodes seeded into the inbox when a new
    /// podcast is added. Matches Flutter's default of 3.
    static let inboxDefaultCount = 3
    /// Sentinel stored under ``SettingsKey/inboxDefaultCount`` meaning "seed the
    /// entire backlog" (no cap). Distinct from 0, which seeds nothing.
    static let inboxDefaultCountAll = -1
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

    /// The outcome of the most recent import attempt, defaulting to
    /// ``MigrationStatus/notAttempted`` when unset or unparseable (#429).
    func migrationStatus() -> MigrationStatus {
        guard let raw = rawValue(SettingsKey.migrationStatus),
              let status = MigrationStatus(rawValue: raw)
        else { return .notAttempted }
        return status
    }

    func setMigrationStatus(_ status: MigrationStatus) {
        setRawValue(status.rawValue, for: SettingsKey.migrationStatus)
    }

    /// The timestamp of the most recent import attempt, or nil before any run
    /// (#429).
    func migrationLastAttemptDate() -> Date? {
        date(SettingsKey.migrationLastAttemptDate)
    }

    func setMigrationLastAttemptDate(_ value: Date) {
        setDate(value, for: SettingsKey.migrationLastAttemptDate)
    }

    /// The number of most-recent episodes to seed into the inbox per podcast on
    /// subscribe, defaulting to ``SettingsDefault/inboxDefaultCount`` (3) when
    /// unset. A value of 0 seeds nothing; ``SettingsDefault/inboxDefaultCountAll``
    /// (-1) seeds the entire backlog.
    func inboxDefaultCount() -> Int {
        int(SettingsKey.inboxDefaultCount, default: SettingsDefault.inboxDefaultCount)
    }

    func setInboxDefaultCount(_ value: Int) {
        setInt(value, for: SettingsKey.inboxDefaultCount)
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

    func librarySortOrder() -> LibrarySortOrder {
        guard let raw = rawValue(SettingsKey.librarySortOrder),
              let order = LibrarySortOrder(rawValue: raw)
        else { return SettingsDefault.librarySortOrder }
        return order
    }

    func setLibrarySortOrder(_ order: LibrarySortOrder) {
        setRawValue(order.rawValue, for: SettingsKey.librarySortOrder)
    }

    // MARK: Appearance (#461)

    func themeOverride() -> ThemeOverride {
        guard let raw = rawValue(SettingsKey.themeOverride),
              let theme = ThemeOverride(rawValue: raw)
        else { return SettingsDefault.themeOverride }
        return theme
    }

    func setThemeOverride(_ theme: ThemeOverride) {
        setRawValue(theme.rawValue, for: SettingsKey.themeOverride)
    }

    func accentChoice() -> AccentChoice {
        guard let raw = rawValue(SettingsKey.accentColor),
              let accent = AccentChoice(rawValue: raw)
        else { return SettingsDefault.accentColor }
        return accent
    }

    func setAccentChoice(_ accent: AccentChoice) {
        setRawValue(accent.rawValue, for: SettingsKey.accentColor)
    }

    func layoutDensity() -> LayoutDensity {
        guard let raw = rawValue(SettingsKey.layoutDensity),
              let density = LayoutDensity(rawValue: raw)
        else { return SettingsDefault.layoutDensity }
        return density
    }

    func setLayoutDensity(_ density: LayoutDensity) {
        setRawValue(density.rawValue, for: SettingsKey.layoutDensity)
    }

    /// The episode-list filter last used for the podcast with this feed URL,
    /// defaulting to ``SettingsDefault/episodeListFilter`` (.unheard) when unset
    /// or unparseable (#489). Keyed by feed URL (the model's unique key) so it
    /// survives store rebuilds and OPML re-import without a schema change.
    func episodeListFilter(forFeedURL feedURL: String) -> EpisodeListFilter {
        guard let raw = rawValue(SettingsKey.podcastFilter(feedURL: feedURL)),
              let filter = EpisodeListFilter(rawValue: raw)
        else { return SettingsDefault.episodeListFilter }
        return filter
    }

    func setEpisodeListFilter(_ filter: EpisodeListFilter, forFeedURL feedURL: String) {
        setRawValue(filter.rawValue, for: SettingsKey.podcastFilter(feedURL: feedURL))
    }

    private func save() {
        do {
            try context.save()
        } catch {
            AppLog.data.error("Failed to save setting: \(error.localizedDescription, privacy: .public)")
        }
    }
}
