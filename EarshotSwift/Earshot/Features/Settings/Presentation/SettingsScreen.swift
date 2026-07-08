import SwiftUI

/// Settings home: a list of category rows, each opening a dedicated screen for
/// that group (the iOS Settings.app pattern). This replaced a single long
/// scrolling form of heading sections — one deep list is harder to scan and, for
/// VoiceOver, means many more stops to pass before reaching a given control.
/// Every row is a native `NavigationLink` + `Label` (icon + text, never icon
/// alone) with a hint describing what the screen contains.
struct SettingsScreen: View {
    var body: some View {
        Form {
            Section {
                NavigationLink {
                    PlaybackSettingsView()
                } label: {
                    Label("Playback", systemImage: "play.circle")
                }
                .accessibilityHint("Speed, skip intervals, voice enhance, chapters, auto-advance, and queue grouping")

                NavigationLink {
                    InboxSettingsView()
                } label: {
                    Label("Inbox", systemImage: "tray")
                }
                .accessibilityHint("How many episodes seed the inbox, and opt-in podcasts")

                NavigationLink {
                    DownloadsSettingsView()
                } label: {
                    Label("Downloads", systemImage: "arrow.down.circle")
                }
                .accessibilityHint("Wi-Fi restriction and auto-download")

                NavigationLink {
                    AppearanceSettingsView()
                } label: {
                    Label("Appearance", systemImage: "paintpalette")
                }
                .accessibilityHint("Theme, accent color, layout density, launch screen, and episode numbers")

                NavigationLink {
                    QuickActionsSettingsView()
                } label: {
                    Label("Quick Actions", systemImage: "bolt")
                }
                .accessibilityHint("Choose and reorder the episode and queue actions")

                NavigationLink {
                    HistorySettingsView()
                } label: {
                    Label("History & Stats", systemImage: "clock")
                }
                .accessibilityHint("Listening stats and how long history is kept")

                NavigationLink {
                    PrivacySettingsView()
                } label: {
                    Label("Privacy", systemImage: "hand.raised")
                }
                .accessibilityHint("What Earshot collects, and policy links")

                NavigationLink {
                    DataSettingsView()
                } label: {
                    Label("Data", systemImage: "externaldrive")
                }
                .accessibilityHint("Export, import, and delete your local data")

                NavigationLink {
                    HelpSettingsView()
                } label: {
                    Label("Help & About", systemImage: "questionmark.circle")
                }
                .accessibilityHint("Send feedback, app version, credits, and license")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Settings")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
            }
        }
    }
}
