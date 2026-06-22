import SwiftUI
import SwiftData
import UIKit

struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PlayerService.self) private var player
    @Environment(QuickActionStore.self) private var quickActions
    @Environment(DownloadManager.self) private var downloads
    @Environment(SettingsStore.self) private var settings
    @Environment(TipsStore.self) private var tips
    @Environment(NotificationRouter.self) private var notificationRouter

    @State private var showOnboarding = false
    @State private var importState = MigrationImportState()

    /// Which tab is selected. Bound so a notification tap can switch to Library.
    @State private var selectedTab: RootTab = .inbox
    /// Navigation path for the Library tab, so a notification can push a podcast
    /// detail screen onto it (#72).
    @State private var libraryPath: [Podcast] = []

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                InboxScreen()
                    .contextualTip(.inbox)
            }
            .modifier(TabChrome())
            .tabItem { Label("Inbox", systemImage: "tray") }
            .tag(RootTab.inbox)

            NavigationStack {
                QueueScreen()
                    .contextualTip(.queue)
            }
            .modifier(TabChrome())
            .tabItem { Label("Queue", systemImage: "list.bullet") }
            .tag(RootTab.queue)

            NavigationStack(path: $libraryPath) {
                SubscriptionsView()
            }
            .modifier(TabChrome())
            .tabItem { Label("Library", systemImage: "books.vertical") }
            .tag(RootTab.library)

            NavigationStack {
                DownloadsScreen()
                    .contextualTip(.downloads)
            }
            .modifier(TabChrome())
            .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }
            .tag(RootTab.downloads)

            NavigationStack {
                SettingsScreen()
            }
            .modifier(TabChrome())
            .tabItem { Label("Settings", systemImage: "gearshape") }
            .tag(RootTab.settings)
        }
        .environment(importState)
        // Route a notification tap / action into the Library tab + podcast detail
        // (#72). Reacting on the published intent keeps the delegate decoupled
        // from the view tree.
        .onChange(of: notificationRouter.pendingIntent) { _, intent in
            if let intent { route(intent) }
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
            // One-time import of subscriptions from a previous (Flutter) install
            // that shared this bundle id's container. The fast local SQLite read
            // (readFeedURLs) decides migrator vs. new user; the slow network
            // subscribe runs in a detached task so launch is never blocked.
            let migration = FlutterMigrationService(context: modelContext)
            if MigrationGate.shouldImport(migrationComplete: migration.isComplete),
               let subs = migration.readSubscriptions(), !subs.isEmpty {
                // Returning user from the old build: skip onboarding and restore
                // their shows. Two phases:
                //   1. Near-instant: create labeled show "shells" (no episodes) on a
                //      background context (@ModelActor). This is what keeps VoiceOver
                //      responsive — no thousands-of-episodes write storm.
                //   2. Background: a normal refresh fetches each show's episodes and
                //      seeds the inbox high-water mark (pre-dismissing the backlog so
                //      the inbox starts empty; only future episodes surface later).
                // The user is free to use the populated Library throughout.
                settings.onboardingComplete = true
                showOnboarding = false
                let importer = SubscriptionImporter(modelContainer: modelContext.container)
                Task {
                    let count = await importer.importShells(subs) { _, _ in }
                    migration.markComplete()
                    guard count > 0 else { return }
                    // Haptic first so it doesn't race the start of the spoken announcement.
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    Announcer.announce(
                        "\(count) \(count == 1 ? "show" : "shows") restored. Your Library is ready. "
                        + "Episodes are loading in the background.",
                        assertive: true
                    )

                    // Fill episodes in the background. The RestoreBanner tracks progress
                    // (swipe-to-check); no spoken milestones — it's a background task the
                    // user didn't start, so interrupting their navigation would be noise.
                    importState.start(total: count)
                    await SubscriptionRepository(context: modelContext).refreshAll { completed, _ in
                        importState.update(completed: completed)
                    }
                    // Stamp the throttle window so a background wake right after the
                    // restore doesn't redundantly re-refresh every show (#381).
                    AppSettingsStore(context: modelContext).setDate(Date(), for: SettingsKey.lastFeedRefresh)
                    importState.finish()
                    Announcer.announce("Episodes loaded. Your Library is up to date.")
                }
            } else {
                // Fresh install (or already migrated): nothing to import.
                if !migration.isComplete { migration.markComplete() }
                // Show onboarding on first launch (after settings load so we don't flash).
                showOnboarding = !settings.onboardingComplete
            }
        }
    }

    // MARK: Notification routing (#72)

    /// Resolves a notification intent against the model graph, performs any
    /// action (enqueue / play), switches to the Library tab, and pushes the
    /// podcast's detail screen. Clears the router when done. Missing podcasts /
    /// episodes are logged and skipped — never crash on a stale notification.
    private func route(_ intent: NotificationIntent) {
        defer { notificationRouter.clear() }

        let feedURL = intent.feedURL
        var descriptor = FetchDescriptor<Podcast>(
            predicate: #Predicate { $0.feedURL == feedURL }
        )
        descriptor.fetchLimit = 1
        guard let podcast = (try? modelContext.fetch(descriptor))?.first else {
            AppLog.notifications.error("Notification routing: podcast not found for feed")
            return
        }

        switch intent {
        case .openPodcast:
            break
        case let .addEpisodeToQueue(_, episodeGUID):
            if let episode = episode(guid: episodeGUID, in: podcast) {
                QueueRepository(context: modelContext).add(episode)
                Announcer.announce("Added to queue")
            }
        case let .playEpisode(_, episodeGUID):
            if let episode = episode(guid: episodeGUID, in: podcast) {
                player.play(episode)
            }
        }

        // Switch to Library and push the podcast detail. Reset the path first so
        // we always land on the show's detail, not stacked atop a prior push.
        selectedTab = .library
        libraryPath = [podcast]
    }

    /// Finds an episode by guid within a podcast's loaded episodes.
    private func episode(guid: String, in podcast: Podcast) -> Episode? {
        podcast.episodes.first { $0.guid == guid }
    }
}

/// The five root tabs. Backs the `TabView` selection so notification routing can
/// switch to Library programmatically (#72).
private enum RootTab: Hashable {
    case inbox, queue, library, downloads, settings
}

/// Per-tab chrome: the restore-progress banner inset above the content (top) and
/// the mini player inset above the system tab bar (bottom). Applied to each tab's
/// `NavigationStack` rather than to the `TabView` — attaching an inset to the
/// TabView itself pushes it into the TabView's safe area, which overlaps and hides
/// the system tab bar (#366). Attached to the tab content, both float correctly
/// and the system handles positioning across devices and Dynamic Type sizes.
/// Both subviews render nothing when inactive, so they add no inset until needed:
/// `NowPlayingBar` while nothing is loaded, `RestoreBanner` while not importing.
private struct TabChrome: ViewModifier {
    @Environment(MigrationImportState.self) private var migration

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top) {
                if migration.isActive {
                    RestoreBanner(completed: migration.completed, total: migration.total)
                }
            }
            .safeAreaInset(edge: .bottom) {
                NowPlayingBar()
            }
    }
}
