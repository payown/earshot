import SwiftUI
import SwiftData
import UIKit

/// Owns the Inbox badge query separately from RootView so changing playback
/// position cannot make RootView evaluate Inbox relationships. The predicate is
/// identical to the Inbox screen's and is executed by the persistent store.
private struct InboxTabBadge: View {
    // Restricted to UNPLAYED, non-dismissed episodes (`playedAt == nil`). This
    // badge is inset into all five tabs, so it is always in the tree during
    // playback, and every 5-second position save invalidates these queries. The
    // old `InboxQuery.normal`/`optInOnly` returned every non-dismissed episode —
    // a set that grows without bound because finished episodes are never
    // dismissed — so each save re-materialized the whole library on the main
    // thread and iOS force-killed the app under `cpu_resource_fatal` (~93% CPU /
    // 60s) about a minute into playback. `playedAt == nil` trims the unbounded
    // played history out of the fetch in SQLite; the exact `.newEpisode` check
    // stays an in-memory pass (SwiftData can't translate the stored enum).
    @Query(filter: InboxQuery.normalUnplayed) private var normalEpisodes: [Episode]
    @Query(filter: InboxQuery.optInOnlyUnplayed) private var optedInEpisodes: [Episode]
    let optInOnly: Bool

    var body: some View {
        let episodes = optInOnly ? optedInEpisodes : normalEpisodes
        TabBarBadgeApplier(tabIndex: 0, count: episodes.lazy.filter { $0.status == .newEpisode }.count)
    }
}

struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(PlayerService.self) private var player
    @Environment(QuickActionStore.self) private var quickActions
    @Environment(DownloadManager.self) private var downloads
    @Environment(SettingsStore.self) private var settings
    @Environment(TipsStore.self) private var tips
    @Environment(OPMLImportProgress.self) private var importProgress
    @Environment(NotificationRouter.self) private var notificationRouter
    @Environment(EntitlementStore.self) private var entitlements

    @State private var showOnboarding = false

    /// Every queue row. SwiftData keeps this current, so it both drives the
    /// re-render when the queue changes AND supplies the rows the Queue tab badge
    /// count is reduced from — without a fresh fetch per body. Reduced through
    /// `QueueRepository.displayedCount(from:)` so the count drops orphan rows and
    /// equals exactly what `QueueScreen` shows (#491). Mirrors `inboxCandidates`.
    @Query(sort: \QueueItem.position) private var queueItems: [QueueItem]

    /// Which tab is selected. Optional so the first paint can resolve the saved
    /// launch-screen preference synchronously (#492) instead of rendering Inbox
    /// and then jumping. `nil` means "not chosen yet" — the selection binding
    /// below falls back to ``resolvedLaunchTab`` until either the user navigates
    /// or the `.task` seeds it from the loaded preference. A notification tap can
    /// also set it to switch to Library.
    @State private var selectedTab: RootTab?
    /// Navigation path for the Library tab, so a notification can push a podcast
    /// detail screen onto it (#72).
    @State private var libraryPath: [Podcast] = []

    var body: some View {
        // Live unplayed-inbox count from the same source of truth as the Inbox
        // heading. Shown via a native `UITabBarItem` badge applied by
        // `TabBarBadgeApplier` (below), NOT SwiftUI's `.badge`. Both render the
        // count as its own VoiceOver element on top of the tab button, so the
        // count was announced twice when flicking past the Inbox tab; the applier
        // sets the visible badge and hides that duplicate element. The
        // `InboxTabBadge` owns the same store-level membership query as the
        // Inbox screen. It never walks Episode→Podcast relationships in Swift,
        // which keeps a playback-position save from fanning out into inverse
        // relationship faults. The bubble is hidden automatically at 0.
        // Live queue count for the Queue tab badge, reduced the same way the Queue
        // screen builds its list (orphan rows dropped). Shown via the same native
        // `UITabBarItem` badge mechanism as Inbox so UIKit folds ", N items" into
        // the single tab element ("Queue, N items") with no extra VoiceOver stop
        // (#491).
        let queueBadgeCount = QueueRepository.displayedCount(from: queueItems)

        // Selection binding that honors the saved Launch screen on cold launch
        // (#492): while `selectedTab` is still nil it reports the persisted launch
        // tab (read synchronously), so the first frame already shows the right
        // tab. Any user tap — or the `.task` seed / notification routing — writes
        // a concrete tab, after which `resolvedLaunchTab` is no longer consulted.
        // Appearance preferences resolved once per body evaluation (#461).
        let appearance = resolvedAppearance

        let tabSelection = Binding<RootTab>(
            get: { selectedTab ?? resolvedLaunchTab },
            set: { selectedTab = $0 }
        )

        TabView(selection: tabSelection) {
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
                #if DEBUG
                // App Store screenshot capture (#643): the "Settings with
                // auto-download" shot needs DownloadsSettingsView, which is a
                // pushed destination in production. Rather than convert Settings'
                // rows to value-based navigation just for a screenshot, render it
                // as the tab root in screenshot mode only. No production change.
                if ScreenshotHarness.requestedScreen == .settings {
                    DownloadsSettingsView()
                } else {
                    SettingsScreen()
                }
                #else
                SettingsScreen()
                #endif
            }
            .modifier(TabChrome())
            .tabItem { Label("Settings", systemImage: "gearshape") }
            .tag(RootTab.settings)
        }
        // Native UITabBarItem badge for the Inbox unread count (#321 follow-up):
        // re-applies whenever `inboxBadgeCount` changes. Replaces SwiftUI's
        // `.badge`, which double-announced the count under VoiceOver.
        .background(InboxTabBadge(optInOnly: settings.inboxOptInOnly))
        // Native UITabBarItem badge for the Queue episode count (#491): same
        // mechanism and VoiceOver folding as the Inbox badge above, on tab 1.
        .background(TabBarBadgeApplier(tabIndex: 1, count: queueBadgeCount))
        // Route a notification tap / action into the Library tab + podcast detail
        // (#72). Reacting on the published intent keeps the delegate decoupled
        // from the view tree.
        .onChange(of: notificationRouter.pendingIntent) { _, intent in
            if let intent { route(intent) }
        }
        // Re-assert the native Inbox badge after a tab switch: SwiftUI can rebuild
        // the tab-bar items on selection change and transiently drop a manually
        // set `badgeValue`. Cheap and idempotent.
        .onChange(of: selectedTab) { _, _ in
            TabBarBadgeApplier.apply(tabIndex: 1, count: queueBadgeCount)
        }
        // Appearance preferences (#461): theme override, accent tint, and layout
        // density, applied at the root so every tab, push, and sheet follows.
        // SettingsStore is observed, so a change in Settings → Appearance
        // re-applies live. `resolvedAppearance` serves the persisted values
        // synchronously on the first launch frames, so an overridden theme
        // doesn't flash the system appearance while settings load.
        .appearance(theme: appearance.theme, accent: appearance.accent, density: appearance.density)
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
        // Raise the full player when the user plays an episode from a row and the
        // "open player on play" setting is on (#562). Presented here at the single
        // TabView root, not on NowPlayingBar — the mini bar is inset into all five
        // tabs (#366), so a per-bar sheet would present up to five times. The row
        // "Play now" action sets `pendingFullPlayerPresentation`; the binding
        // clears it on dismiss so it never re-presents.
        .sheet(isPresented: Binding(
            get: { player.pendingFullPlayerPresentation },
            set: { player.pendingFullPlayerPresentation = $0 }
        )) {
            NowPlayingScreen()
        }
        // Bulk OPML import progress, presented over whichever tab is active. The
        // binding is read-only off the shared state: it appears when an import calls
        // `start()` and auto-dismisses when `finish()` flips `isImporting` false.
        // There's no manual dismiss for v1 (no cancel) — the import is short and the
        // "Imported N podcasts" announcement closes the loop. `.interactiveDismiss`
        // is disabled so a drag can't orphan an in-flight import; auto-dismiss is the
        // only path, which also keeps it off a drag gesture screen-reader users
        // can't reliably perform.
        .sheet(isPresented: Binding(
            get: { importProgress.isImporting },
            set: { _ in }
        )) {
            ImportProgressView(progress: importProgress)
                .interactiveDismissDisabled(true)
                .presentationDetents([.medium])
        }
        // Share-sheet / "Open in Earshot" for .opml files exported by feed
        // readers. RootView is always in the tree (onboarding is a cover on top),
        // so the import runs and announces its count whether the user is
        // mid-onboarding or on the main tabs — the file is never silently dropped.
        // Routed through the shared importer so it uses the app's main container
        // context, exactly as Settings' in-app picker does.
        .onOpenURL { url in
            handleIncomingFile(url)
        }
        // Re-apply audio settings mid-playback when they change (#352).
        .onChange(of: settings.globalSpeed) { _, _ in
            player.reapplyRate()
        }
        .onChange(of: settings.voiceEnhanceEnabled) { _, _ in
            player.applyAudioEnhancement()
        }
        // Keep the lock-screen / Control Center skip buttons in sync with the
        // skip-interval settings (#... review P1-5). Set once at launch, then
        // updated here so a change in Settings takes effect immediately.
        .onChange(of: settings.skipForwardSeconds) { _, _ in
            player.updateRemoteSkipIntervals()
        }
        .onChange(of: settings.skipBackSeconds) { _, _ in
            player.updateRemoteSkipIntervals()
        }
        .task {
            #if DEBUG
            // App Store screenshot capture (#643): seed the in-memory store from
            // fixtures before any of the configure/restore work below reads it.
            // This task is main-actor isolated, so the settings writes in the
            // seeder (AppSettingsStore is @MainActor) are safe here. DEBUG +
            // launch-arg only; a normal launch never enters this branch.
            if ScreenshotHarness.isSeeding {
                ScreenshotFixtures.seed(into: modelContext)
            }
            #endif
            // Wire persistence and restore the last episode (paused) on launch.
            // Done here, not in a view body's computed work, so the context is
            // injected exactly once.
            player.configure(context: modelContext)
            quickActions.configure(context: modelContext)
            downloads.configure(context: modelContext)
            // Reset downloads left stuck at .downloading by a kill mid-transfer,
            // so they don't hang forever; in-flight background tasks are kept (#544).
            await downloads.reconcileStuckDownloads()
            // Rewrite legacy absolute download paths to bare file names and reset
            // episodes whose file is gone, BEFORE anything resolves a local file
            // this launch (#575). iOS moves the app container on every update.
            await downloads.reconcileDownloadPaths()
            settings.configure(context: modelContext)
            // One-time free-tier podcast cap grandfathering snapshot (#635): must
            // run before any subscribe action can occur (including an onboarding
            // OPML import below), so it's placed right after settings load and
            // before showOnboarding is set.
            let capSettings = AppSettingsStore(context: modelContext)
            let currentPodcastCount = (try? modelContext.fetchCount(FetchDescriptor<Podcast>())) ?? 0
            capSettings.introducePodcastCapGatingIfNeeded(currentPodcastCount: currentPodcastCount)
            // Seed the launch tab from the now-loaded preference exactly once, so
            // the saved Launch screen choice is honored on cold launch (#492).
            // Only applies while the user hasn't already navigated; it never
            // re-asserts on later settings loads, leaving mid-session tab
            // switching and notification routing to Library intact.
            if selectedTab == nil {
                selectedTab = RootTab(launchScreen: settings.launchScreen)
            }
            tips.configure(context: modelContext)
            ExpirationService(context: modelContext).runExpiration()
            StatsRepository(context: modelContext).applyRetention(days: settings.historyRetentionDays)
            PlaybackStartup.restoreLastEpisode(into: player, context: modelContext)
            // Show onboarding on first launch (after settings load so we don't
            // flash). The Flutter→SwiftUI launch import that used to run here was
            // removed with the rest of the abandoned migration feature (#580) —
            // OPML is the only re-import path.
            showOnboarding = !settings.onboardingComplete
            #if DEBUG
            // App Store screenshot capture (#643): route straight to the
            // requested screen and never show onboarding. DEBUG + launch-arg only.
            if ScreenshotHarness.isActive {
                showOnboarding = false
                ScreenshotHarness.apply(
                    in: modelContext,
                    player: player,
                    selectTab: { selectedTab = $0 },
                    pushLibrary: { libraryPath = $0 }
                )
            }
            #endif
        }
    }

    // MARK: Launch tab (#492)

    /// The launch tab resolved straight from persisted settings, read
    /// synchronously so the very first render already shows the user's chosen tab
    /// rather than flashing Inbox and jumping (#492). `settings.launchScreen` is
    /// still the default at first body evaluation (it loads in `.task`), so this
    /// reads ``AppSettingsStore`` directly. Consulted only while `selectedTab` is
    /// nil — a handful of launch renders — after which the seeded value is used.
    private var resolvedLaunchTab: RootTab {
        RootTab(launchScreen: AppSettingsStore(context: modelContext).launchScreen())
    }

    // MARK: Appearance (#461)

    /// The appearance preferences to apply this frame. Reads the observed
    /// SettingsStore properties FIRST — unconditionally — so Observation always
    /// registers them as dependencies and a change in Settings → Appearance
    /// re-renders RootView. While the store hasn't loaded yet (the handful of
    /// launch frames before the `.task` runs `configure`), the persisted values
    /// are read synchronously from ``AppSettingsStore`` instead, so a saved
    /// theme override is already applied on the first paint with no
    /// default-theme flash (mirrors ``resolvedLaunchTab``, #492).
    private var resolvedAppearance: (theme: ThemeOverride, accent: AccentChoice, density: LayoutDensity) {
        var theme = settings.themeOverride
        var accent = settings.accentColor
        var density = settings.layoutDensity
        if !settings.loaded {
            let store = AppSettingsStore(context: modelContext)
            theme = store.themeOverride()
            accent = store.accentChoice()
            density = store.layoutDensity()
        }
        return (theme, accent, density)
    }

    // MARK: Incoming OPML file (share sheet / Open in)

    /// Handles a file handed to Earshot via the share sheet or "Open in". Only
    /// acts on `.opml`/`.xml` file URLs (the document types we registered);
    /// anything else is ignored gracefully. Routes through the shared importer so
    /// the read + security-scope + import + announce logic is identical to the
    /// in-app Settings picker, using this view's main container context.
    private func handleIncomingFile(_ url: URL) {
        guard url.isFileURL else { return }
        let ext = url.pathExtension.lowercased()
        guard ext == "opml" || ext == "xml" else { return }
        Task {
            await OPMLFileImporter.importFile(at: url, context: modelContext, progress: importProgress, downloader: downloads, isEntitled: entitlements.isEntitled)
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
/// switch to Library programmatically (#72). Internal (not private) so the
/// launch-screen mapping is unit-testable (#492).
enum RootTab: Hashable {
    case inbox, queue, library, downloads, settings

    /// Maps a persisted ``LaunchScreen`` preference to the tab Earshot opens on
    /// cold launch (#492). `LaunchScreen` has no Settings case, so every case
    /// maps to its matching content tab.
    init(launchScreen: LaunchScreen) {
        switch launchScreen {
        case .inbox: self = .inbox
        case .queue: self = .queue
        case .library: self = .library
        case .downloads: self = .downloads
        }
    }
}

/// Per-tab chrome: the mini player inset above the system tab bar. Applied to
/// each tab's `NavigationStack` rather than to the `TabView` — attaching an inset
/// to the TabView itself pushes it into the TabView's safe area, which overlaps
/// and hides the system tab bar (#366). Attached to the tab content, it floats
/// correctly and the system handles positioning across devices and Dynamic Type
/// sizes. `NowPlayingBar` renders nothing while nothing is loaded, so it adds no
/// inset until needed.
private struct TabChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom) {
                // Group the mini player's transport controls into one named
                // accessibility container so reaching the bar reads as a "Now
                // Playing" group rather than loose buttons (#490). `.contain`
                // keeps each control individually navigable. This does not change
                // VoiceOver's standard first→last wrap, and NowPlayingBar still
                // renders (and insets) nothing while idle, so the #366 layout —
                // the bar never covering the system tab bar — is unchanged.
                NowPlayingBar()
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Now Playing")
            }
    }
}
