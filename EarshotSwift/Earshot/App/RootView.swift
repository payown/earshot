import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PlayerService.self) private var player

    var body: some View {
        TabView {
            NavigationStack {
                SubscriptionsView()
            }
            .tabItem { Label("Podcasts", systemImage: "music.note.list") }

            NavigationStack {
                QueueScreen()
            }
            .tabItem { Label("Queue", systemImage: "list.bullet") }

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
            PlaybackStartup.restoreLastEpisode(into: player, context: modelContext)
        }
    }
}
