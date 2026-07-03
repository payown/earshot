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
    @Environment(OPMLImportProgress.self) private var importProgress
    @Environment(NotificationRouter.self) private var notificationRouter

    @State private var showOnboarding = false
    @State private var importState = MigrationImportState()

    /// Candidate inbox episodes: non-dismissed, newest first. SwiftData keeps
    /// this result current, so it both triggers a RootView re-render when inbox
    /// membership changes AND supplies the rows the badge count is computed from
    /// — without a fresh `context.fetch` on every body evaluation. The remaining
    /// in-memory rules (status + per-podcast exclusion) are applied by
    /// `InboxRepository.inbox(from:)`. Mirrors InboxScreen's pattern. The
    /// predicate matches `inboxEpisodes()` exactly so the badge count is
    /// identical to the Inbox heading.
    @Query(filter: #Predicate<Episode> { $0.inboxDismissed == false },
           sort: \Episode.pubDate, order: .reverse)
    private var inboxCandidates: [Episode]

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
        // `inboxCandidates` @Query above drives the re-render that keeps this
        // current AND supplies the rows, so the count is computed with
        // `inbox(from:)` over the maintained query result rather than a fresh
        // `context.fetch` on every render (a position save no longer fans out
        // into a full inbox re-fetch). The bubble is hidden automatically when
        // the count is 0.
        let inboxBadgeCount = InboxRepository(context: modelContext).inbox(from: inboxCandidates).count
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
                SettingsScreen()
            }
            .modifier(TabChrome())
            .tabItem { Label("Settings", systemImage: "gearshape") }
            .tag(RootTab.settings)
        }
        // Native UITabBarItem badge for the Inbox unread count (#321 follow-up):
        // re-applies whenever `inboxBadgeCount` changes. Replaces SwiftUI's
        // `.badge`, which double-announced the count under VoiceOver.
        .background(TabBarBadgeApplier(tabIndex: 0, count: inboxBadgeCount))
        // Native UITabBarItem badge for the Queue episode count (#491): same
        // mechanism and VoiceOver folding as the Inbox badge above, on tab 1.
        .background(TabBarBadgeApplier(tabIndex: 1, count: queueBadgeCount))
        .environment(importState)
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
            TabBarBadgeApplier.apply(tabIndex: 0, count: inboxBadgeCount)
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
            // Wire persistence and restore the last episode (paused) on launch.
            // Done here, not in a view body's computed work, so the context is
            // injected exactly once.
            player.configure(context: modelContext)
            quickActions.configure(context: modelContext)
            downloads.configure(context: modelContext)
            // Reset downloads left stuck at .downloading by a kill mid-transfer,
            // so they don't hang forever; in-flight background tasks are kept (#544).
            await downloads.reconcileStuckDownloads()
            settings.configure(context: modelContext)
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
            // One-time import of subscriptions from a previous (Flutter) install
            // that shared this bundle id's container. The fast local SQLite read
            // (readFeedURLs) decides migrator vs. new user; the slow network
            // subscribe runs in a detached task so launch is never blocked.
            let migration = FlutterMigrationService(context: modelContext)
            // Temporary instrumentation for the returning-user data-loss report
            // (#430): snapshot earshot.db's on-disk state to the migration log
            // channel on every launch. Remove once diagnosed.
            migration.logDiagnostics(trigger: "launch")
            // Self-heal a completed migration that's missing data. Two cases,
            // distinguished by whether any shows survived (#426):
            //  - Library empty: the first-launch import fired and found nothing
            //    (or failed), locking the user out of a library still recoverable
            //    from earshot.db. Reopen the gate so the full import below re-runs.
            //  - Shows present but per-episode state never restored (a prior build,
            //    or an overlay that failed after the shells imported): re-run just
            //    the local state overlay against the episodes already in the store
            //    — no network, no re-subscribe, no "shows restored" announcement.
            let migratedPodcastCount = (try? modelContext.fetchCount(FetchDescriptor<Podcast>())) ?? 0
            if MigrationGate.shouldSelfHeal(
                migrationComplete: migration.isComplete,
                podcastCount: migratedPodcastCount,
                episodeStateRestored: migration.episodeStateRestored,
                flutterHasData: migration.hasFlutterData()
            ) {
                if migratedPodcastCount == 0 {
                    migration.resetForSelfHeal()
                } else {
                    // State-only self-heal: the library survived but its per-episode
                    // state never restored. Stamp the attempt date; restoreEpisodeState
                    // records succeeded/failed (#429).
                    migration.recordImportAttempt()
                    Task { await restoreEpisodeState(using: migration) }
                }
            }
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
                //   3. Overlay the user's old per-episode state (played / inbox /
                //      position) from earshot.db onto those freshly-fetched episodes,
                //      so a returning user's inbox and history come back (#426).
                // The user is free to use the populated Library throughout.
                settings.onboardingComplete = true
                showOnboarding = false
                // Stamp the attempt date now that an import run is actually
                // starting, so Settings → Data shows when the import last ran even
                // while episodes are still loading (#429). Status is written at the
                // success/failure points in restoreEpisodeState.
                migration.recordImportAttempt()
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
                    let notifications = await SubscriptionRepository(context: modelContext)
                        .refreshAll(onProgress: { completed, _ in
                            importState.update(completed: completed)
                        })
                    // Deliver any new-episode notifications this launch refresh
                    // found. This stamp marks lastFeedRefresh, so a background wake
                    // inside the throttle window is skipped — the path that finds
                    // new episodes must be the path that notifies or they're lost
                    // (#421). deliver() coalesces per podcast, so no double-fire.
                    // (Migrated shells backfill pre-dismissed and never notify, so
                    // this is typically empty on the very first restore.)
                    if !notifications.isEmpty {
                        await NotificationService().deliver(notifications)
                    }
                    // Restore played / inbox / position state and queue order now
                    // that the episodes exist. The backfill above pre-dismissed and
                    // unplayed everything; this puts the user's actual inbox,
                    // history, and queue back, and records success so the self-heal
                    // gate won't redo it (#426).
                    await restoreEpisodeState(using: migration)
                    // Stamp the throttle window so a background wake right after the
                    // restore doesn't redundantly re-refresh every show (#381).
                    AppSettingsStore(context: modelContext).setDate(Date(), for: SettingsKey.lastFeedRefresh)
                    importState.finish()
                    Announcer.announce("Episodes loaded. Your Library is up to date.")
                }
            } else if MigrationGate.shouldImport(migrationComplete: migration.isComplete) {
                // Gate is open but the Flutter database gave us nothing this launch.
                // Don't mark complete yet — a first cold launch can miss earshot.db.
                // Retry on the next launch, giving up only after maxAttempts (#426).
                migration.recordEmptyImportAttempt()
                showOnboarding = !settings.onboardingComplete
            } else {
                // Already migrated: nothing to import. Show onboarding on first
                // launch (after settings load so we don't flash).
                showOnboarding = !settings.onboardingComplete
            }
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

    // MARK: Migration state restore (#426)

    /// Overlays the user's Flutter per-episode state (played / inbox / position)
    /// and queue order onto the episodes now in the store, then records success
    /// so the self-heal gate won't re-run it. Shared by the full first-launch
    /// import and the state-only self-heal path. A hard failure leaves the marker
    /// unset so a later launch retries, rather than recording a half-applied
    /// overlay as done. The queue restore runs after the state overlay because a
    /// formerly-queued episode is left `newEpisode` until it's re-queued.
    @MainActor
    private func restoreEpisodeState(using migration: FlutterMigrationService) async {
        do {
            if let flutterEpisodes = migration.readEpisodes() {
                try EpisodeStateImporter(context: modelContext).apply(flutterEpisodes)
            }
            if let flutterQueue = migration.readQueue() {
                try QueueImporter(context: modelContext).apply(flutterQueue)
            }
            migration.markEpisodeStateRestored()
            // The import run completed: shells imported AND the overlay finished
            // without throwing. Stamp the status so Settings → Data shows success
            // (#429).
            migration.recordImportSucceeded()
        } catch {
            // The overlay threw: leave the "restored" marker unset so a later
            // launch retries, and record the failure for Settings → Data (#429).
            migration.recordImportFailed()
            AppLog.data.error("Migration: episode state restore failed; will retry next launch: \(error.localizedDescription, privacy: .public)")
        }
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
            await OPMLFileImporter.importFile(at: url, context: modelContext, progress: importProgress)
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
