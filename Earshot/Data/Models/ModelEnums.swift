import Foundation

/// Lifecycle state of an episode. Mirrors the Flutter drift `EpisodeStatus`
/// enum; stored by SwiftData as its String raw value (`.name` in Flutter).
enum EpisodeStatus: String, Codable, CaseIterable {
    case newEpisode
    case inQueue
    case played
    case expired
}

/// Download state of an episode's audio. Mirrors the Flutter drift
/// `DownloadStatus`; stored as its String raw value.
enum DownloadStatus: String, Codable, CaseIterable {
    case none
    case pending
    case downloading
    case downloaded
    case failed
}

/// Listener-selected gain applied before Earshot's soft limiter. The raw value
/// is stable persistence; `nil` at the episode level means "use global".
enum VolumeBoostLevel: String, Codable, CaseIterable, Identifiable, Sendable {
    case off
    case low
    case medium
    case high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Off"
        case .low: return "Low (+3 dB)"
        case .medium: return "Medium (+6 dB)"
        case .high: return "High (+9 dB)"
        }
    }

    var spokenValue: String {
        switch self {
        case .off: return "off"
        case .low: return "low, plus 3 decibels"
        case .medium: return "medium, plus 6 decibels"
        case .high: return "high, plus 9 decibels"
        }
    }

    var gain: Float {
        switch self {
        case .off: return 1
        case .low: return pow(10, 3 / 20)
        case .medium: return pow(10, 6 / 20)
        case .high: return pow(10, 9 / 20)
        }
    }

    var processingConfiguration: AudioGainLimiterConfiguration {
        AudioGainLimiterConfiguration(gain: gain)
    }
}

/// Which Quick Action set a configuration row belongs to. Mirrors the Flutter
/// drift `QuickActionContentType`; stored as its String raw value.
enum QuickActionContentType: String, Codable, CaseIterable {
    case episode
    case podcast
    case queueItem
}

/// The screen Earshot opens to on launch. Mirrors the Flutter `LaunchScreen`.
enum LaunchScreen: String, Codable, CaseIterable {
    case inbox
    case queue
    case library
    case downloads
}

/// How the Library list is ordered. Persisted as a String raw value under
/// ``SettingsKey/librarySortOrder``; defaults to ``alphabetical``.
enum LibrarySortOrder: String, Codable, CaseIterable, Identifiable {
    /// A→Z by title, ignoring a leading article (see ``LibrarySort``).
    case alphabetical
    /// Most recently published episode first (most active feed at the top).
    case lastPublished

    var id: String { rawValue }

    /// User-facing label for the sort menu.
    var title: String {
        switch self {
        case .alphabetical: return "Alphabetical"
        case .lastPublished: return "Last published"
        }
    }
}
