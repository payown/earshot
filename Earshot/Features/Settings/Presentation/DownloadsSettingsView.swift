import SwiftUI
import SwiftData

/// Settings → Downloads: Wi-Fi restriction and auto-download count. Extracted
/// from the former single Settings form.
struct DownloadsSettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(DownloadManager.self) private var downloads
    @Environment(\.modelContext) private var context

    // Live count of downloaded episodes, refreshed on appear and after a clear.
    // A bounded SQL COUNT over `downloadPath != nil` (no object materialization),
    // so it stays cheap even on a large library (performance.md).
    @State private var downloadCount = 0
    @State private var showClearAllConfirm = false
    @State private var isClearing = false

    private static let downloadCounts = [0, 1, 3, 5, 10]

    private var autoDownloadAdjustableOptions: [AdjustableOptionPicker<Int>.Option] {
        Self.downloadCounts.map {
            .init(value: $0, title: $0 == 0 ? "Off" : "\($0)", spoken: $0 == 0 ? "Off" : "\($0) episodes")
        }
    }

    var body: some View {
        @Bindable var settings = settings
        Form {
            // No section header: the "Downloads" navigation title already names
            // the screen, so a matching header would be a redundant VoiceOver
            // heading stop.
            Section {
                Toggle("Download on Wi-Fi only", isOn: $settings.wifiOnlyDownloads)
                AdjustableOptionPicker(
                    "Auto-download new episodes per podcast",
                    options: autoDownloadAdjustableOptions,
                    selection: $settings.autoDownloadCount,
                    hint: "Sets how many newest episodes per podcast download when you follow or refresh. Includes new Inbox and Queue episodes. Flick up for more, down to turn off."
                )
                Toggle("Auto-download queued episodes", isOn: $settings.autoDownloadQueued)
                    .accessibilityHint("When on, episodes added to the queue download automatically so you can play them offline. The Wi-Fi-only setting still applies.")
            } footer: {
                Text("Downloads up to this many newest episodes per podcast when you follow it and after each refresh. New episodes may download whether they appear in Inbox or Queue. This is not a global storage cap. The separate Queue setting also downloads older episodes you add to Queue.")
            }

            Section {
                Toggle("Delete downloads when done", isOn: $settings.deleteDownloadAfterPlayed)
                    .accessibilityHint("When on, an episode's download is removed automatically once you finish it, mark it played, or remove it from the queue")
            } footer: {
                Text("Frees storage as you go by removing an episode's download when you finish it, mark it played, or remove it from the queue. Off by default.")
            }

            Section {
                Button(role: .destructive) {
                    showClearAllConfirm = true
                } label: {
                    Text("Clear all downloads")
                }
                .disabled(downloadCount == 0 || isClearing)
                .accessibilityHint(
                    downloadCount == 0
                        ? "No downloads to remove"
                        : "Removes every downloaded episode from this device"
                )
            } footer: {
                Text(
                    downloadCount == 0
                        ? "You have no downloaded episodes."
                        : "Frees storage by removing ^[\(downloadCount) downloaded episode](inflect: true) from this device. This can't be undone."
                )
            }
        }
        .navigationTitle("Downloads")
        .task { await refreshDownloadCount() }
        .confirmationDialog(
            "Clear all downloads?",
            isPresented: $showClearAllConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear all downloads", role: .destructive) { clearAllDownloads() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes ^[\(downloadCount) downloaded episode](inflect: true) from this device. This can't be undone.")
        }
    }

    /// Recomputes the downloaded-episode count with a bounded SQL COUNT — no
    /// object materialization, so it's safe on a large library.
    private func refreshDownloadCount() async {
        let descriptor = FetchDescriptor<LocalEpisodeState>(predicate: DownloadListQuery.hasPath)
        downloadCount = (try? context.fetchCount(descriptor)) ?? 0
    }

    private func clearAllDownloads() {
        isClearing = true
        Task {
            let removed = await downloads.clearAllDownloads()
            await refreshDownloadCount()
            isClearing = false
            Announcer.announce(removed == 1 ? "Cleared 1 download" : "Cleared \(removed) downloads")
        }
    }
}
