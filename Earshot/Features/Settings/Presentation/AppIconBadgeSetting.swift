import SwiftUI

struct AppIconBadgeSetting: View {
    @Environment(SettingsStore.self) private var settings
    @State private var requesting = false
    @State private var message: String?

    var body: some View {
        Section {
            Toggle("Badge downloaded unheard episodes", isOn: Binding(
                get: { settings.badgeDownloadedUnheardEpisodes },
                set: { enabled in
                    message = nil
                    if !enabled {
                        settings.badgeDownloadedUnheardEpisodes = false
                        return
                    }
                    requesting = true
                    Task { @MainActor in
                        defer { requesting = false }
                        do {
                            if try await SystemAppIconBadge().requestPermission() {
                                settings.badgeDownloadedUnheardEpisodes = true
                            } else {
                                message = "Badges are disabled. Allow badges for Earshot in iPhone Settings, then try again."
                            }
                        } catch {
                            message = "Badge permission could not be checked. Please try again."
                        }
                    }
                }
            ))
            .disabled(requesting)
        } footer: {
            Text("Shows the number of downloaded unheard episodes on Earshot’s Home Screen icon. This setting applies only to this device.")
        }
        .alert("Badge unavailable", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("OK", role: .cancel) { message = nil }
        } message: {
            Text(message ?? "")
        }
    }
}
