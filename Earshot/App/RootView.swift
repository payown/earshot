import Combine
import SwiftUI
import SwiftData

private struct PlayerCompletionDismissal: ViewModifier {
    let player: PlayerService
    let settings: SettingsStore

    func body(content: Content) -> some View {
        content.onChange(of: player.completedPlaybackStopID) { _, completionID in
            guard completionID != nil,
                  settings.dismissPlayerWhenPlaybackEnds,
                  player.pendingFullPlayerPresentation else { return }
            player.pendingFullPlayerPresentation = false
        }
    }
}

private struct CleartextPlaybackWarningPresenter: ViewModifier {
    let player: PlayerService

    private var isPresented: Binding<Bool> {
        Binding(
            get: { player.pendingCleartextPlaybackWarning != nil },
            set: { isPresented in
                if !isPresented, player.pendingCleartextPlaybackWarning != nil {
                    player.cancelPendingCleartextPlayback()
                }
            }
        )
    }

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Unsecured audio connection",
            isPresented: isPresented,
            titleVisibility: .visible
        ) {
            Button("Play episode") { player.approvePendingCleartextPlayback() }
            Button("Cancel", role: .cancel) { player.cancelPendingCleartextPlayback() }
        } message: {
            Text(CleartextPlaybackWarning.message)
        }
    }
}
import UIKit

/// Owns the Inbox badge count separately from RootView so changing playback
/// position cannot make RootView evaluate Inbox relationships.
///
/// It does NOT use a live `@Query`, and it deliberately does NOT observe
/// `ModelContext.didSave` (#736). A `@Query` re-materializes its whole result
/// set on every context save, and `PlayerService` saves the playback position
/// every ~5 seconds — so on a large library the badge was fetching and filtering
/// the entire unplayed backlog ~18 times a minute during playback, sustained
/// main-thread CPU that ran the phone hot. `#732`'s `playedAt == nil` bound
/// stopped the earlier `cpu_resource_fatal` crash but left that residual cost.
///
/// Instead the count is recomputed ONLY on the events that can actually change
/// it — an explicit `.earshotInboxDidChange` (ingest, play, dismiss, caps), a
/// queue change, opt-in-mode change, and app-foreground (which self-heals any
/// signal we didn't get). A playback-position save triggers nothing here, so the
/// badge does zero work on the hot path. On a tab switch the native badge is
/// re-asserted from the cached count (SwiftData rebuilds the tab items and drops
/// the manually set `badgeValue`) — a pure UIKit re-apply, no store work.
private struct InboxTabBadge: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    let optInOnly: Bool
    let selectedTab: RootTab?

    @State private var count = 0

    var body: some View {
        TabBarBadgeApplier(tabIndex: 0, count: count)
            .onAppear { recompute() }
            .onChange(of: optInOnly) { _, _ in recompute() }
            // Foreground heals any inbox change we didn't get an explicit signal
            // for (a background feed refresh, a podcast include/exclude).
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { recompute() }
            }
            // Re-assert the native badge after a tab switch drops it. No store
            // work — just re-apply the cached count.
            .onChange(of: selectedTab) { _, _ in
                TabBarBadgeApplier.apply(tabIndex: 0, count: count)
            }
            // Recompute only on real inbox changes — never on a position save.
            // Delivered on main since a background context can post these.
            .onReceive(NotificationCenter.default.publisher(for: .earshotInboxDidChange).receive(on: DispatchQueue.main)) { _ in
                recompute()
            }
            .onReceive(NotificationCenter.default.publisher(for: .earshotQueueDidChange).receive(on: DispatchQueue.main)) { _ in
                recompute()
            }
    }

    private func recompute() {
        let interval = PerformanceSignposts.signposter.beginInterval("InboxReload")
        defer { PerformanceSignposts.signposter.endInterval("InboxReload", interval) }
        count = InboxRepository(context: context).inboxCount(optInOnly: optInOnly)
    }
}

struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppRuntime.self) private var runtime
    @Environment(PlayerService.self) private var player
    @Environment(QuickActionStore.self) private var quickActions
    @Environment(DownloadManager.self) private var downloads
    @Environment(SettingsStore.self) private var settings
    @Environment(TipsStore.self) private var tips
    @Environment(OPMLImportProgress.self) private var importProgress
    @Environment(OPMLImportCoordinator.self) private var opmlImportCoordinator
    @Environment(NotificationRouter.self) private var notificationRouter
    @Environment(EntitlementStore.self) private var entitlements

    @State private var showOnboarding = false
    @State private var showOPMLPaywall = false
    @State private var resumeImportAfterPaywall = false
    @State private var confirmOPMLReplacement = false
    @State private var rootServicesActivated = false

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
    /// Item-driven folder destination used by Now Playing's "Playing from"
    /// route. Kept beside (not inside) the podcast-typed path so existing
    /// notification and screenshot podcast routing stays unchanged.
    @State private var libraryFolderDestination: PodcastFolder?

    /// Drives the app-background durability anchor for playback position/stats
    /// (#736): the ~5s tick no longer writes to the store, so persist on
    /// background instead.
    @Environment(\.scenePhase) private var scenePhase

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
                    .navigationDestination(item: $libraryFolderDestination) { folder in
                        FolderDetailScreen(folder: folder)
                    }
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
        // On iOS 26, make the player a native persistent tab accessory. Unlike
        // a per-tab safe-area inset, the system owns its geometry relative to
        // the floating tab bar, so VoiceOver Explore by Touch finds the player
        // where it is visibly presented (#840).
        .modifier(TabPlayerAccessory())
        // Native UITabBarItem badge for the Inbox unread count (#321 follow-up):
        // re-applies whenever `inboxBadgeCount` changes. Replaces SwiftUI's
        // `.badge`, which double-announced the count under VoiceOver.
        .background(InboxTabBadge(optInOnly: settings.inboxOptInOnly, selectedTab: selectedTab))
        // Native UITabBarItem badge for the Queue episode count (#491): same
        // mechanism and VoiceOver folding as the Inbox badge above, on tab 1.
        .background(TabBarBadgeApplier(tabIndex: 1, count: queueBadgeCount))
        // Route a notification tap / action into the Library tab + podcast detail
        // (#72). Reacting on the published intent keeps the delegate decoupled
        // from the view tree.
        .onChange(of: notificationRouter.pendingIntent) { _, intent in
            if let intent { route(intent) }
        }
        // The app host owns Open-in routing so a file handed to Earshot before
        // the data-bound root exists is retained. Consume it once this final
        // container's RootView is ready (#781).
        .onChange(of: runtime.pendingIncomingFileURL) { _, url in
            if url != nil, rootServicesActivated { handlePendingIncomingFile() }
        }
        .onChange(of: opmlImportCoordinator.state) { _, state in
            if case .readyToImport = state, rootServicesActivated { continuePendingOPMLImport() }
            if case .replacementRequested = state { confirmOPMLReplacement = true }
        }
        .confirmationDialog(
            "Replace pending OPML import?",
            isPresented: $confirmOPMLReplacement,
            titleVisibility: .visible
        ) {
            Button("Replace pending import", role: .destructive) {
                Task { try? await opmlImportCoordinator.confirmReplacement() }
            }
            Button("Keep pending import", role: .cancel) {
                opmlImportCoordinator.cancelReplacement()
            }
        } message: {
            Text("Earshot can keep one OPML file ready to continue. Replacing it discards the currently pending file.")
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
        // Durably persist playback position + listening stats when the app goes
        // to the background (#736). The ~5s playback tick no longer writes to the
        // store — it records to UserDefaults — so this is the anchor that flushes
        // to SwiftData when the user locks the phone or switches apps.
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { player.persistForBackground() }
        }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView()
                // Designed-for-iPhone apps on macOS host full-screen covers in
                // a separate presentation graph. Inject the shared observable
                // services explicitly so first-launch onboarding cannot lose
                // them while that graph is being constructed.
                .environment(runtime)
                .environment(settings)
                .environment(importProgress)
                .environment(opmlImportCoordinator)
                .environment(downloads)
                .environment(entitlements)
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
        .modifier(PlayerCompletionDismissal(player: player, settings: settings))
        .modifier(CleartextPlaybackWarningPresenter(player: player))
        .sheet(isPresented: $showOPMLPaywall, onDismiss: {
            guard resumeImportAfterPaywall else { return }
            resumeImportAfterPaywall = false
            continuePendingOPMLImport()
        }) {
            PaywallView(showsRestorePurchases: true)
        }
        .onChange(of: entitlements.isEntitled) { wasEntitled, isEntitled in
            guard !wasEntitled, isEntitled, showOPMLPaywall,
                  opmlImportCoordinator.pendingImport?.stopReason == .freeTierLimit else { return }
            resumeImportAfterPaywall = true
            showOPMLPaywall = false
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
        .onReceive(
            NotificationCenter.default.publisher(for: .earshotCloudProjectionDidApply)
        ) { _ in
            settings.configure(context: modelContext)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .earshotFolderSyncConflictRepaired)
        ) { _ in
            Announcer.announce("A folder sync conflict was repaired.")
        }
        .task { await activateRoot() }
        // A separate view-owned task keeps the legacy cleanup off the critical
        // root-activation path and automatically cancels it if this container's
        // RootView disappears during recovery/reset. Each batch is already
        // durable, so the next RootView or launch safely resumes (#729).
        .task(id: rootServicesActivated) {
            guard rootServicesActivated else { return }
            await dismissLegacyPlayedInboxRows()
        }
        // Keep this outermost so RootView-owned presentations, especially the
        // automatic Now Playing sheet above, inherit the folder route as well as
        // the tab content. Placing it directly on TabView hides the origin button
        // in that sheet because the sheet sees the unavailable default action.
        .environment(
            \.playbackFolderNavigation,
            PlaybackFolderNavigationAction { folderID in
                routeToPlaybackFolder(folderID)
            }
        )
    }

    private func activateRoot() async {
        let activationCompleted = await runtime.activateRootServices(for: modelContext.container) {
            runtime.bindRootServicesIfNeeded(to: modelContext.container) {
                #if DEBUG
                if ScreenshotHarness.isSeeding { ScreenshotFixtures.seed(into: modelContext) }
                #endif
                player.configure(context: modelContext)
                quickActions.configure(context: modelContext)
                downloads.configure(context: modelContext)
            }
            try Task.checkCancellation()
            await downloads.reconcileStuckDownloads()
            try Task.checkCancellation()
            await downloads.reconcileDownloadPaths()
            try Task.checkCancellation()
            settings.configure(context: modelContext)
            runtime.listeningPlaces.configure(context: modelContext)
            let capSettings = AppSettingsStore(context: modelContext)
            let count = (try? modelContext.fetchCount(FetchDescriptor<Podcast>())) ?? 0
            capSettings.introducePodcastCapGatingIfNeeded(currentPodcastCount: count)
            tips.configure(context: modelContext)
            #if DEBUG
            if !ScreenshotHarness.isActive {
                ExpirationService(context: modelContext).runExpiration()
            }
            #else
            ExpirationService(context: modelContext).runExpiration()
            #endif
            try await runtime.activateCloudProjectionIfNeeded(container: modelContext.container)
            StatsRepository(context: modelContext).applyRetention(days: settings.historyRetentionDays)
            PlaybackStartup.restoreLastEpisode(into: player, context: modelContext)
        }
        guard activationCompleted else { return }
        if selectedTab == nil { selectedTab = RootTab(launchScreen: settings.launchScreen) }
        showOnboarding = !settings.onboardingComplete
        #if DEBUG
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
        if let intent = notificationRouter.pendingIntent { route(intent) }
        await opmlImportCoordinator.restorePendingImport()
        rootServicesActivated = true
        handlePendingIncomingFile()
    }

    private func dismissLegacyPlayedInboxRows() async {
        let maintenance = await InboxHistoryMaintenance.makeBackground(
            modelContainer: modelContext.container
        )
        do {
            let report = try await maintenance.dismissPlayedEpisodes()
            if report.dismissed > 0 {
                AppLog.data.info(
                    "Dismissed \(report.dismissed) legacy played Inbox rows in \(report.batches) batches (#729)"
                )
                NotificationCenter.default.post(name: .earshotInboxDidChange, object: nil)
            }
        } catch is CancellationError {
            AppLog.data.info(
                "Legacy played Inbox cleanup paused; durable progress will resume next launch (#729)"
            )
        } catch {
            AppLog.data.error(
                "Legacy played Inbox cleanup failed and will retry next launch: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: Launch tab (#492)

    /// Resolves the live folder only when the player requests navigation. The
    /// Now Playing control already disappears when its query cannot resolve the
    /// origin; this second guard closes a deletion race during modal dismissal.
    private func routeToPlaybackFolder(_ folderID: PersistentIdentifier) {
        guard let folder = FolderRepository(context: modelContext).folders().first(where: {
            $0.persistentModelID == folderID
        }) else { return }

        selectedTab = .library
        libraryPath = []
        libraryFolderDestination = nil
        DispatchQueue.main.async {
            libraryFolderDestination = folder
        }
    }

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

    private func handlePendingIncomingFile() {
        guard let url = runtime.takePendingIncomingFile() else { return }
        handleIncomingFile(url)
    }

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
            await OPMLFileImporter.stageFile(at: url, coordinator: opmlImportCoordinator)
        }
    }

    private func continuePendingOPMLImport() {
        guard !importProgress.isImporting else { return }
        Task {
            let result = await OPMLFileImporter.continuePendingImport(
                coordinator: opmlImportCoordinator,
                context: modelContext,
                progress: importProgress,
                downloader: downloads,
                isEntitled: entitlements.isEntitled
            )
            if case .pending(_, .freeTierLimit) = result, !entitlements.isEntitled {
                showOPMLPaywall = true
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

        guard let podcast = try? PodcastIdentityService(context: modelContext)
            .existing(feedURL: intent.feedURL) else {
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
                player.playWithHandoff(episode)
            }
        }

        // Switch to Library and push the podcast detail. Reset the path first so
        // we always land on the show's detail, not stacked atop a prior push.
        selectedTab = .library
        libraryPath = [podcast]
    }

    /// Finds an episode by guid within a podcast's loaded episodes.
    private func episode(guid: String, in podcast: Podcast) -> Episode? {
        podcast.episodes?.first { $0.guid == guid }
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

/// Per-tab chrome for systems before iOS 26. The legacy mini-player inset stays
/// on each tab's `NavigationStack`; attaching that inset to the `TabView` itself
/// overlaps and hides the system tab bar (#366). iOS 26 instead uses the native
/// `tabViewBottomAccessory` installed by ``TabPlayerAccessory`` below (#840).
private struct TabChrome: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            // The TabView-level accessory supplies the mini player on iOS 26.
            // Keep the content priority that established the desired flick
            // order in #730 without creating five hidden player instances.
            content
                .accessibilitySortPriority(1)
        } else {
            content
            // Reading order (#730): the mini player sits visually at the BOTTOM
            // (just above the tab bar) and touch exploration finds it there, but
            // safeAreaInset content is declared first, so VoiceOver flick order
            // announced it FIRST. The inset content and this tab content are
            // same-container peers; VoiceOver orders peers by DESCENDING sort
            // priority, so giving the whole tab content a higher priority than
            // the bar (0, below) makes flick order match the visual bottom
            // placement — content first, "Now Playing" group last. This modifier
            // MUST come before .safeAreaInset so it lands on the content node,
            // not on the combined composite (which would tag both equally).
            .accessibilitySortPriority(1)
            .safeAreaInset(edge: .bottom) {
                NowPlayingBar()
                    // Read LAST, after the tab's content (priority 1 above).
                    .accessibilitySortPriority(0)
            }
        }
    }
}

/// Hosts the mini player in the system-managed tab accessory introduced in
/// iOS 26. Earlier systems retain the proven per-tab safe-area inset above.
private struct TabPlayerAccessory: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .tabViewBottomAccessory {
                    NowPlayingBar()
                        .accessibilitySortPriority(0)
                }
        } else {
            content
        }
    }
}
