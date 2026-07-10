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
            // Earshot Plus (#633). Only "Restore Purchases" lives here today —
            // the paywall / entitlement status row (#632) is a separate,
            // design-reviewed checkpoint that will add more to this section
            // later.
            Section("Earshot Plus") {
                RestorePurchasesRow()
            }

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

/// "Restore Purchases" action for Earshot Plus (#633). Re-syncs the current
/// Apple ID's transaction history against StoreKit — covers a reinstall, a
/// new device, or an entitlement that lapsed locally — and announces the
/// result to VoiceOver. Stateless: no entitlement status or upsell copy here,
/// that's #632's paywall.
private struct RestorePurchasesRow: View {
    @Environment(EntitlementStore.self) private var entitlements
    @State private var isRestoring = false

    var body: some View {
        Button {
            restore()
        } label: {
            HStack {
                Text("Restore Purchases")
                Spacer()
                if isRestoring {
                    ProgressView()
                }
            }
        }
        .disabled(isRestoring)
        // `.disabled` alone only adds the "dimmed" trait — VoiceOver users get
        // no spoken indication that a restore is actually in flight (the
        // ProgressView above has no accessibility presence of its own once
        // this Button's own accessibilityLabel flattens its children). Swap
        // the label text itself, matching the busy-state pattern already used
        // for AddFeedView's "Adding podcast" ProgressView.
        .accessibilityLabel(isRestoring ? "Restoring purchases" : "Restore Purchases")
        .accessibilityHint("Re-checks your Apple ID for past Earshot Plus purchases")
    }

    private func restore() {
        guard !isRestoring else { return }
        isRestoring = true
        Task {
            let outcome = await entitlements.restorePurchases()
            isRestoring = false
            announce(outcome)
        }
    }

    private func announce(_ outcome: EntitlementStore.RestoreOutcome) {
        switch outcome {
        case .restored:
            Announcer.announce("Earshot Plus restored.", assertive: true)
        case .noChange:
            Announcer.announce("No purchases to restore.", assertive: true)
        case .failed(let reason):
            AppLog.monetization.error("Restore Purchases failed: \(reason, privacy: .public)")
            Announcer.announce("Restore failed. Check your connection and try again.", assertive: true)
        }
    }
}
