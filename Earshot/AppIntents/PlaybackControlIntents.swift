import AppIntents
import Foundation
import SwiftData

/// One configurable action plus dedicated, ready-to-use common actions.
enum ShortcutPlaybackCommand: String, AppEnum {
    case toggle, deferEpisode, volumeBoost, trimSilence
    case pause, nextChapter, previousChapter, clearAndNext, nextEpisode, previousEpisode
    case seek, speed, continuousPlay, sleepTimer, extendSleepTimer, cancelSleepTimer, bookmark
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Playback control")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .toggle: "Play or pause", .deferEpisode: "Move current episode to end and play next",
        .volumeBoost: "Set volume boost", .trimSilence: "Set silence trimming",
        .pause: "Pause", .nextChapter: "Next chapter", .previousChapter: "Previous chapter",
        .clearAndNext: "Clear episode and play next", .nextEpisode: "Next episode",
        .previousEpisode: "Previous episode", .seek: "Seek to position", .speed: "Set playback speed",
        .continuousPlay: "Set continuous play", .sleepTimer: "Set sleep timer",
        .extendSleepTimer: "Extend sleep timer", .cancelSleepTimer: "Cancel sleep timer",
        .bookmark: "Bookmark current position"
    ]
}

enum ShortcutTimer: String, AppEnum {
    case endOfEpisode, fiveMinutes, tenMinutes, fifteenMinutes, thirtyMinutes, fortyFiveMinutes, sixtyMinutes
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Sleep timer")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .endOfEpisode: "End of episode", .fiveMinutes: "5 minutes", .tenMinutes: "10 minutes",
        .fifteenMinutes: "15 minutes", .thirtyMinutes: "30 minutes",
        .fortyFiveMinutes: "45 minutes", .sixtyMinutes: "60 minutes"
    ]
}

struct ShortcutControlError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
extension LibraryPlaybackBridge {
    func control(_ command: ShortcutPlaybackCommand, seconds: Int = 0, speed: Double = 1,
                 enabled: Bool = true, timer: ShortcutTimer = .fifteenMinutes, note: String = "") async throws {
        let runtime = try await preparedRuntime()
        try Self.control(command, runtime: runtime, seconds: seconds, speed: speed,
                         enabled: enabled, timer: timer, note: note)
    }

    static func control(_ command: ShortcutPlaybackCommand, runtime: AppRuntime, seconds: Int = 0,
                        speed: Double = 1, enabled: Bool = true,
                        timer: ShortcutTimer = .fifteenMinutes, note: String = "") throws {
        try Task.checkCancellation()
        guard !runtime.isResettingLocalData, let context = runtime.readyContainer?.mainContext,
              runtime.rootServiceActivationStatus == .completed else { throw LibraryIntentError.notReady }
        let player = runtime.player
        guard let episode = player.nowPlayingEpisode, !episode.isDeleted else { throw LibraryPlaybackError.noEpisode }
        switch command {
        case .toggle:
            if player.hasActivePlaybackRequest { player.pause() } else { player.resume() }
        case .deferEpisode:
            let repo = QueueRepository(context: context)
            guard let next = player.shortcutQueueNeighbor(.next) else {
                throw ShortcutControlError(message: "No next episode in Queue.")
            }
            guard repo.moveToBottom(episode) else { throw ShortcutControlError(message: "Could not move this episode.") }
            player.playWithHandoff(next)
        case .volumeBoost: player.setCurrentVolumeBoostOverride(enabled ? .medium : .off)
        case .trimSilence:
            guard let podcast = episode.podcast else { throw ShortcutControlError(message: "Save this podcast before changing silence trimming.") }
            podcast.trimSilenceOverride = enabled
            try context.save()
            NotificationCenter.default.post(name: .earshotSkipSilenceSettingDidChange, object: podcast.feedURL)
        case .pause: player.pause()
        case .nextChapter, .previousChapter:
            guard player.chapterCount > 0 else {
                throw ShortcutControlError(message: "No chapters are available yet for this episode.")
            }
            if command == .nextChapter {
                guard ChapterNavLogic.nextIndex(
                    currentIndex: player.currentChapterIndex,
                    count: player.chapterCount
                ) != nil else { throw ShortcutControlError(message: "Already at the last chapter.") }
                player.nextChapter()
            } else { player.previousChapter() }
        case .nextEpisode, .previousEpisode, .clearAndNext:
            guard QueueRepository(context: context).queue().contains(where: {
                $0.persistentModelID == episode.persistentModelID
            }) else { throw ShortcutControlError(message: "The current episode is not in Queue.") }
            // These preserve displayed group order, stop/timer rules and download policy.
            // Do not announce unconditional success: the player reports failed saves
            // and unavailable neighbors through its established error path.
            if command != .clearAndNext,
               player.shortcutQueueNeighbor(command == .nextEpisode ? .next : .previous) == nil {
                throw ShortcutControlError(message: "No neighboring episode in Queue.")
            }
            if command == .clearAndNext { player.markCurrentPlayedAndNextInQueue() }
            else if command == .nextEpisode { player.nextInQueue() }
            else { player.previousInQueue() }
        case .seek:
            guard seconds >= 0 else { throw ShortcutControlError(message: "Position must be zero or greater.") }
            player.seek(to: Double(seconds))
        case .speed:
            guard speed.isFinite, (0.5...3).contains(speed) else {
                throw ShortcutControlError(message: "Choose a speed from 0.5 to 3.")
            }
            if episode.podcast != nil { player.setPodcastSpeedOverride(speed, announce: false) }
            else { throw ShortcutControlError(message: "This episode has no saved podcast speed setting.") }
        case .continuousPlay: player.stopAfterCurrentEpisode = !enabled
        case .sleepTimer:
            guard let preset = SleepTimerPreset(rawValue: timer.rawValue) else { return }
            player.sleepTimer.set(preset)
        case .extendSleepTimer:
            guard player.sleepTimer.isActive, !player.sleepTimer.endOfEpisode else {
                throw ShortcutControlError(message: "Start a countdown sleep timer before extending it.")
            }
            guard (1...3600).contains(seconds) else {
                throw ShortcutControlError(message: "Choose an extension from 1 to 3600 seconds.")
            }
            player.sleepTimer.extend(by: Double(seconds))
        case .cancelSleepTimer: player.sleepTimer.cancel()
        case .bookmark:
            guard PersistentModelLifetime.episodeExists(episode.persistentModelID, in: context) else {
                throw ShortcutControlError(message: "Save this episode in Earshot before bookmarking it.")
            }
            BookmarkRepository(context: context).add(to: episode,
                positionSeconds: Int(player.currentPositionSeconds), note: note)
        }
    }
}

struct PlaybackControlIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Control Playback in Earshot"
    static let description = IntentDescription("Controls the loaded episode without opening Earshot. Speed and silence trimming apply to the current podcast. Volume boost enables medium boost or turns it off for the current episode. Continuous play controls stopping after this episode. Clear marks the current queued episode played, removes it, and advances using your existing download policy.")
    @Parameter(title: "Control", default: .pause) var command: ShortcutPlaybackCommand
    @Parameter(title: "Seconds", default: 300) var seconds: Int
    @Parameter(title: "Speed", default: 1.0) var speed: Double
    @Parameter(title: "Enabled", default: true) var enabled: Bool
    @Parameter(title: "Timer", default: .fifteenMinutes) var timer: ShortcutTimer
    @Parameter(title: "Bookmark note", default: "") var note: String
    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$command) in Earshot") {
            \.$seconds
            \.$speed
            \.$enabled
            \.$timer
            \.$note
        }
    }
    func perform() async throws -> some IntentResult {
        try await LibraryPlaybackBridge.shared.control(command, seconds: seconds, speed: speed,
                                                       enabled: enabled, timer: timer, note: note)
        return .result()
    }
}

struct PauseListeningIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Pause Listening in Earshot"
    static let description = IntentDescription("Pauses the current episode without toggling playback.")
    func perform() async throws -> some IntentResult {
        try await LibraryPlaybackBridge.shared.control(.pause)
        return .result()
    }
}

struct NextChapterIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Next Chapter in Earshot"
    static let description = IntentDescription("Moves to the next chapter. Reports when chapters are unavailable.")
    func perform() async throws -> some IntentResult {
        try await LibraryPlaybackBridge.shared.control(.nextChapter)
        return .result()
    }
}

struct PreviousChapterIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Previous Chapter in Earshot"
    static let description = IntentDescription("Restarts the current chapter or moves to the previous one, matching Earshot’s player.")
    func perform() async throws -> some IntentResult {
        try await LibraryPlaybackBridge.shared.control(.previousChapter)
        return .result()
    }
}

struct ClearEpisodeIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Clear Episode and Play Next in Earshot"
    static let description = IntentDescription("Marks the current queued episode played, removes it from Queue and plays the next one. Existing download deletion settings apply. Does not clear the entire Queue.")
    func perform() async throws -> some IntentResult {
        try await LibraryPlaybackBridge.shared.control(.clearAndNext)
        return .result()
    }
}
