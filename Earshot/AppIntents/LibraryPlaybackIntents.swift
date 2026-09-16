import AppIntents
import Foundation

struct ResumeListeningIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Resume Listening in Earshot"
    static let description = IntentDescription("Opens Earshot and resumes the current episode from its saved position.")
    static var openAppWhenRun: Bool { true } // iOS 18–25 compatibility.
    @available(iOS 26.0, *) static var supportedModes: IntentModes { .foreground }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await LibraryPlaybackBridge.shared.resume()
        return .result()
    }
}

struct PlayEpisodeIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Episode in Earshot"
    static let description = IntentDescription("Opens Earshot and plays the selected episode, preserving saved progress and queue order. Enable Siri and Search to choose an episode.")
    static var openAppWhenRun: Bool { true }
    @available(iOS 26.0, *) static var supportedModes: IntentModes { .foreground }
    @Parameter(title: "Episode") var episode: EpisodeEntity

    static var parameterSummary: some ParameterSummary { Summary("Play \(\.$episode) in Earshot") }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await LibraryPlaybackBridge.shared.play(id: episode.id)
        return .result()
    }
}
