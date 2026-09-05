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
    var volumeBoost: VolumeBoostLevel = SettingsDefault.volumeBoost { didSet { persist { $0.setVolumeBoost(volumeBoost) } } }
    var skipSilenceEnabled: Bool = SettingsDefault.skipSilenceEnabled { didSet { persist { $0.setBool(skipSilenceEnabled, for: SettingsKey.skipSilenceEnabled) } } }
    var skipForwardSeconds: Int = SettingsDefault.skipForwardSeconds { didSet { persist { $0.setInt(skipForwardSeconds, for: SettingsKey.skipForwardSeconds) } } }
    var skipBackSeconds: Int = SettingsDefault.skipBackSeconds { didSet { persist { $0.setInt(skipBackSeconds, for: SettingsKey.skipBackSeconds) } } }
    var wrapQueue: Bool = SettingsDefault.wrapQueue { didSet { persist { $0.setBool(wrapQueue, for: SettingsKey.wrapQueue) } } }
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
    var dismissPlayerWhenPlaybackEnds: Bool = SettingsDefault.dismissPlayerWhenPlaybackEnds { didSet { persist { $0.setBool(dismissPlayerWhenPlaybackEnds, for: SettingsKey.dismissPlayerWhenPlaybackEnds) } } }

    // Device-local VoiceOver verbosity. These keys are deliberately absent from
    // AppSettingScope.mirroredKeys so another device cannot change row speech.
    var spokenEpisodePodcastName = true { didSet { persist { $0.setBool(spokenEpisodePodcastName, for: SettingsKey.spokenEpisodePodcastName) } } }
    var spokenEpisodePublishedDate = true { didSet { persist { $0.setBool(spokenEpisodePublishedDate, for: SettingsKey.spokenEpisodePublishedDate) } } }
    var spokenEpisodeDownloadStatus = true { didSet { persist { $0.setBool(spokenEpisodeDownloadStatus, for: SettingsKey.spokenEpisodeDownloadStatus) } } }
    var spokenEpisodeDuration = true { didSet { persist { $0.setBool(spokenEpisodeDuration, for: SettingsKey.spokenEpisodeDuration) } } }
    var spokenEpisodeDescriptionMode: SpokenDescriptionMode = .brief { didSet { persist { $0.setRawValue(spokenEpisodeDescriptionMode.rawValue, for: SettingsKey.spokenEpisodeDescriptionMode) } } }
    var spokenPodcastDescriptionMode: SpokenDescriptionMode = .brief { didSet { persist { $0.setRawValue(spokenPodcastDescriptionMode.rawValue, for: SettingsKey.spokenPodcastDescriptionMode) } } }
    var hapticFeedbackEnabled: Bool = SettingsDefault.hapticFeedbackEnabled { didSet { persist { $0.setBool(hapticFeedbackEnabled, for: SettingsKey.hapticFeedbackEnabled) } } }
    var transcriptExportMetadata: TranscriptExportMetadata = SettingsDefault.transcriptExportMetadata { didSet { persist { $0.setTranscriptExportMetadata(transcriptExportMetadata) } } }

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
    var downloadCompletionNotifications: Bool = SettingsDefault.downloadCompletionNotifications { didSet { persist { $0.setBool(downloadCompletionNotifications, for: SettingsKey.downloadCompletionNotifications) } } }
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
        // Before #900, every export included both metadata fields. A completed
        // onboarding is the durable evidence that this is an existing usable
        // installation; a genuinely new store has not completed it yet.
        let wasExistingInstallation = store.bool(
            SettingsKey.onboardingComplete,
            default: SettingsDefault.onboardingComplete
        )
        assignIfChanged(\.globalSpeed, store.double(SettingsKey.globalSpeed, default: SettingsDefault.globalSpeed))
        assignIfChanged(\.volumeBoost, store.volumeBoost())
        assignIfChanged(\.skipSilenceEnabled, store.bool(SettingsKey.skipSilenceEnabled, default: SettingsDefault.skipSilenceEnabled))
        assignIfChanged(\.skipForwardSeconds, store.int(SettingsKey.skipForwardSeconds, default: SettingsDefault.skipForwardSeconds))
        assignIfChanged(\.skipBackSeconds, store.int(SettingsKey.skipBackSeconds, default: SettingsDefault.skipBackSeconds))
        assignIfChanged(\.wrapQueue, store.bool(SettingsKey.wrapQueue, default: SettingsDefault.wrapQueue))
        assignIfChanged(\.continueAfterEpisode, store.bool(SettingsKey.continueAfterEpisode, default: SettingsDefault.continueAfterEpisode))
        assignIfChanged(\.continueAfterGroupEnds, store.bool(SettingsKey.continueAfterGroupEnds, default: SettingsDefault.continueAfterGroupEnds))
        assignIfChanged(\.chapterNavButtonsVisible, store.bool(SettingsKey.chapterNavButtonsVisible, default: SettingsDefault.chapterNavButtonsVisible))
        assignIfChanged(\.launchScreen, store.launchScreen())
        assignIfChanged(\.librarySortOrder, store.librarySortOrder())
        assignIfChanged(\.episodeSortOrder, store.episodeSortOrder())
        assignIfChanged(\.queueGrouping, store.queueGrouping())
        assignIfChanged(\.showEpisodeNumbers, store.bool(SettingsKey.showEpisodeNumbers, default: SettingsDefault.showEpisodeNumbers))
        assignIfChanged(\.openPlayerOnPlay, store.bool(SettingsKey.openPlayerOnPlay, default: SettingsDefault.openPlayerOnPlay))
        assignIfChanged(\.dismissPlayerWhenPlaybackEnds, store.bool(
            SettingsKey.dismissPlayerWhenPlaybackEnds,
            default: SettingsDefault.dismissPlayerWhenPlaybackEnds
        ))
        assignIfChanged(\.spokenEpisodePodcastName, store.bool(SettingsKey.spokenEpisodePodcastName, default: true))
        assignIfChanged(\.spokenEpisodePublishedDate, store.bool(SettingsKey.spokenEpisodePublishedDate, default: true))
        assignIfChanged(\.spokenEpisodeDownloadStatus, store.bool(SettingsKey.spokenEpisodeDownloadStatus, default: true))
        assignIfChanged(\.spokenEpisodeDuration, store.bool(SettingsKey.spokenEpisodeDuration, default: true))
        assignIfChanged(\.spokenEpisodeDescriptionMode, SpokenDescriptionMode(
            rawValue: store.rawValue(SettingsKey.spokenEpisodeDescriptionMode) ?? ""
        ) ?? .brief)
        assignIfChanged(\.spokenPodcastDescriptionMode, SpokenDescriptionMode(
            rawValue: store.rawValue(SettingsKey.spokenPodcastDescriptionMode) ?? ""
        ) ?? .brief)
        assignIfChanged(\.hapticFeedbackEnabled, store.bool(
            SettingsKey.hapticFeedbackEnabled,
            default: SettingsDefault.hapticFeedbackEnabled
        ))
        assignIfChanged(\.transcriptExportMetadata, store.initializeTranscriptExportMetadataIfNeeded(
            default: wasExistingInstallation ? .speakersAndTimestamps : .speakersOnly
        ))
        assignIfChanged(\.themeOverride, store.themeOverride())
        assignIfChanged(\.accentColor, store.accentChoice())
        assignIfChanged(\.layoutDensity, store.layoutDensity())
        assignIfChanged(\.inboxOptInOnly, store.bool(SettingsKey.inboxOptInOnly, default: SettingsDefault.inboxOptInOnly))
        assignIfChanged(\.inboxDefaultCount, store.inboxDefaultCount())
        assignIfChanged(\.wifiOnlyDownloads, store.bool(SettingsKey.wifiOnlyDownloads, default: SettingsDefault.wifiOnlyDownloads))
        assignIfChanged(\.downloadCompletionNotifications, store.bool(
            SettingsKey.downloadCompletionNotifications,
            default: SettingsDefault.downloadCompletionNotifications
        ))
        assignIfChanged(\.deleteDownloadAfterPlayed, store.bool(SettingsKey.deleteDownloadAfterPlayed, default: SettingsDefault.deleteDownloadAfterPlayed))
        assignIfChanged(\.autoDownloadQueued, store.bool(SettingsKey.autoDownloadQueued, default: SettingsDefault.autoDownloadQueued))
        assignIfChanged(\.autoDownloadCount, store.int(SettingsKey.autoDownloadCount, default: SettingsDefault.autoDownloadCount))
        assignIfChanged(\.historyRetentionDays, store.int(SettingsKey.historyRetentionDays, default: SettingsDefault.historyRetentionDays))
        assignIfChanged(\.statsStreaksEnabled, store.bool(SettingsKey.statsStreaksEnabled, default: SettingsDefault.statsStreaksEnabled))
        assignIfChanged(\.onboardingComplete, store.bool(SettingsKey.onboardingComplete, default: SettingsDefault.onboardingComplete))
        loaded = true
    }

    /// Observation invalidates SwiftUI even when an observable property is
    /// assigned its current value. A CloudKit pass used to reassign every
    /// setting after any projected model changed, repeatedly rebuilding the
    /// Settings accessibility tree while VoiceOver was finding its next item.
    private func assignIfChanged<Value: Equatable>(
        _ keyPath: ReferenceWritableKeyPath<SettingsStore, Value>,
        _ value: Value
    ) {
        guard self[keyPath: keyPath] != value else { return }
        self[keyPath: keyPath] = value
    }

    func releasePersistence() { store = nil; loaded = false }

    private func persist(_ apply: (AppSettingsStore) -> Void) {
        guard loaded, let store else { return }
        apply(store)
    }
}
