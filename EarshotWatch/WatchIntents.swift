import AppIntents
import Foundation

struct OpenWatchNowPlayingIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Earshot Now Playing"
    static let description = IntentDescription("Open the Now Playing screen on Apple Watch.")
    static var openAppWhenRun: Bool { true }

    func perform() async throws -> some IntentResult {
        UserDefaults.standard.set("now-playing", forKey: "watchPendingDestination")
        return .result()
    }
}

struct PauseWatchAudioIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause Earshot on Apple Watch"
    static let description = IntentDescription("Pause podcast audio playing on Apple Watch.")

    func perform() async throws -> some IntentResult {
        let paused = await MainActor.run {
            guard let runtime = WatchRuntimeRegistry.runtime else { return false }
            runtime.player.pause()
            return true
        }
        guard paused else {
            return .result(dialog: "Open Earshot on Apple Watch to control playback.")
        }
        return .result(dialog: "Paused Earshot on Apple Watch.")
    }
}

struct EarshotWatchShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenWatchNowPlayingIntent(),
                    phrases: ["Open Now Playing in \(.applicationName)"],
                    shortTitle: "Now Playing", systemImageName: "play.circle")
        AppShortcut(intent: PauseWatchAudioIntent(),
                    phrases: ["Pause \(.applicationName) on Apple Watch"],
                    shortTitle: "Pause Earshot", systemImageName: "pause.circle")
    }
}
