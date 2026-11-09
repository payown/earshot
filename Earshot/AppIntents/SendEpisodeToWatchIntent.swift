import AppIntents

/// Queues a direct watch download. Watch Connectivity delivers the request when
/// possible; the watch performs and validates the actual media transfer.
struct SendEpisodeToWatchIntent: AppIntent {
    static let title: LocalizedStringResource = "Download Episode on Apple Watch"
    static let description = IntentDescription("Choose an Earshot episode for a direct watch download.")
    @Parameter(title: "Episode") var episode: EpisodeEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Download \(\.$episode) on Apple Watch")
    }

    func perform() async throws -> some IntentResult {
        let records = try await LibraryIntentBridge.shared.episodes(for: [episode.id])
        guard let record = records.first else {
            return .result(dialog: "That episode is no longer available in the iPhone library.")
        }
        let queued = await PhoneWatchConnectivity.shared.queueWatchDownload(record)
        guard queued else {
            return .result(dialog: "Apple Watch is not ready to receive this download request.")
        }
        return .result(dialog: "Sent to Apple Watch. The watch will download it when connected.")
    }
}
