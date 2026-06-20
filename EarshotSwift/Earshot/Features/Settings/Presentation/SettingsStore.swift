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
    var skipSilenceEnabled: Bool = SettingsDefault.skipSilenceEnabled { didSet { persist { $0.setBool(skipSilenceEnabled, for: SettingsKey.skipSilenceEnabled) } } }
    var voiceEnhanceEnabled = false { didSet { persist { $0.setBool(voiceEnhanceEnabled, for: SettingsKey.voiceEnhanceEnabled) } } }

    // General
    var launchScreen: LaunchScreen = SettingsDefault.launchScreen { didSet { persist { $0.setLaunchScreen(launchScreen) } } }
    var groupQueueEpisodes: Bool = SettingsDefault.groupQueueEpisodes { didSet { persist { $0.setBool(groupQueueEpisodes, for: SettingsKey.groupQueueEpisodes) } } }

    // Inbox
    var inboxOptInOnly: Bool = SettingsDefault.inboxOptInOnly { didSet { persist { $0.setBool(inboxOptInOnly, for: SettingsKey.inboxOptInOnly) } } }

    // Downloads
    var wifiOnlyDownloads: Bool = SettingsDefault.wifiOnlyDownloads { didSet { persist { $0.setBool(wifiOnlyDownloads, for: SettingsKey.wifiOnlyDownloads) } } }
    var autoDownloadCount: Int = SettingsDefault.autoDownloadCount { didSet { persist { $0.setInt(autoDownloadCount, for: SettingsKey.autoDownloadCount) } } }
    var historyRetentionDays: Int = SettingsDefault.historyRetentionDays { didSet { persist { $0.setInt(historyRetentionDays, for: SettingsKey.historyRetentionDays) } } }

    // Privacy
    var crashReportingEnabled: Bool = SettingsDefault.crashReportingEnabled { didSet { persist { $0.setBool(crashReportingEnabled, for: SettingsKey.crashReportingEnabled) } } }
    var analyticsEnabled: Bool = SettingsDefault.analyticsEnabled { didSet { persist { $0.setBool(analyticsEnabled, for: SettingsKey.analyticsEnabled) } } }

    // Stats
    var statsStreaksEnabled: Bool = SettingsDefault.statsStreaksEnabled { didSet { persist { $0.setBool(statsStreaksEnabled, for: SettingsKey.statsStreaksEnabled) } } }

    // Accessibility
    var directTouchEnabled: Bool = SettingsDefault.directTouchEnabled { didSet { persist { $0.setBool(directTouchEnabled, for: SettingsKey.directTouchEnabled) } } }

    @ObservationIgnored private var store: AppSettingsStore?
    @ObservationIgnored private var loaded = false

    func configure(context: ModelContext) {
        let store = AppSettingsStore(context: context)
        self.store = store
        loaded = false
        globalSpeed = store.double(SettingsKey.globalSpeed, default: SettingsDefault.globalSpeed)
        skipForwardSeconds = store.int(SettingsKey.skipForwardSeconds, default: SettingsDefault.skipForwardSeconds)
        skipBackSeconds = store.int(SettingsKey.skipBackSeconds, default: SettingsDefault.skipBackSeconds)
        skipSilenceEnabled = store.bool(SettingsKey.skipSilenceEnabled, default: SettingsDefault.skipSilenceEnabled)
        voiceEnhanceEnabled = store.bool(SettingsKey.voiceEnhanceEnabled, default: false)
        launchScreen = store.launchScreen()
        groupQueueEpisodes = store.bool(SettingsKey.groupQueueEpisodes, default: SettingsDefault.groupQueueEpisodes)
        inboxOptInOnly = store.bool(SettingsKey.inboxOptInOnly, default: SettingsDefault.inboxOptInOnly)
        wifiOnlyDownloads = store.bool(SettingsKey.wifiOnlyDownloads, default: SettingsDefault.wifiOnlyDownloads)
        autoDownloadCount = store.int(SettingsKey.autoDownloadCount, default: SettingsDefault.autoDownloadCount)
        historyRetentionDays = store.int(SettingsKey.historyRetentionDays, default: SettingsDefault.historyRetentionDays)
        crashReportingEnabled = store.bool(SettingsKey.crashReportingEnabled, default: SettingsDefault.crashReportingEnabled)
        analyticsEnabled = store.bool(SettingsKey.analyticsEnabled, default: SettingsDefault.analyticsEnabled)
        directTouchEnabled = store.bool(SettingsKey.directTouchEnabled, default: SettingsDefault.directTouchEnabled)
        statsStreaksEnabled = store.bool(SettingsKey.statsStreaksEnabled, default: SettingsDefault.statsStreaksEnabled)
        loaded = true
    }

    private func persist(_ apply: (AppSettingsStore) -> Void) {
        guard loaded, let store else { return }
        apply(store)
    }
}
