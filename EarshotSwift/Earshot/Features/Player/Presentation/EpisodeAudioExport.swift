import SwiftUI

extension View {
    /// Presents the "Export audio" flow for the episode bound to `trigger` (#689).
    /// When `trigger` becomes non-nil: downloads the episode if needed (announcing
    /// "Preparing audio file for export" only in that case), copies the local file,
    /// then presents the system share sheet with it. Clears `trigger` when done.
    ///
    /// Keeps the async download-then-share wiring in ONE place so every episode-row
    /// surface (Inbox, Library episode list, Downloads) exports identically. A row's
    /// "Export audio" Quick Action just sets the bound episode.
    func episodeAudioExport(_ trigger: Binding<Episode?>) -> some View {
        modifier(EpisodeAudioExportModifier(trigger: trigger))
    }
}

private struct EpisodeAudioExportModifier: ViewModifier {
    @Binding var trigger: Episode?
    @Environment(DownloadManager.self) private var downloads
    @State private var exportURL: ExportFile?
    @State private var isExporting = false

    func body(content: Content) -> some View {
        content
            // Keyed on identity: fires when a row sets a target episode, and again
            // (harmlessly, guarded) when `start()` clears it back to nil.
            .onChange(of: trigger?.persistentModelID) { _, _ in start() }
            .sheet(item: $exportURL) { file in
                ShareSheet(items: [file.url])
            }
    }

    private func start() {
        // `onChange` also fires when `start()` clears `trigger` back to nil — a
        // no-op we return from silently.
        guard let episode = trigger else { return }
        // A second export requested while one is still preparing: don't start it,
        // but tell the VoiceOver user their activation wasn't lost (they can try
        // again once the first finishes) rather than dropping it in silence.
        guard !isExporting else {
            Announcer.announce("Already preparing an export")
            trigger = nil
            return
        }
        isExporting = true
        // Announce only when a download must happen first, mirroring the player's
        // export flow. Clean, human-readable strings only — no raw data (#688).
        let needsDownload = episode.localAudioURL.map {
            !FileManager.default.fileExists(atPath: $0.path)
        } ?? true
        if needsDownload {
            Announcer.announce("Preparing audio file for export")
        }
        Task {
            let url = await EpisodeExporter.export(episode: episode, using: downloads)
            isExporting = false
            trigger = nil
            if let url {
                exportURL = ExportFile(url: url)
            } else {
                Announcer.announce("Could not export audio file")
            }
        }
    }
}
