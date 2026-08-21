import Foundation
import Observation
import SwiftData

/// Bindable wrapper over ``AppSettingsStore`` for the Settings UI. Holds the
/// documented preferences as observed properties (so SwiftUI controls bind
/// directly) and persists each change to SwiftData. Serves defaults until
/// ``configure(context:)`` runs.
@MainActor
@Observable
final class SettingsStore {
    // Playback
    var globalSpeed: Double = SettingsDefault.globalSpeed { didSet { persist { $0.setDouble(globalSpeed, for: SettingsKey.globalSpeed) } } }
    var skipForwardSeconds: Int = SettingsDefault.skipForwardSeconds { didSet { persist { $0.setInt(skipForwardSeconds, for: SettingsKey.skipForwardSeconds) } } }
    var skipBackSeconds: Int = SettingsDefault.skipBackSeconds { didSet { persist { $0.setInt(skipBackSeconds, for: SettingsKey.skipBackSeconds) } } }
    var voiceEnhanceEnabled = false { didSet { persist { $0.setBool(voiceEnhanceEnabled, for: SettingsKey.voiceEnhanceEnabled) } } }
    var continueAfterEpisode: Bool = SettingsDefault.continueAfterEpisode { didSet { persist { $0.setBool(continueAfterEpisode, for: SettingsKey.continueAfterEpisode) } } }
    var continueAfterGroupEnds: Bool = SettingsDefault.continueAfterGroupEnds { didSet { persist { $0.setBool(continueAfterGroupEnds, for: SettingsKey.continueAfterGroupEnds) } } }
    var chapterNavButtonsVisible: Bool = SettingsDefault.chapterNavButtonsVisible { didSet { persist { $0.setBool(chapterNavButtonsVisible, for: SettingsKey.chapterNavButtonsVisible) } } }

    // General
    var launchScreen: LaunchScreen = SettingsDefault.launchScreen { didSet { persist { $0.setLaunchScreen(launchScreen) } } }
    var librarySortOrder: LibrarySortOrder = SettingsDefault.librarySortOrder { didSet { persist { $0.setLibrarySortOrder(librarySortOrder) } } }
    var episodeSortOrder: EpisodeSortOrder = SettingsDefault.episodeSortOrder { didSet { persist { $0.setEpisodeSortOrder(episodeSortOrder) } } }
    var queueGrouping: QueueGrouping = SettingsDefault.queueGrouping { didSet { persist { $0.setQueueGrouping(queueGrouping) } } }
    var showEpisodeNumbers: Bool = SettingsDefault.showEpisodeNumbers { didSet { persist { $0.setBool(showEpisodeNumbers, for: SettingsKey.showEpisodeNumbers) } } }
    var openPlayerOnPlay: Bool = SettingsDefault.openPlayerOnPlay { didSet { persist { $0.setBool(openPlayerOnPlay, for: SettingsKey.openPlayerOnPlay) } } }

    // Device-local VoiceOver verbosity. These keys are deliberately absent from
    // AppSettingScope.mirroredKeys so another device cannot change row speech.
    var spokenEpisodePodcastName = true { didSet { persist { $0.setBool(spokenEpisodePodcastName, for: SettingsKey.spokenEpisodePodcastName) } } }
    var spokenEpisodePublishedDate = true { didSet { persist { $0.setBool(spokenEpisodePublishedDate, for: SettingsKey.spokenEpisodePublishedDate) } } }
    var spokenEpisodeDownloadStatus = true { didSet { persist { $0.setBool(spokenEpisodeDownloadStatus, for: SettingsKey.spokenEpisodeDownloadStatus) } } }
    var spokenEpisodeDuration = true { didSet { persist { $0.setBool(spokenEpisodeDuration, for: SettingsKey.spokenEpisodeDuration) } } }
    var spokenEpisodeDescriptionMode: SpokenDescriptionMode = .brief { didSet { persist { $0.setRawValue(spokenEpisodeDescriptionMode.rawValue, for: SettingsKey.spokenEpisodeDescriptionMode) } } }
    var spokenPodcastDescriptionMode: SpokenDescriptionMode = .brief { didSet { persist { $0.setRawValue(spokenPodcastDescriptionMode.rawValue, for: SettingsKey.spokenPodcastDescriptionMode) } } }

    var episodeSpokenDetails: EpisodeSpokenDetails {
        EpisodeSpokenDetails(
            includesPodcastName: spokenEpisodePodcastName,
            includesPublishedDate: spokenEpisodePublishedDate,
            includesDownloadStatus: spokenEpisodeDownloadStatus,
            includesDuration: spokenEpisodeDuration,
            descriptionMode: spokenEpisodeDescriptionMode
        )
    }

    // Appearance (#461)
    var themeOverride: ThemeOverride = SettingsDefault.themeOverride { didSet { persist { $0.setThemeOverride(themeOverride) } } }
    var accentColor: AccentChoice = SettingsDefault.accentColor { didSet { persist { $0.setAccentChoice(accentColor) } } }
    var layoutDensity: LayoutDensity = SettingsDefault.layoutDensity { didSet { persist { $0.setLayoutDensity(layoutDensity) } } }

    // Inbox
    var inboxOptInOnly: Bool = SettingsDefault.inboxOptInOnly { didSet { persist { $0.setBool(inboxOptInOnly, for: SettingsKey.inboxOptInOnly) } } }
    /// Number of most-recent episodes seeded into the inbox when a new podcast is
    /// added. 0 = none; ``SettingsDefault/inboxDefaultCountAll`` (-1) = all.
    var inboxDefaultCount: Int = SettingsDefault.inboxDefaultCount { didSet { persist { $0.setInt(inboxDefaultCount, for: SettingsKey.inboxDefaultCount) } } }

    // Downloads
    var wifiOnlyDownloads: Bool = SettingsDefault.wifiOnlyDownloads { didSet { persist { $0.setBool(wifiOnlyDownloads, for: SettingsKey.wifiOnlyDownloads) } } }
    var deleteDownloadAfterPlayed: Bool = SettingsDefault.deleteDownloadAfterPlayed { didSet { persist { $0.setBool(deleteDownloadAfterPlayed, for: SettingsKey.deleteDownloadAfterPlayed) } } }
    var autoDownloadQueued: Bool = SettingsDefault.autoDownloadQueued { didSet { persist { $0.setBool(autoDownloadQueued, for: SettingsKey.autoDownloadQueued) } } }
    var autoDownloadCount: Int = SettingsDefault.autoDownloadCount { didSet { persist { $0.setInt(autoDownloadCount, for: SettingsKey.autoDownloadCount) } } }
    var historyRetentionDays: Int = SettingsDefault.historyRetentionDays { didSet { persist { $0.setInt(historyRetentionDays, for: SettingsKey.historyRetentionDays) } } }

    // Stats
    var statsStreaksEnabled: Bool = SettingsDefault.statsStreaksEnabled { didSet { persist { $0.setBool(statsStreaksEnabled, for: SettingsKey.statsStreaksEnabled) } } }

    // Onboarding
    var onboardingComplete: Bool = SettingsDefault.onboardingComplete { didSet { persist { $0.setBool(onboardingComplete, for: SettingsKey.onboardingComplete) } } }

    @ObservationIgnored private var store: AppSettingsStore?
    /// Whether ``configure(context:)`` has loaded persisted values. Readable so
    /// RootView can serve the persisted appearance synchronously on the first
    /// launch frames (no default-theme flash) until the load lands (#461,
    /// mirrors the #492 launch-tab pattern).
    @ObservationIgnored private(set) var loaded = false

    func configure(context: ModelContext) {
        let store = AppSettingsStore(context: context)
        self.store = store
        loaded = false
        globalSpeed = store.double(SettingsKey.globalSpeed, default: SettingsDefault.globalSpeed)
        skipForwardSeconds = store.int(SettingsKey.skipForwardSeconds, default: SettingsDefault.skipForwardSeconds)
        skipBackSeconds = store.int(SettingsKey.skipBackSeconds, default: SettingsDefault.skipBackSeconds)
        voiceEnhanceEnabled = store.bool(SettingsKey.voiceEnhanceEnabled, default: false)
        continueAfterEpisode = store.bool(SettingsKey.continueAfterEpisode, default: SettingsDefault.continueAfterEpisode)
        continueAfterGroupEnds = store.bool(SettingsKey.continueAfterGroupEnds, default: SettingsDefault.continueAfterGroupEnds)
        chapterNavButtonsVisible = store.bool(SettingsKey.chapterNavButtonsVisible, default: SettingsDefault.chapterNavButtonsVisible)
        launchScreen = store.launchScreen()
        librarySortOrder = store.librarySortOrder()
        episodeSortOrder = store.episodeSortOrder()
        queueGrouping = store.queueGrouping()
        showEpisodeNumbers = store.bool(SettingsKey.showEpisodeNumbers, default: SettingsDefault.showEpisodeNumbers)
        openPlayerOnPlay = store.bool(SettingsKey.openPlayerOnPlay, default: SettingsDefault.openPlayerOnPlay)
        spokenEpisodePodcastName = store.bool(SettingsKey.spokenEpisodePodcastName, default: true)
        spokenEpisodePublishedDate = store.bool(SettingsKey.spokenEpisodePublishedDate, default: true)
        spokenEpisodeDownloadStatus = store.bool(SettingsKey.spokenEpisodeDownloadStatus, default: true)
        spokenEpisodeDuration = store.bool(SettingsKey.spokenEpisodeDuration, default: true)
        spokenEpisodeDescriptionMode = SpokenDescriptionMode(
            rawValue: store.rawValue(SettingsKey.spokenEpisodeDescriptionMode) ?? ""
        ) ?? .brief
        spokenPodcastDescriptionMode = SpokenDescriptionMode(
            rawValue: store.rawValue(SettingsKey.spokenPodcastDescriptionMode) ?? ""
        ) ?? .brief
        themeOverride = store.themeOverride()
        accentColor = store.accentChoice()
        layoutDensity = store.layoutDensity()
        inboxOptInOnly = store.bool(SettingsKey.inboxOptInOnly, default: SettingsDefault.inboxOptInOnly)
        inboxDefaultCount = store.inboxDefaultCount()
        wifiOnlyDownloads = store.bool(SettingsKey.wifiOnlyDownloads, default: SettingsDefault.wifiOnlyDownloads)
        deleteDownloadAfterPlayed = store.bool(SettingsKey.deleteDownloadAfterPlayed, default: SettingsDefault.deleteDownloadAfterPlayed)
        autoDownloadQueued = store.bool(SettingsKey.autoDownloadQueued, default: SettingsDefault.autoDownloadQueued)
        autoDownloadCount = store.int(SettingsKey.autoDownloadCount, default: SettingsDefault.autoDownloadCount)
        historyRetentionDays = store.int(SettingsKey.historyRetentionDays, default: SettingsDefault.historyRetentionDays)
        statsStreaksEnabled = store.bool(SettingsKey.statsStreaksEnabled, default: SettingsDefault.statsStreaksEnabled)
        onboardingComplete = store.bool(SettingsKey.onboardingComplete, default: SettingsDefault.onboardingComplete)
        loaded = true
    }

    func releasePersistence() { store = nil; loaded = false }

    private func persist(_ apply: (AppSettingsStore) -> Void) {
        guard loaded, let store else { return }
        apply(store)
    }
}
