import AppIntents
import Foundation

struct ResumeListeningIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Resume Listening in Earshot"
    static let description = IntentDescription("Resumes the current episode from its saved position, or starts the first queued episode if none is loaded.")
    static var openAppWhenRun: Bool { false } // iOS 18–25 compatibility.
    @available(iOS 26.0, *) static var supportedModes: IntentModes { .background }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await LibraryPlaybackBridge.shared.resume()
        return .result()
    }
}

struct PlayEpisodeIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Episode in Earshot"
    static let description = IntentDescription("Plays the selected episode, preserving saved progress and queue order. Enable library search in Earshot settings to choose an episode.")
    static var openAppWhenRun: Bool { false }
    @available(iOS 26.0, *) static var supportedModes: IntentModes { .background }
    @Parameter(title: "Episode") var episode: EpisodeEntity

    static var parameterSummary: some ParameterSummary { Summary("Play \(\.$episode) in Earshot") }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await LibraryPlaybackBridge.shared.play(id: episode.id)
        return .result()
    }
}

struct PlayLatestPodcastIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Latest Podcast Episode in Earshot"
    static let description = IntentDescription("Plays the newest episode already stored for the selected followed podcast. It does not refresh the feed or change your queue.")
    static var openAppWhenRun: Bool { false }
    @available(iOS 26.0, *) static var supportedModes: IntentModes { .background }
    @Parameter(title: "Podcast") var podcast: PodcastEntity

    static var parameterSummary: some ParameterSummary { Summary("Play the latest episode of \(\.$podcast)") }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await LibraryPlaybackBridge.shared.playLatest(showID: podcast.id)
        return .result()
    }
}
