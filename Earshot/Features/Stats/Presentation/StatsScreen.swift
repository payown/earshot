import SwiftUI
import SwiftData

/// Listening stats: total time, time saved by speed, episodes completed, an
/// opt-in day streak, and a per-podcast breakdown, with CSV export and
/// delete-all-history. Reached from Settings. Native `Form`/`List` controls are
/// VoiceOver- and Dynamic-Type-friendly by default.
struct StatsScreen: View {
    @Environment(\.modelContext) private var context
    @Environment(SettingsStore.self) private var settings

    @State private var period: StatsPeriod = .thisWeek
    @State private var stats: ListeningStats = .empty
    @State private var exportFile: StatsCSVFile?
    @State private var confirmingDelete = false

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker("Period", selection: $period) {
                    ForEach(StatsPeriod.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Stats period")
            }

            if stats.totalSeconds == 0 {
                // Lead with the empty state so a VoiceOver user meets it first,
                // rather than wading through a column of zeroes.
                Section {
                    ContentUnavailableView {
                        Label("No listening yet", systemImage: "chart.bar")
                    } description: {
                        Text("Play some episodes and your stats will appear here.")
                    }
                }
            } else {
                Section("Summary") {
                    summaryRow("Total listening", seconds: stats.totalSeconds)
                    summaryRow("Time saved by speed", seconds: stats.timeSavedSeconds)
                    LabeledContent("Episodes completed", value: "\(stats.episodesCompleted)")
                        .accessibilityElement(children: .combine)
                    if settings.statsStreaksEnabled {
                        LabeledContent("Day streak", value: "\(stats.currentStreakDays)")
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("Day streak, \(stats.currentStreakDays) \(stats.currentStreakDays == 1 ? "day" : "days")")
                    }
                }

                if !stats.perPodcast.isEmpty {
                    Section("By podcast") {
                        ForEach(stats.perPodcast) { stat in
                            LabeledContent(stat.podcastTitle, value: StatsLogic.durationLabel(stat.totalSeconds))
                                .accessibilityElement(children: .combine)
                                .accessibilityLabel("\(stat.podcastTitle), \(StatsLogic.spokenDuration(stat.totalSeconds)), \(stat.episodeCount) \(stat.episodeCount == 1 ? "session" : "sessions")")
                        }
                    }
                }
            }

            Section("Streaks") {
                Toggle("Show day streak", isOn: $settings.statsStreaksEnabled)
                    .accessibilityHint("Off by default. Counts consecutive days you've listened.")
            }

            Section("Data") {
                Button {
                    exportFile = StatsCSVFile(text: StatsRepository(context: context).csv())
                } label: {
                    Label("Export history (CSV)", systemImage: "square.and.arrow.up")
                }
                .disabled(stats.totalSeconds == 0)
                .accessibilityHint(stats.totalSeconds == 0 ? "Nothing to export yet. Listen to an episode first." : "")

                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    Label("Delete all history", systemImage: "trash")
                }
            }
        }
        .navigationTitle("Listening Stats")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .onChange(of: period) { _, _ in
            reload()
            // The numbers below change silently, so confirm the new total.
            Announcer.announce("\(period.label). Total listening \(StatsLogic.spokenDuration(stats.totalSeconds)).")
        }
        .onChange(of: settings.statsStreaksEnabled) { _, _ in reload() }
        .sheet(item: $exportFile) { file in
            ShareSheet(items: [file.url])
        }
        .confirmationDialog(
            "Delete all listening history?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete all history", role: .destructive) { deleteAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes every recorded listening session. This can't be undone.")
        }
    }

    private func summaryRow(_ title: String, seconds: Int) -> some View {
        LabeledContent(title, value: StatsLogic.durationLabel(seconds))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(title), \(StatsLogic.spokenDuration(seconds))")
    }

    private func reload() {
        stats = StatsRepository(context: context).stats(
            for: period,
            includeStreak: settings.statsStreaksEnabled
        )
    }

    private func deleteAll() {
        StatsRepository(context: context).deleteAllHistory()
        reload()
        // Defer past the confirmation dialog's dismissal so VoiceOver doesn't drop
        // the announcement mid-transition.
        DispatchQueue.main.async {
            Announcer.announce("Listening history deleted")
        }
    }
}

/// A throwaway CSV file backing the share sheet, written to a temp URL.
struct StatsCSVFile: Identifiable {
    let id = UUID()
    let url: URL

    init(text: String) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("earshot-listening-history.csv")
        try? text.data(using: .utf8)?.write(to: url)
        self.url = url
    }
}
