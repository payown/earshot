import SwiftUI

extension View {
    /// Loads, normalizes, writes, and shares the transcript for a Quick Action's
    /// target episode (#717). Every episode-row surface uses this same flow.
    func episodeTranscriptExport(_ trigger: Binding<Episode?>) -> some View {
        modifier(EpisodeTranscriptExportModifier(trigger: trigger))
    }
}

private struct EpisodeTranscriptExportModifier: ViewModifier {
    @Binding var trigger: Episode?
    @State private var exportFile: ExportFile?
    @State private var isExporting = false

    func body(content: Content) -> some View {
        content
            .onChange(of: trigger?.persistentModelID) { _, _ in start() }
            .sheet(item: $exportFile) { file in
                ShareSheet(items: [file.url])
            }
    }

    private func start() {
        guard let episode = trigger else { return }
        guard !isExporting else {
            Announcer.announce("Already preparing a transcript export")
            trigger = nil
            return
        }
        let source = episode.transcriptURL?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !source.isEmpty else {
            Announcer.announce("No transcript available for this episode")
            trigger = nil
            return
        }

        isExporting = true
        Announcer.announce("Preparing transcript export")
        let podcastTitle = episode.podcast?.title
        let episodeTitle = episode.title
        let publicationDate = episode.pubDate
        Task {
            let result = await TranscriptService().load(from: source)
            isExporting = false
            trigger = nil
            switch result {
            case .success(let segments):
                do {
                    exportFile = ExportFile(url: try TranscriptMarkdownExporter.write(
                        podcastTitle: podcastTitle,
                        episodeTitle: episodeTitle,
                        publicationDate: publicationDate,
                        segments: segments
                    ))
                } catch {
                    AppLog.data.error(
                        "Transcript export failed: \(error.localizedDescription, privacy: .public)"
                    )
                    Announcer.announce("Could not export transcript")
                }
            case .failure(let error):
                AppLog.data.error(
                    "Transcript export load failed: \(error.localizedDescription, privacy: .public)"
                )
                Announcer.announce("Could not export transcript")
            }
        }
    }
}
