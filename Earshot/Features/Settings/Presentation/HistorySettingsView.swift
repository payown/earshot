import SwiftUI

/// Settings → History & Stats: listening statistics and how long history is
/// retained. Extracted from the former single Settings form.
struct HistorySettingsView: View {
    @Environment(SettingsStore.self) private var settings

    private static let retentionOptions = [30, 60, 90, 180, 365]

    private var historyAdjustableOptions: [AdjustableOptionPicker<Int>.Option] {
        Self.retentionOptions.map { .init(value: $0, title: "\($0) days", spoken: "\($0) days") }
    }

    var body: some View {
        @Bindable var settings = settings
        Form {
            // No section header: the "History & Stats" navigation title already
            // names the screen, so a matching header would be a redundant
            // VoiceOver heading stop.
            Section {
                NavigationLink("Listening stats") { StatsScreen() }
                AdjustableOptionPicker(
                    "Keep listening history",
                    options: historyAdjustableOptions,
                    selection: $settings.historyRetentionDays,
                    hint: "How long listening history is kept. Flick up for longer."
                )
            }
        }
        .navigationTitle("History & Stats")
    }
}
