import Combine
import SwiftData
import SwiftUI

/// No accessibility element and no live query. Existing tab speech is unchanged.
struct AppIconBadgeObserver: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(SettingsStore.self) private var settings
    @State private var controller: AppIconBadgeController?

    var body: some View {
        Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
            .onAppear {
                guard controller == nil else { refresh(); return }
                let container = context.container
                controller = AppIconBadgeController.shared
                controller?.configure(container: container)
                refresh()
            }
            .onChange(of: settings.badgeDownloadedUnheardEpisodes) { _, _ in refresh() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { refresh() }
            }
            .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)
                .receive(on: DispatchQueue.main)) { notification in
                if settings.badgeDownloadedUnheardEpisodes,
                   AppIconBadgeCount.downloadsChanged(notification) { refresh() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .earshotInboxDidChange)
                .merge(with: NotificationCenter.default.publisher(for: .earshotSubscriptionsDidChange))
                .merge(with: NotificationCenter.default.publisher(for: .earshotQueueDidChange))
                .merge(with: NotificationCenter.default.publisher(for: .earshotCloudProjectionDidApply))
                .receive(on: DispatchQueue.main)) { _ in
                if settings.badgeDownloadedUnheardEpisodes { refresh() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .earshotEpisodeUserStateDidChange)
                .receive(on: DispatchQueue.main)) { notification in
                guard settings.badgeDownloadedUnheardEpisodes,
                      let snapshots = notification.object as? [EpisodeUserStateSnapshot],
                      snapshots.contains(where: \.playedChangedExplicitly) else { return }
                refresh()
            }
    }

    private func refresh() {
        controller?.refresh(enabled: settings.badgeDownloadedUnheardEpisodes)
    }
}
