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
            .modifier(MiniPlayerInset())
            .tabItem { Label("Inbox", systemImage: "tray") }

            NavigationStack {
                QueueScreen()
                    .contextualTip(.queue)
            }
            .modifier(MiniPlayerInset())
            .tabItem { Label("Queue", systemImage: "list.bullet") }

            NavigationStack {
                SubscriptionsView()
            }
            .modifier(MiniPlayerInset())
            .tabItem { Label("Library", systemImage: "books.vertical") }

            NavigationStack {
                DownloadsScreen()
                    .contextualTip(.downloads)
            }
            .modifier(MiniPlayerInset())
            .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }

            NavigationStack {
                SettingsScreen()
            }
            .modifier(MiniPlayerInset())
            .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        // VoiceOver magic tap (two-finger double tap) toggles playback anywhere.
        .accessibilityAction(.magicTap) {
            player.togglePlayPause()
        }
        // Announce play-state transitions once, at the single TabView root. The
        // mini player is now inset into each of the five tabs (#366), so the
        // announcement cannot live on NowPlayingBar without firing up to five
        // times per toggle. Announcer no-ops when VoiceOver is off.
        .onChange(of: player.isPlaying) { _, isPlaying in
            Announcer.announce(isPlaying ? "Playing" : "Paused")
        }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView()
        }
        #if IS_BETA_BUILD
        .fullScreenCover(isPresented: $showMigration) {
            MigrationPromptView()
        }
        #endif
        // Re-apply audio settings mid-playback when they change (#352).
        .onChange(of: settings.globalSpeed) { _, _ in
            player.reapplyRate()
        }
        .onChange(of: settings.voiceEnhanceEnabled) { _, _ in
            player.applyAudioEnhancement()
        }
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

/// Insets the mini player above a tab's content via the tab content's own bottom
/// safe area. Applied to each tab's `NavigationStack` rather than to the
/// `TabView` — attaching the inset to the TabView itself pushed the bar into the
/// TabView's bottom safe area, which overlaps and hides the system tab bar
/// (#366). Attached to the tab content, the bar floats above the system tab bar,
/// the tab bar stays visible and tappable during playback, and the system
/// continues to handle positioning above the tab bar and home indicator across
/// devices and Dynamic Type sizes. `NowPlayingBar` renders nothing when no
/// episode is loaded, so this adds no inset until playback begins.
private struct MiniPlayerInset: ViewModifier {
    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom) {
            NowPlayingBar()
        }
    }
}
