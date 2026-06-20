import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PlayerService.self) private var player
    @Environment(QuickActionStore.self) private var quickActions
    @Environment(DownloadManager.self) private var downloads

    var body: some View {
        TabView {
            NavigationStack {
                InboxScreen()
            }
            .tabItem { Label("Inbox", systemImage: "tray") }

            NavigationStack {
                SubscriptionsView()
            }
            .tabItem { Label("Podcasts", systemImage: "music.note.list") }

            NavigationStack {
                QueueScreen()
            }
            .tabItem { Label("Queue", systemImage: "list.bullet") }

            NavigationStack {
                DownloadsScreen()
            }
            .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }

            NavigationStack {
                QuickActionsSettingsView()
            }
            .tabItem { Label("Actions", systemImage: "slider.horizontal.3") }
        }
        .safeAreaInset(edge: .bottom) {
            NowPlayingBar()
        }
        // VoiceOver magic tap (two-finger double tap) toggles playback anywhere.
        .accessibilityAction(.magicTap) {
            player.togglePlayPause()
        }
        .task {
            // Wire persistence and restore the last episode (paused) on launch.
            // Done here, not in a view body's computed work, so the context is
            // injected exactly once.
            player.configure(context: modelContext)
            quickActions.configure(context: modelContext)
            downloads.configure(context: modelContext)
            ExpirationService(context: modelContext).runExpiration()
            PlaybackStartup.restoreLastEpisode(into: player, context: modelContext)
        }
    }
}
