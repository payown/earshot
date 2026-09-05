import Foundation
import SwiftData

extension Notification.Name {
    static let earshotVolumeBoostSettingDidChange = Notification.Name(
        "earshotVolumeBoostSettingDidChange"
    )
    static let earshotSkipSilenceSettingDidChange = Notification.Name(
        "earshotSkipSilenceSettingDidChange"
    )
}

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
    /// Device-local default for compacting sustained silence during playback.
    /// Individual podcasts can inherit, enable, or disable this preference.
    static let skipSilenceEnabled = "skip_silence_enabled"
    // Retained for persisted-data compatibility. The former "Voice enhance"
    // control only forced mono and changed prompt interruption behavior; it did
    // not enhance speech, so no current code reads or writes this key.
    static let voiceEnhanceEnabled = "voice_enhance_enabled"
    static let globalSpeed = "global_speed"
    /// Device-local default gain. Per-episode overrides are also device-local.
    static let volumeBoost = "volume_boost"
    static let skipForwardSeconds = "skip_forward_seconds"
    static let skipBackSeconds = "skip_back_seconds"
    // direct_touch_enabled: retained for data compatibility only. Its one
    // consumer, PlayerService.fastForwardRotorAvailable, no longer gates on it
    // (#610 -- the fast-forward rotor action is now always available regardless).
    // The SettingsStore property and "Direct-touch playback area" Settings UI
    // toggle have been removed.
    static let directTouchEnabled = "direct_touch_enabled"
    // Whether the Previous/Next chapter buttons flanking the chapter name in the
    // player are shown. Default true (#515). Turning it off hides only the two
    // buttons; the chapter-name button and the artwork VoiceOver rotor
    // Previous/Next chapter actions stay available regardless.
    static let chapterNavButtonsVisible = "chapter_nav_buttons_visible"
    static let inboxOptInOnly = "inbox_opt_in_only"
    static let wifiOnlyDownloads = "wifi_only_downloads"
    /// Whether a completed background audio download produces a local
    /// notification. Device-local because iOS notification authorization and
    /// delivery are device-specific. Off by default (#453).
    static let downloadCompletionNotifications = "download_completion_notifications"
    /// When on, an episode's downloaded file is deleted automatically once the
    /// listener marks it played, finishes it, or deliberately removes it from
    /// the queue. The persisted key retains its original name for compatibility.
    /// Global, off by default (destructive, opt-in).
    static let deleteDownloadAfterPlayed = "delete_download_after_played"
    /// When on, any episode added to the queue (manually or by auto-queue) is
    /// downloaded for offline playback, honoring the Wi-Fi-only gate. On by default.
    static let autoDownloadQueued = "auto_download_queued"
    /// Global played/unheard filter for the Downloads screen (#641). Not
    /// per-podcast — Downloads spans every show — so it's a single scalar key.
    static let downloadsPlayedFilter = "downloads_played_filter"
    // Queue grouping mode (#762). Began life as a "Group by podcast" bool and
    // now stores a ``QueueGrouping`` raw value under the SAME key; the legacy
    // `"true"`/`"false"` strings are migrated on read by
    // ``AppSettingsStore/queueGrouping()``.
    static let groupQueueEpisodes = "group_queue_episodes"
    /// JSON-encoded stable episode identities for the reusable Queue lineup.
    /// Mirrored through private iCloud; applying it is always an explicit action.
    static let morningLineup = "morning_lineup"
    static let showEpisodeNumbers = "show_episode_numbers"
    static let spokenEpisodePodcastName = "spoken_episode_podcast_name"
    static let spokenEpisodePublishedDate = "spoken_episode_published_date"
    static let spokenEpisodeDownloadStatus = "spoken_episode_download_status"
    static let spokenEpisodeDuration = "spoken_episode_duration"
    static let spokenEpisodeDescriptionMode = "spoken_episode_description_mode"
    static let spokenPodcastDescriptionMode = "spoken_podcast_description_mode"
    /// Whether Earshot provides its own tactile cues for playback starts and
    /// completed refreshes. Device-local because haptic preference and hardware
    /// availability belong to this device, not the listener's synced library.
    static let hapticFeedbackEnabled = "haptic_feedback_enabled"
    /// Which source metadata appears in transcript Markdown exports. Device-local
    /// so each device can favor the files it creates without changing another.
    static let transcriptExportMetadata = "transcript_export_metadata"
    // Whether playing an episode (the "Play now" default row action) also opens
    // the full player screen. Default true (#562).
    static let openPlayerOnPlay = "open_player_on_play"
    // Whether the full player closes after natural completion when playback has
    // no next episode to advance to. Default off (#718).
    static let dismissPlayerWhenPlaybackEnds = "dismiss_player_when_playback_ends"
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
    // Order for a podcast's episode list (alphabetical / latest first / latest
    // last). Global SwiftUI-only preference, stored as the ``EpisodeSortOrder``
    // raw value; defaults to ``EpisodeSortOrder/latestFirst`` which preserves the
    // pre-existing pubDate-descending order (#459).
    static let episodeSortOrder = "episode_sort_order"
    static let lastPlayingEpisodeID = "last_playing_episode_id"
    static let statsStreaksEnabled = "stats_streaks_enabled"
    // How many of a newly-added podcast's most-recent episodes to seed into the
    // inbox on subscribe. Mirrors Flutter's getInboxDefaultMaxEpisodes()
    // (default 3). 0 = seed none (the whole backlog is pre-dismissed);
    // ``SettingsDefault/inboxDefaultCountAll`` (-1) = seed the entire backlog.
    static let inboxDefaultCount = "inbox_default_count"
    // flutter_migration_complete / flutter_migration_attempts /
    // flutter_episode_state_restored: retained for data compatibility only. The
    // Flutter→SwiftUI import feature was removed (#580); OPML is the only
    // re-import path. Existing stores may still carry these rows, so the key
    // names are kept but nothing reads or writes them.
    static let flutterMigrationComplete = "flutter_migration_complete"
    static let flutterMigrationAttempts = "flutter_migration_attempts"
    static let flutterEpisodeStateRestored = "flutter_episode_state_restored"
    // Timestamp (epoch seconds) of the last completed feed refresh. Used by
    // FeedRefreshPolicy to throttle background refreshes (#381).
    static let lastFeedRefresh = "last_feed_refresh"
    // migration_status / migration_last_attempt_date: retained for data
    // compatibility only. They recorded the outcome and timestamp of the removed
    // Flutter→SwiftUI import (#580); existing stores may still carry the rows,
    // so the key names are kept but nothing reads or writes them.
    static let migrationStatus = "migration_status"
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
        podcastFilterPrefix + FeedURLIdentity.canonical(feedURL)
    }

    // Prefix for the per-podcast inbox episode limit. The full key is
    // `podcast_inbox_cap_<feedURL>`, built by ``podcastInboxCap(feedURL:)``.
    // Keyed by the podcast's unique feed URL — same pattern as the filter above
    // (#489) — so the user's saved cap survives unsubscribe → re-subscribe
    // (including OPML re-import), which otherwise creates a fresh `Podcast`
    // with `inboxMaxEpisodes = nil` and silently drops the limit (#548).
    // `Podcast.inboxMaxEpisodes` stays the live source of truth for all
    // existing flows; this keyed copy exists only to restore it on re-add.
    static let podcastDisplayNamePrefix = "podcast_display_name_"

    static func podcastDisplayName(feedURL: String) -> String {
        podcastDisplayNamePrefix + FeedURLIdentity.canonical(feedURL)
    }

    static let podcastInboxCapPrefix = "podcast_inbox_cap_"

    /// The full per-podcast inbox-cap key for a given feed URL (#548).
    static func podcastInboxCap(feedURL: String) -> String {
        podcastInboxCapPrefix + FeedURLIdentity.canonical(feedURL)
    }

    /// Versioned per-podcast ingest-filter JSON. Mirrored through the existing
    /// AppSetting projection; no SwiftData schema change is involved.
    static let episodeFilterConfigurationPrefix = "episode_filter_configuration_"

    static func episodeFilterConfiguration(feedURL: String) -> String {
        episodeFilterConfigurationPrefix + FeedURLIdentity.canonical(feedURL)
    }

    static let pendingCloudFollowPrefix = "pending_cloud_follow_"
    static let pendingCloudUnfollowPrefix = "pending_cloud_unfollow_"
    /// Device-local restart journal for a subscription learned from an active
    /// Cloud row while this device still held a catalog-only shell. Unlike the
    /// explicit Follow intent, this marker never revives a subscription tombstone
    /// or takes ownership of the Cloud subscription clock.
    static let pendingCloudRemoteActivationPrefix = "pending_cloud_remote_activation_"

    static func pendingCloudFollow(token: String) -> String {
        pendingCloudFollowPrefix + token
    }

    static func pendingCloudUnfollow(token: String) -> String {
        pendingCloudUnfollowPrefix + token
    }

    static func pendingCloudRemoteActivation(token: String) -> String {
        pendingCloudRemoteActivationPrefix + token
    }

    /// Device-local unresolved runtime guard. It remains visible until the user
    /// reviews and saves that podcast's filters.
    static let episodeFilterSafetyWarningPrefix = "episode_filter_safety_warning_"

    static func episodeFilterSafetyWarning(feedURL: String) -> String {
        episodeFilterSafetyWarningPrefix + FeedURLIdentity.canonical(feedURL)
    }

    // Device-local acknowledgement for a podcast whose audio was verified to
    // require cleartext HTTP (#709). Kept out of the mirrored-key allowlist: a
    // listener approves the network risk independently on each device.
    static let cleartextMediaApprovalPrefix = "cleartext_media_approved_"

    static func cleartextMediaApproval(identity: String) -> String {
        cleartextMediaApprovalPrefix + FeedURLIdentity.canonical(identity)
    }

    // Persisted Earshot Plus entitlement state (#634). Recomputed from
    // StoreKit `Transaction.currentEntitlements` at launch, after every
    // `Transaction.updates` event, and after Restore Purchases (#633) — see
    // ``EntitlementStore``. `earshotPlusEntitled` is the flag a future paywall
    // gate (#635) reads synchronously; `earshotPlusEntitlementProduct` stores
    // which verified Plus product supplies the entitlement for presentation;
    // `earshotPlusActiveSubscription` records whether a still-active monthly
    // or yearly fact exists so Lifetime overlap guidance is accurate;
    // `earshotPlusEntitlementLastSynced` records when the state was last
    // recomputed, for diagnostics only.
    static let earshotPlusEntitled = "earshot_plus_entitled"
    static let earshotPlusEntitlementProduct = "earshot_plus_entitlement_product"
    static let earshotPlusActiveSubscription = "earshot_plus_active_subscription"
    static let earshotPlusEntitlementLastSynced = "earshot_plus_entitlement_last_synced"

    // One-time grandfathering snapshot for the free-tier podcast cap (#635).
    // Set exactly once, on the first launch of the build that introduces cap
    // gating: `podcastCapGatingIntroduced` flips true and
    // `grandfatheredPodcastCount` snapshots the podcast count AT THAT MOMENT
    // (0 for a fresh install). Never retroactively enforced against podcasts
    // that already existed before gating shipped — see PodcastCapPolicy.
    static let podcastCapGatingIntroduced = "podcast_cap_gating_introduced"
    static let grandfatheredPodcastCount = "grandfathered_podcast_count"

    // Listening Places is intentionally device-local. A security-scoped folder
    // bookmark cannot be used on another device, and mirroring it would both
    // fail and disclose a local provider path.
    static let listeningPlacesEnabled = "listening_places_enabled"
    static let listeningPlacesBookmark = "listening_places_bookmark"
    static let listeningPlacesFolderName = "listening_places_folder_name"
    static let listeningPlacesDeviceID = "listening_places_device_id"
    static let listeningPlacesIncludeLabels = "listening_places_include_labels"
}

enum AppSettingScope {
    private static let mirroredKeys: Set<String> = [
        SettingsKey.historyRetentionDays, SettingsKey.voiceEnhanceEnabled,
        SettingsKey.globalSpeed, SettingsKey.skipForwardSeconds,
        SettingsKey.skipBackSeconds, SettingsKey.chapterNavButtonsVisible,
        SettingsKey.inboxOptInOnly, SettingsKey.groupQueueEpisodes,
        SettingsKey.morningLineup,
        SettingsKey.showEpisodeNumbers, SettingsKey.openPlayerOnPlay,
        SettingsKey.dismissPlayerWhenPlaybackEnds,
        SettingsKey.continueAfterEpisode, SettingsKey.continueAfterGroupEnds,
        SettingsKey.defaultLaunchScreen, SettingsKey.librarySortOrder,
        SettingsKey.episodeSortOrder, SettingsKey.statsStreaksEnabled,
        SettingsKey.inboxDefaultCount, SettingsKey.themeOverride,
        SettingsKey.accentColor, SettingsKey.layoutDensity,
        SettingsKey.podcastCapGatingIntroduced, SettingsKey.grandfatheredPodcastCount,
    ]

    static func isLocal(_ key: String) -> Bool {
        let canonical = AppSettingIdentity.canonicalKey(key)
        if canonical.hasPrefix(SettingsKey.podcastFilterPrefix)
            || canonical.hasPrefix(SettingsKey.podcastInboxCapPrefix)
            || canonical.hasPrefix(SettingsKey.podcastDisplayNamePrefix)
            || canonical.hasPrefix(SettingsKey.episodeFilterConfigurationPrefix) {
            return false
        }
        return !mirroredKeys.contains(canonical)
    }

    static func isMirrored(_ key: String) -> Bool { !isLocal(key) }
}

/// Documented defaults for settings not yet written by the user.
enum SettingsDefault {
    static let autoDownloadCount = 0
    static let historyRetentionDays = 90
    static let crashReportingEnabled = true  // retained; not read by SettingsStore (no telemetry ships)
    static let analyticsEnabled = true  // retained; not read by SettingsStore (no telemetry ships)
    static let skipSilenceEnabled = false
    static let globalSpeed = 1.0
    static let volumeBoost: VolumeBoostLevel = .off
    static let skipForwardSeconds = 30
    static let skipBackSeconds = 15
    static let wifiOnlyDownloads = true
    static let downloadCompletionNotifications = false
    /// Auto-delete downloads after played is OFF by default: it destroys files,
    /// so it must be an explicit opt-in.
    static let deleteDownloadAfterPlayed = false
    /// Auto-download queued episodes is ON by default so queued episodes are
    /// playable offline out of the box; the Wi-Fi-only gate still applies.
    static let autoDownloadQueued = true
    static let directTouchEnabled = false  // retained; not read by SettingsStore (#610)
    /// Chapter navigation buttons shown by default; users who prefer the artwork
    /// VoiceOver rotor can turn them off (#515).
    static let chapterNavButtonsVisible = true
    static let hapticFeedbackEnabled = true
    static let inboxOptInOnly = false
    /// The Queue starts ungrouped (a flat play-order list) until the user picks a
    /// grouping mode (#762). Replaces the old `groupQueueEpisodes = false` bool;
    /// the legacy stored value is migrated in ``AppSettingsStore/queueGrouping()``.
    static let queueGrouping: QueueGrouping = .none
    /// Season/episode numbering in rows is OFF by default: most feeds don't set
    /// these, and users who don't care shouldn't have it read out (#452).
    static let showEpisodeNumbers = false
    /// Playing an episode opens the full player by default (#562); users who
    /// prefer to keep browsing can turn it off and use the mini player.
    static let openPlayerOnPlay = true
    /// Keep the full player open unless the listener explicitly opts into
    /// dismissal after a natural completion that stops playback (#718).
    static let dismissPlayerWhenPlaybackEnds = false
    // Auto-advance defaults true: preserves today's unconditional auto-advance
    // until the user opts to stop at a boundary (#446).
    static let continueAfterEpisode = true
    static let continueAfterGroupEnds = true
    static let onboardingComplete = false
    static let launchScreen: LaunchScreen = .inbox
    static let librarySortOrder: LibrarySortOrder = .alphabetical
    /// Episode-list order default: newest published first, preserving the
    /// pre-existing pubDate-descending order (#459).
    static let episodeSortOrder: EpisodeSortOrder = .latestFirst
    /// Per-podcast episode-list filter default: hide played episodes (#489).
    static let episodeListFilter: EpisodeListFilter = .unheard
    /// Downloads-screen played filter default: show everything (#641). Unlike a
    /// per-podcast episode list, hiding played downloads is opt-in so the user is
    /// never surprised by files they downloaded disappearing after playback.
    static let downloadsPlayedFilter: EpisodeListFilter = .all
    // Appearance defaults (#461): follow the system everywhere until the user
    // explicitly overrides.
    static let themeOverride: ThemeOverride = .followSystem
    static let accentColor: AccentChoice = .systemDefault
    static let layoutDensity: LayoutDensity = .comfortable
    static let statsStreaksEnabled = false
    /// Fresh-install default. Existing onboarded installations are seeded with
    /// ``TranscriptExportMetadata/speakersAndTimestamps`` by ``SettingsStore``.
    static let transcriptExportMetadata: TranscriptExportMetadata = .speakersOnly
    /// Default number of most-recent episodes seeded into the inbox when a new
    /// podcast is added. Matches Flutter's default of 3.
    static let inboxDefaultCount = 3
    /// Sentinel stored under ``SettingsKey/inboxDefaultCount`` meaning "seed the
    /// entire backlog" (no cap). Distinct from 0, which seeds nothing.
    static let inboxDefaultCountAll = -1
    static let podcastCapGatingIntroduced = false
    static let grandfatheredPodcastCount = 0
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
        if AppSettingScope.isLocal(key) {
            return LocalAppSettingIdentity.value(for: key, in: context)
                ?? AppSettingIdentity.value(for: key, in: context)
        }
        return AppSettingIdentity.value(for: key, in: context)
    }

    func setRawValue(_ value: String, for key: String) {
        do {
            if AppSettingScope.isLocal(key) {
                try LocalAppSettingIdentity.setValue(value, for: key, in: context)
            } else {
                try AppSettingIdentity.setValue(value, for: key, in: context)
            }
            save()
            if AppSettingScope.isMirrored(key) {
                NotificationCenter.default.post(
                    name: .earshotMirroredSettingDidChange,
                    object: AppSettingIdentity.canonicalKey(key)
                )
            }
            if AppSettingIdentity.canonicalKey(key) == SettingsKey.volumeBoost {
                NotificationCenter.default.post(
                    name: .earshotVolumeBoostSettingDidChange,
                    object: nil
                )
            }
            if AppSettingIdentity.canonicalKey(key) == SettingsKey.skipSilenceEnabled {
                NotificationCenter.default.post(
                    name: .earshotSkipSilenceSettingDidChange,
                    object: nil
                )
            }
        } catch {
            AppLog.data.error(
                "Setting write failed for \(key, privacy: .private): \(error.localizedDescription, privacy: .public)"
            )
        }
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

    func volumeBoost() -> VolumeBoostLevel {
        guard let raw = rawValue(SettingsKey.volumeBoost),
              let level = VolumeBoostLevel(rawValue: raw) else {
            return SettingsDefault.volumeBoost
        }
        return level
    }

    func setVolumeBoost(_ level: VolumeBoostLevel) {
        setRawValue(level.rawValue, for: SettingsKey.volumeBoost)
    }

    func transcriptExportMetadata(default fallback: TranscriptExportMetadata) -> TranscriptExportMetadata {
        guard let raw = rawValue(SettingsKey.transcriptExportMetadata),
              let metadata = TranscriptExportMetadata(rawValue: raw) else {
            return fallback
        }
        return metadata
    }

    func setTranscriptExportMetadata(_ metadata: TranscriptExportMetadata) {
        setRawValue(metadata.rawValue, for: SettingsKey.transcriptExportMetadata)
    }

    /// Writes the launch-specific default exactly once. An invalid legacy value
    /// is repaired to the supplied default instead of remaining ambiguous.
    func initializeTranscriptExportMetadataIfNeeded(
        default fallback: TranscriptExportMetadata
    ) -> TranscriptExportMetadata {
        if let raw = rawValue(SettingsKey.transcriptExportMetadata),
           let metadata = TranscriptExportMetadata(rawValue: raw) {
            return metadata
        }
        setTranscriptExportMetadata(fallback)
        return fallback
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

    /// The episode-list sort order, defaulting to
    /// ``SettingsDefault/episodeSortOrder`` (.latestFirst) when unset or
    /// unparseable (#459).
    func episodeSortOrder() -> EpisodeSortOrder {
        guard let raw = rawValue(SettingsKey.episodeSortOrder),
              let order = EpisodeSortOrder(rawValue: raw)
        else { return SettingsDefault.episodeSortOrder }
        return order
    }

    func setEpisodeSortOrder(_ order: EpisodeSortOrder) {
        setRawValue(order.rawValue, for: SettingsKey.episodeSortOrder)
    }

    // MARK: Queue grouping (#762)

    /// The Queue's grouping mode, migrating the legacy boolean value stored under
    /// the same key. The setting shipped as a "Group by podcast" bool (#444);
    /// existing stores hold `"true"` / `"false"`, which map to
    /// ``QueueGrouping/podcast`` / ``QueueGrouping/none`` so a user who had
    /// grouping on is not silently reset. A ``QueueGrouping`` raw value (written
    /// by ``setQueueGrouping(_:)`` once the user touches the new three-way
    /// control) parses directly and takes precedence. An unset key returns the
    /// default (``SettingsDefault/queueGrouping``, `.none`).
    func queueGrouping() -> QueueGrouping {
        guard let raw = rawValue(SettingsKey.groupQueueEpisodes) else {
            return SettingsDefault.queueGrouping
        }
        if let mode = QueueGrouping(rawValue: raw) { return mode }
        // Legacy bool: only the exact "true" grouped the queue (by podcast);
        // every other legacy value ("false") means no grouping.
        return (raw as NSString).boolValue ? .podcast : .none
    }

    func setQueueGrouping(_ mode: QueueGrouping) {
        setRawValue(mode.rawValue, for: SettingsKey.groupQueueEpisodes)
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

    /// The global Downloads-screen played filter, defaulting to
    /// ``SettingsDefault/downloadsPlayedFilter`` (.all) when unset or unparseable
    /// (#641). Cross-podcast, so a single scalar key rather than per-feed.
    func downloadsPlayedFilter() -> EpisodeListFilter {
        guard let raw = rawValue(SettingsKey.downloadsPlayedFilter),
              let filter = EpisodeListFilter(rawValue: raw)
        else { return SettingsDefault.downloadsPlayedFilter }
        return filter
    }

    func setDownloadsPlayedFilter(_ filter: EpisodeListFilter) {
        setRawValue(filter.rawValue, for: SettingsKey.downloadsPlayedFilter)
    }

    /// The saved per-podcast inbox episode limit for this feed URL, or nil when
    /// the user never set one, explicitly chose "No limit" (stored as the
    /// `"null"` sentinel), or the stored value doesn't parse to a positive Int
    /// (bad values are ignored defensively) (#548).
    func podcastInboxCap(forFeedURL feedURL: String) -> Int? {
        guard let cap = optionalInt(SettingsKey.podcastInboxCap(feedURL: feedURL)),
              cap > 0
        else { return nil }
        return cap
    }

    /// Persists the per-podcast inbox limit outside the model, keyed by feed
    /// URL, so it can be restored onto the fresh `Podcast` a re-subscribe
    /// creates (#548). `nil` (an explicit "No limit") stores the `"null"`
    /// sentinel rather than deleting the row, so choosing "No limit" can't be
    /// shadowed by an older saved cap on a future re-subscribe.
    func setPodcastInboxCap(_ cap: Int?, forFeedURL feedURL: String) {
        setOptionalInt(cap, for: SettingsKey.podcastInboxCap(feedURL: feedURL))
    }

    func episodeFilterConfiguration(forFeedURL feedURL: String) -> EpisodeFilterConfiguration {
        EpisodeFilterCodec.decode(
            rawValue(SettingsKey.episodeFilterConfiguration(feedURL: feedURL))
        )
    }

    func setEpisodeFilterConfiguration(
        _ configuration: EpisodeFilterConfiguration,
        forFeedURL feedURL: String
    ) throws {
        let key = SettingsKey.episodeFilterConfiguration(feedURL: feedURL)
        let value = try EpisodeFilterCodec.encode(configuration)
        do {
            try AppSettingIdentity.setValue(value, for: key, in: context)
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        NotificationCenter.default.post(
            name: .earshotMirroredSettingDidChange,
            object: AppSettingIdentity.canonicalKey(key)
        )
    }

    func episodeFilterSafetyWarning(forFeedURL feedURL: String) -> String? {
        rawValue(SettingsKey.episodeFilterSafetyWarning(feedURL: feedURL))
    }

    func episodeFilterNeedsReview(forFeedURL feedURL: String) -> Bool {
        episodeFilterSafetyWarning(forFeedURL: feedURL)?.isEmpty == false
    }

    func clearEpisodeFilterSafetyWarning(forFeedURL feedURL: String) {
        setRawValue("", for: SettingsKey.episodeFilterSafetyWarning(feedURL: feedURL))
    }

    // MARK: Podcast cap grandfathering (#635)

    func podcastCapGatingIntroduced() -> Bool {
        bool(SettingsKey.podcastCapGatingIntroduced, default: SettingsDefault.podcastCapGatingIntroduced)
    }

    func grandfatheredPodcastCount() -> Int {
        int(SettingsKey.grandfatheredPodcastCount, default: SettingsDefault.grandfatheredPodcastCount)
    }

    /// One-time: if gating hasn't been introduced yet on this install, snapshot
    /// the current podcast count as the grandfathered allowance and mark gating
    /// introduced. Idempotent — a second call is a no-op. Call from RootView's
    /// launch `.task`, before any subscribe action can occur.
    func introducePodcastCapGatingIfNeeded(currentPodcastCount: Int) {
        guard !podcastCapGatingIntroduced() else { return }
        do {
            try AppSettingIdentity.setValue(
                String(currentPodcastCount),
                for: SettingsKey.grandfatheredPodcastCount,
                in: context
            )
            try AppSettingIdentity.setValue(
                "true",
                for: SettingsKey.podcastCapGatingIntroduced,
                in: context
            )
            try context.save()
            NotificationCenter.default.post(
                name: .earshotMirroredSettingDidChange,
                object: SettingsKey.grandfatheredPodcastCount
            )
            NotificationCenter.default.post(
                name: .earshotMirroredSettingDidChange,
                object: SettingsKey.podcastCapGatingIntroduced
            )
        } catch {
            AppLog.data.error(
                "Podcast cap initialization failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func save() {
        do {
            try context.save()
        } catch {
            AppLog.data.error("Failed to save setting: \(error.localizedDescription, privacy: .public)")
        }
    }
}
