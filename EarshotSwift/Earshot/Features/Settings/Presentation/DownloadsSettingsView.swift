import SwiftUI

/// Settings → Downloads: Wi-Fi restriction and auto-download count. Extracted
/// from the former single Settings form.
struct DownloadsSettingsView: View {
    @Environment(SettingsStore.self) private var settings

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
                    "Auto-download recent",
                    options: autoDownloadAdjustableOptions,
                    selection: $settings.autoDownloadCount,
                    hint: "How many recent episodes download automatically. Flick up for more, down to turn off."
                )
            }
        }
        .navigationTitle("Downloads")
    }
}
