import SwiftUI
import UIKit
import UserNotifications

/// Settings → Downloads: Wi-Fi restriction and auto-download count. Extracted
/// from the former single Settings form.
struct DownloadsSettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(DownloadManager.self) private var downloads
    @Environment(\.scenePhase) private var scenePhase

    // Compact count/size/activity snapshot. File traversal happens off-main in
    // DownloadManager so opening Settings stays responsive with large libraries.
    @State private var storageSummary = DownloadStorageSummary.empty
    @State private var showClearAllConfirm = false
    @State private var showCancelActiveConfirm = false
    @State private var isClearing = false
    @State private var isCancelling = false
    @State private var authRequestToken = 0
    @State private var authorizationStatus: UNAuthorizationStatus?

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
                Toggle(
                    "Notify when downloads finish",
                    isOn: downloadCompletionNotificationsBinding
                )
                .accessibilityHint("Sends a local notification after an episode finishes downloading")
                .task(id: authRequestToken) {
                    guard authRequestToken > 0 else { return }
                    await NotificationService().requestAuthorization()
                    await refreshAuthorizationStatus(announceIfStillProblematic: true)
                }

                if settings.downloadCompletionNotifications {
                    switch authorizationStatus {
                    case .denied:
                        Label {
                            Text("Notifications are turned off for Earshot. Enable them in Settings to get download alerts.")
                        } icon: {
                            Image(systemName: "bell.slash")
                                .foregroundStyle(.orange)
                        }
                        Button("Open Settings") { openSystemSettings() }
                            .accessibilityHint("Opens the Settings app to Earshot's notification permissions")
                    case .notDetermined:
                        Label {
                            Text("Notifications haven't been turned on for Earshot yet.")
                        } icon: {
                            Image(systemName: "bell")
                                .foregroundStyle(.orange)
                        }
                        Button("Enable Notifications") { authRequestToken += 1 }
                            .accessibilityHint("Asks iOS for permission to send notifications")
                    default:
                        EmptyView()
                    }
                }
            } footer: {
                Text("Sends an on-device notification after an episode finishes downloading. Off by default.")
            }
            .task { await refreshAuthorizationStatus() }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await refreshAuthorizationStatus() }
            }

            Section {
                Button(role: .destructive) {
                    showCancelActiveConfirm = true
                } label: {
                    Text("Cancel active downloads")
                }
                .disabled(storageSummary.activeCount == 0 || isCancelling || isClearing)
                .accessibilityHint(
                    storageSummary.activeCount == 0
                        ? "No active downloads to cancel"
                        : "Stops \(storageSummary.activeCount) active downloads and keeps completed downloads"
                )

                Button(role: .destructive) {
                    showClearAllConfirm = true
                } label: {
                    Text("Clear all downloads")
                }
                .disabled(
                    (storageSummary.downloadedCount == 0 && storageSummary.activeCount == 0)
                        || isClearing || isCancelling
                )
                .accessibilityHint(
                    storageSummary.downloadedCount == 0 && storageSummary.activeCount == 0
                        ? "No downloads to remove"
                        : "Removes every downloaded episode and cancels every active download"
                )
            } footer: {
                Text(DownloadStorageText.storageFooter(summary: storageSummary))
            }
        }
        .navigationTitle("Downloads")
        .task { await refreshStorageSummary() }
        .confirmationDialog(
            "Cancel \(storageSummary.activeCount) active downloads?",
            isPresented: $showCancelActiveConfirm,
            titleVisibility: .visible
        ) {
            Button("Cancel \(storageSummary.activeCount) downloads", role: .destructive) {
                cancelActiveDownloads()
            }
            Button("Keep downloading", role: .cancel) {}
        } message: {
            Text(DownloadStorageText.cancelConfirmation(activeCount: storageSummary.activeCount))
        }
        .confirmationDialog(
            "Clear all downloads?",
            isPresented: $showClearAllConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear all downloads", role: .destructive) { clearAllDownloads() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(DownloadStorageText.clearConfirmation(summary: storageSummary))
        }
    }

    private func refreshStorageSummary() async {
        storageSummary = await downloads.storageSummary()
    }

    private func cancelActiveDownloads() {
        isCancelling = true
        Task {
            let cancelled = await downloads.cancelActiveDownloads()
            await refreshStorageSummary()
            isCancelling = false
            Announcer.announce(
                cancelled == 1
                    ? "Cancelled 1 active download. Completed downloads were kept."
                    : "Cancelled \(cancelled) active downloads. Completed downloads were kept."
            )
        }
    }

    private func clearAllDownloads() {
        isClearing = true
        Task {
            let removed = await downloads.clearAllDownloads()
            await refreshStorageSummary()
            isClearing = false
            Announcer.announce(removed == 1 ? "Cleared 1 download" : "Cleared \(removed) downloads")
        }
    }

    private var downloadCompletionNotificationsBinding: Binding<Bool> {
        Binding(
            get: { settings.downloadCompletionNotifications },
            set: { isOn in
                let decision = NotificationPermissionTrigger.apply(newValue: isOn)
                settings.downloadCompletionNotifications = decision.persistedValue
                if decision.shouldRequestAuthorization { authRequestToken += 1 }
            }
        )
    }

    private func refreshAuthorizationStatus(announceIfStillProblematic: Bool = false) async {
        let status = await NotificationService().currentAuthorizationStatus()
        authorizationStatus = status
        guard announceIfStillProblematic else { return }
        switch status {
        case .denied:
            Announcer.announce(
                "Notifications are off for Earshot in Settings. Enable them there to get download alerts."
            )
        case .notDetermined:
            Announcer.announce("Notifications are still not enabled for Earshot.")
        default:
            break
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
