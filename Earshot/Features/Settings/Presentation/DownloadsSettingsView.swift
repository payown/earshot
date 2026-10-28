import SwiftUI
import SwiftData
import UIKit
import UserNotifications

enum DownloadsSettingsFocus: Hashable {
    case autoDownloadCount
}

/// Listen to compact save metadata instead of keeping a live SwiftData query
/// over all downloads in the view. Episode and podcast membership changes can
/// affect whether a local active row has a matching episode.
enum DownloadStorageChange {
    static func affectsSnapshot(_ notification: Notification) -> Bool {
        let info = notification.userInfo ?? [:]
        for key in [ModelContext.NotificationKey.insertedIdentifiers,
                    .updatedIdentifiers, .deletedIdentifiers] {
            let value = info[key] ?? info[key.rawValue]
            let ids = (value as? [PersistentIdentifier]) ?? Array(value as? Set<PersistentIdentifier> ?? [])
            if ids.contains(where: { id in
                id.entityName == "LocalEpisodeState" || id.entityName == "Podcast"
                    || (id.entityName == "Episode" && key != .updatedIdentifiers)
            }) { return true }
        }
        return false
    }
}

/// At most one store scan runs at a time. If a newer save arrives while a
/// scan is running, its waiter performs one fresh scan after the old one ends.
@MainActor
final class DownloadStorageSnapshotCoordinator {
    private struct Scan {
        let id: UUID
        let revision: Int
        let task: Task<DownloadStorageSnapshot?, Never>
    }
    private var inFlight: Scan?
    private var latestRevision = 0

    func invalidate() -> Int {
        latestRevision += 1
        return latestRevision
    }

    func snapshot(for revision: Int,
                  load: @escaping @MainActor () async -> DownloadStorageSnapshot?) async -> DownloadStorageSnapshot? {
        while !Task.isCancelled && revision == latestRevision {
            let current: Scan
            if let inFlight {
                current = inFlight
            } else {
                current = Scan(id: UUID(), revision: revision, task: Task { await load() })
                inFlight = current
            }
            let result = await current.task.value
            if inFlight?.id == current.id { inFlight = nil }
            guard !Task.isCancelled, revision == latestRevision else { return nil }
            guard current.revision == revision else { continue }
            return result
        }
        return nil
    }
}

/// Shares a directory scan across view-task cancellations. A canceled waiter
/// never records a successful scan, and a changed set of paths gets a fresh
/// scan after the old one finishes rather than starting overlapping walks.
@MainActor
final class DownloadStorageSizeCoordinator {
    private struct Scan {
        let id: UUID
        let paths: Set<String>
        let forceRequest: Int
        let task: Task<Int64, Never>
    }

    private var inFlight: Scan?
    private var lastCompletedAt: Date?
    private var completedForceRequest = 0

    func recordCompletedScan(forceRequest: Int = 0) {
        lastCompletedAt = Date()
        completedForceRequest = max(completedForceRequest, forceRequest)
    }

    func size(
        for paths: Set<String>,
        forceRequest: Int = 0,
        scan: @escaping @MainActor () async -> Int64
    ) async -> Int64? {
        if forceRequest <= completedForceRequest, let lastCompletedAt {
            let delay = max(1, 60 - Date().timeIntervalSince(lastCompletedAt))
            do { try await Task.sleep(for: .seconds(delay)) } catch { return nil }
        }

        while !Task.isCancelled {
            let current: Scan
            if let inFlight {
                current = inFlight
            } else {
                current = Scan(id: UUID(), paths: paths, forceRequest: forceRequest, task: Task { await scan() })
                inFlight = current
            }
            let bytes = await current.task.value
            guard !Task.isCancelled else { return nil }
            if inFlight?.id == current.id { inFlight = nil }
            // A new download may have completed during the scan. Recheck its
            // size instead of publishing a snapshot from the old set of files.
            guard current.paths == paths, current.forceRequest >= forceRequest else { continue }
            return bytes
        }
        return nil
    }
}

/// Settings → Downloads: Wi-Fi restriction and auto-download count. Extracted
/// from the former single Settings form.
struct DownloadsSettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(DownloadManager.self) private var downloads
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    let initialFocus: DownloadsSettingsFocus?
    let showsDoneButton: Bool

    // Compact count/size/activity snapshot. File traversal happens off-main in
    // DownloadManager so opening Settings stays responsive with large libraries.
    @State private var storageSummary = DownloadStorageSummary.empty
    @State private var sizeCoordinator = DownloadStorageSizeCoordinator()
    @State private var snapshotCoordinator = DownloadStorageSnapshotCoordinator()
    @State private var storagePaths: Set<String> = []
    @State private var hasStorageSnapshot = false
    @State private var storageRefreshID = 0
    @State private var foregroundRefreshID = 0
    @State private var forcedSizeRefreshID = 0
    @State private var showClearAllConfirm = false
    @State private var showCancelActiveConfirm = false
    @State private var isClearing = false
    @State private var isCancelling = false
    @State private var authRequestToken = 0
    @State private var authorizationStatus: UNAuthorizationStatus?
    @AccessibilityFocusState private var focusedSetting: DownloadsSettingsFocus?

    init(
        initialFocus: DownloadsSettingsFocus? = nil,
        showsDoneButton: Bool = false
    ) {
        self.initialFocus = initialFocus
        self.showsDoneButton = showsDoneButton
    }

    private static let downloadCounts = [0, 1, 3, 5, 10]

    private var autoDownloadAdjustableOptions: [AdjustableOptionPicker<Int>.Option] {
        Self.downloadCounts.map {
            .init(value: $0, title: $0 == 0 ? "Off" : "\($0)", spoken: $0 == 0 ? "Off" : "\($0) episodes")
        }
    }

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                NavigationLink("Download activity") { DownloadActivityScreen() }
                NavigationLink("Inbox, Queue, and Downloads guide") { ListeningWorkflowGuide() }
            }
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
                .accessibilityFocused($focusedSetting, equals: .autoDownloadCount)
                Toggle("Auto-download queued episodes", isOn: $settings.autoDownloadQueued)
                    .accessibilityHint("When on, episodes added to the queue download automatically so you can play them offline. The Wi-Fi-only setting still applies.")
            } footer: {
                Text("Downloads up to this many newest episodes per podcast when you follow it and after each refresh. New episodes may download whether they appear in Inbox or Queue. This is not a global storage cap. The separate Queue setting also downloads older episodes you add to Queue.")
            }

            Section {
                Toggle("Delete downloads when done", isOn: $settings.deleteDownloadAfterPlayed)
                    .accessibilityHint("When on, an episode's download is removed automatically once you finish it, mark it played, or remove it from Inbox or Queue")
            } footer: {
                Text("Frees storage as you go by removing an episode's download when you finish it, mark it played, or remove it from Inbox or Queue. Pending and active downloads are cancelled too. Off by default.")
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
        .toolbar {
            if showsDoneButton {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityHint("Closes download settings")
                }
            }
        }
        .task(id: storageRefreshID) {
            await refreshStorageCounts(revision: storageRefreshID)
        }
        .task(id: StorageSizeRequest(paths: storagePaths, refreshID: foregroundRefreshID,
                                     forceRequest: forcedSizeRefreshID, hasSnapshot: hasStorageSnapshot)) {
            if hasStorageSnapshot {
                await refreshStorageSizeWhenDue(paths: storagePaths, forceRequest: forcedSizeRefreshID)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)
            .receive(on: DispatchQueue.main)) { notification in
            if DownloadStorageChange.affectsSnapshot(notification) { invalidateStorageSnapshot() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .earshotSubscriptionsDidChange)
            .merge(with: NotificationCenter.default.publisher(for: .earshotCloudProjectionDidApply))
            .receive(on: DispatchQueue.main)) { _ in
            invalidateStorageSnapshot()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                invalidateStorageSnapshot()
                foregroundRefreshID += 1
            }
        }
        .onAppear { requestInitialFocus() }
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

    private func invalidateStorageSnapshot() {
        storageRefreshID = snapshotCoordinator.invalidate()
    }

    private struct StorageSizeRequest: Equatable {
        let paths: Set<String>
        let refreshID: Int
        let forceRequest: Int
        let hasSnapshot: Bool
    }

    private func refreshStorageCounts(revision: Int) async {
        guard let snapshot = await snapshotCoordinator.snapshot(for: revision, load: {
            await downloads.storageSnapshot()
        }), !Task.isCancelled else { return }
        if storagePaths != snapshot.paths { storagePaths = snapshot.paths }
        if !hasStorageSnapshot { hasStorageSnapshot = true }
        let updated = DownloadStorageSummary(
            downloadedCount: snapshot.counts.downloadedCount,
            activeCount: snapshot.counts.activeCount,
            allocatedBytes: storageSummary.allocatedBytes
        )
        if storageSummary != updated { storageSummary = updated }
    }

    private func refreshStorageSizeWhenDue(paths: Set<String>, forceRequest: Int) async {
        guard let bytes = await sizeCoordinator.size(for: paths, forceRequest: forceRequest, scan: {
            await downloads.storageAllocatedBytes()
        }), !Task.isCancelled else { return }
        storageSummary = DownloadStorageSummary(
            downloadedCount: storageSummary.downloadedCount,
            activeCount: storageSummary.activeCount,
            allocatedBytes: bytes
        )
        sizeCoordinator.recordCompletedScan(forceRequest: forceRequest)
    }

    private func requestInitialFocus() {
        guard let initialFocus else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            focusedSetting = initialFocus
        }
    }

    private func cancelActiveDownloads() {
        isCancelling = true
        Task {
            let cancelled = await downloads.cancelActiveDownloads()
            invalidateStorageSnapshot()
            await refreshStorageCounts(revision: storageRefreshID)
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
            invalidateStorageSnapshot()
            forcedSizeRefreshID += 1
            await refreshStorageCounts(revision: storageRefreshID)
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
