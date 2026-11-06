import AppIntents
import Foundation

enum WatchNavigationRequest {
    static let changed = Notification.Name("EarshotWatchNavigationRequestChanged")
    private static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: "group.media.payown.earshot.watch") ?? .standard
    }

    static func openNowPlaying(defaults: UserDefaults? = nil) {
        (defaults ?? sharedDefaults).set("now-playing", forKey: "watchPendingDestination")
        NotificationCenter.default.post(name: changed, object: nil)
    }

    static func consumeNowPlaying(defaults: UserDefaults? = nil) -> Bool {
        let store = defaults ?? sharedDefaults
        guard store.string(forKey: "watchPendingDestination") == "now-playing" else { return false }
        store.removeObject(forKey: "watchPendingDestination")
        return true
    }
}

struct OpenWatchNowPlayingIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Earshot Now Playing"
    static let description = IntentDescription("Open the Now Playing screen on Apple Watch.")
    static var openAppWhenRun: Bool { true }

    func perform() async throws -> some IntentResult {
        await MainActor.run { WatchNavigationRequest.openNowPlaying() }
        return .result()
    }
}

struct PauseWatchAudioIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause Earshot on Apple Watch"
    static let description = IntentDescription("Pause podcast audio playing on Apple Watch.")

    func perform() async throws -> some IntentResult {
        let paused = await MainActor.run {
            guard let runtime = WatchRuntimeRegistry.currentOrCreate(), runtime.player.episode != nil else { return false }
            runtime.player.pause()
            return true
        }
        guard paused else {
            return .result(dialog: "Open Earshot on Apple Watch to control playback.")
        }
        return .result(dialog: "Paused Earshot on Apple Watch.")
    }
}

struct ResumeWatchAudioIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume Earshot on Apple Watch"
    static let description = IntentDescription("Resume the current podcast on Apple Watch.")

    func perform() async throws -> some IntentResult {
        let runtime = await MainActor.run { WatchRuntimeRegistry.currentOrCreate() }
        guard let runtime, await MainActor.run(body: { runtime.player.episode != nil }) else {
            return .result(dialog: "Open Earshot and choose an episode first.")
        }
        let playing = await MainActor.run { runtime.player.isPlaying }
        if !playing { await runtime.player.toggle() }
        let started = await MainActor.run { runtime.player.isPlaying }
        if started { return .result(dialog: "Playing on Apple Watch.") }
        return .result(dialog: "Apple Watch could not start playback.")
    }
}

struct SkipWatchForwardIntent: AppIntent {
    static let title: LocalizedStringResource = "Skip Forward in Earshot on Apple Watch"

    func perform() async throws -> some IntentResult {
        guard let runtime = await MainActor.run(body: { WatchRuntimeRegistry.currentOrCreate() }) else {
            return .result(dialog: "Open Earshot on Apple Watch first.")
        }
        await runtime.player.skipForward()
        return .result(dialog: "Skipped forward on Apple Watch.")
    }
}

struct SkipWatchBackwardIntent: AppIntent {
    static let title: LocalizedStringResource = "Skip Back in Earshot on Apple Watch"

    func perform() async throws -> some IntentResult {
        guard let runtime = await MainActor.run(body: { WatchRuntimeRegistry.currentOrCreate() }) else {
            return .result(dialog: "Open Earshot on Apple Watch first.")
        }
        await runtime.player.skipBackward()
        return .result(dialog: "Skipped back on Apple Watch.")
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
        AppShortcut(intent: ResumeWatchAudioIntent(),
                    phrases: ["Resume \(.applicationName) on Apple Watch"],
                    shortTitle: "Resume Earshot", systemImageName: "play.circle")
        AppShortcut(intent: SkipWatchForwardIntent(),
                    phrases: ["Skip forward in \(.applicationName) on Apple Watch"],
                    shortTitle: "Skip Forward", systemImageName: "goforward")
        AppShortcut(intent: SkipWatchBackwardIntent(),
                    phrases: ["Skip back in \(.applicationName) on Apple Watch"],
                    shortTitle: "Skip Back", systemImageName: "gobackward")
    }
}
