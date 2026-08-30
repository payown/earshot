import SwiftUI

struct AccessibilitySettingsView: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("Haptic feedback", isOn: $settings.hapticFeedbackEnabled)
                    .accessibilityHint(
                        "Provides tactile feedback when playback starts and a refresh completes"
                    )
            } footer: {
                Text("Provides tactile feedback when playback starts and a refresh completes.")
            }

            Section {
                Toggle("Podcast name", isOn: $settings.spokenEpisodePodcastName)
                Toggle("Published date", isOn: $settings.spokenEpisodePublishedDate)
                Toggle("Download or streaming status", isOn: $settings.spokenEpisodeDownloadStatus)
                Toggle("Duration or time remaining", isOn: $settings.spokenEpisodeDuration)
                Picker("Episode description", selection: $settings.spokenEpisodeDescriptionMode) {
                    ForEach(SpokenDescriptionMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
            } header: {
                Text("Episode list details")
            } footer: {
                Text("Brief speaks a short show-notes preview. Full can make each episode item lengthy. Episode title and interaction state are always spoken.")
            }

            Section {
                Picker("Podcast description", selection: $settings.spokenPodcastDescriptionMode) {
                    ForEach(SpokenDescriptionMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
            } header: {
                Text("Podcast list details")
            } footer: {
                Text("Brief speaks a short description. Full can make podcast items in Library, search, and category browsing lengthy.")
            }
        }
        .navigationTitle("Accessibility")
    }
}
