import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PlayerService.self) private var player
    @Environment(QuickActionStore.self) private var quickActions
    @Environment(DownloadManager.self) private var downloads
    @Environment(SettingsStore.self) private var settings
    @Environment(TipsStore.self) private var tips

    @State private var showOnboarding = false
    #if IS_BETA_BUILD
    @State private var showMigration = false
    #endif

    var body: some View {
        TabView {
            NavigationStack {
                InboxScreen()
                    .contextualTip(.inbox)
            }
            .tabItem { Label("Inbox", systemImage: "tray") }

            NavigationStack {
                QueueScreen()
                    .contextualTip(.queue)
            }
            .tabItem { Label("Queue", systemImage: "list.bullet") }

            NavigationStack {
                SubscriptionsView()
            }
            .tabItem { Label("Library", systemImage: "books.vertical") }

            NavigationStack {
                DownloadsScreen()
                    .contextualTip(.downloads)
            }
            .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }

            NavigationStack {
                SettingsScreen()
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .safeAreaInset(edge: .bottom) {
            NowPlayingBar()
        }
        // VoiceOver magic tap (two-finger double tap) toggles playback anywhere.
        .accessibilityAction(.magicTap) {
            player.togglePlayPause()
        }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView()
        }
        #if IS_BETA_BUILD
        .fullScreenCover(isPresented: $showMigration) {
            MigrationPromptView()
        }
        #endif
        .task {
            // Wire persistence and restore the last episode (paused) on launch.
            // Done here, not in a view body's computed work, so the context is
            // injected exactly once.
            player.configure(context: modelContext)
            quickActions.configure(context: modelContext)
            downloads.configure(context: modelContext)
            settings.configure(context: modelContext)
            tips.configure(context: modelContext)
            ExpirationService(context: modelContext).runExpiration()
            StatsRepository(context: modelContext).applyRetention(days: settings.historyRetentionDays)
            PlaybackStartup.restoreLastEpisode(into: player, context: modelContext)
            // Show onboarding on first launch (after settings load so we don't flash).
            showOnboarding = !settings.onboardingComplete
            #if IS_BETA_BUILD
            // Beta only: offer the Flutter→SwiftUI import once onboarding is done
            // and migration hasn't been resolved. Mutually exclusive with
            // onboarding (which requires onboardingComplete == false).
            let migration = FlutterMigrationService(context: modelContext)
            showMigration = MigrationGate.shouldPrompt(
                onboardingComplete: settings.onboardingComplete,
                migrationComplete: migration.isComplete
            )
            #endif
        }
    }
}
