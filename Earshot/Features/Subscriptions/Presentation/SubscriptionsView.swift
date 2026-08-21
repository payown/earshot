import SwiftUI
import SwiftData

struct SubscriptionsView: View {
    @Environment(AppRuntime.self) private var runtime
    @Environment(\.modelContext) private var context
    @Environment(QuickActionStore.self) private var quickActions
    @Environment(SettingsStore.self) private var settings
    @Environment(DownloadManager.self) private var downloads
    @Environment(EntitlementStore.self) private var entitlements
    // A live `@Query<Podcast>` asks Core Data to populate to-many faults for the
    // inverse `episodes` relationship. On the 242K-episode device library that
    // blocks VoiceOver even though this screen never needs those episodes.
    @State private var podcasts: [Podcast] = []
    @State private var hasLoadedPodcasts = false
    @State private var showingAdd = false
    @State private var isRefreshing = false
    @State private var sharingPodcast: Podcast?
    @State private var pendingUnsubscribe: Podcast?
    // The pending "Add to folder" / "Move to folder" podcast Quick Action target
    // (#756). Non-nil presents the shared `FolderPickerView` for the single podcast.
    @State private var folderPickRequest: FolderPickRequest?
    // Multi-select (#757). `selection` drives select mode and the chosen ids;
    // `batchRequest` presents the shared picker for the whole selection.
    @State private var selection = MultiSelectState()
    @State private var batchRequest: FolderPickRequest?
    // Moves VoiceOver focus onto the list's first row when entering selection
    // mode, and re-anchors it to a still-present row after a batch or manual
    // exit — never onto a removed row. Attached to both the selectable and the
    // normal row variant, keyed on the stable PersistentIdentifier, so focus
    // rides the row across the select-mode toggle.
    @AccessibilityFocusState private var focusedRowID: PersistentIdentifier?
    @AccessibilityFocusState private var focusLaunchHeading: Bool
    // Gates the sighted-only swipe action below, mirroring Inbox's identical
    // gate: VoiceOver users already reach unfollow through the row's
    // "Unfollow" Quick Action in the rotor (`rotorActions(for:)` below), so
    // this only needs to add a second, sighted affordance — never both for the
    // same user (#597).
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    /// Library order, per the user's chosen ``LibrarySortOrder``. The `@Query`
    /// sort above is a coarse, stored-property base; both orderings are computed
    /// transforms SwiftData can't express in a `SortDescriptor`, so they run in
    /// memory. Cheap even for the largest tester libraries (low hundreds of shows).
    /// Both fall back to the article-aware alphabetical order to stay stable and
    /// deterministic (important for predictable VoiceOver focus position).
    private var sortedPodcasts: [Podcast] {
        switch settings.librarySortOrder {
        case .alphabetical:
            return podcasts.sorted { LibrarySort.titlesInOrder($0.title, $1.title) }
        case .lastPublished:
            // Sort by the stored `lastSeenPubDate` (maintained on each refresh as
            // the newest episode's pubDate) — NOT by faulting each podcast's
            // `episodes` relationship. Faulting inside the comparator iterated
            // every episode O(n log n) times on the main thread on each render,
            // which made VoiceOver sluggish for large libraries. This is a cheap
            // scalar compare. Ties and missing dates fall back to alphabetical.
            return podcasts.sorted { lhs, rhs in
                let lDate = lhs.lastSeenPubDate ?? .distantPast
                let rDate = rhs.lastSeenPubDate ?? .distantPast
                if lDate == rDate { return LibrarySort.titlesInOrder(lhs.title, rhs.title) }
                return lDate > rDate
            }
        }
    }

    var body: some View {
        // Compute cap ranking once for this render. Doing this inside `row(for:)`
        // sorted the full library once per row (quadratic work).
        let readOnlyIDs = readOnlyPodcastIDs
        Group {
            if hasLoadedPodcasts && podcasts.isEmpty {
                ContentUnavailableView {
                    Label("No podcasts yet", systemImage: "music.note")
                } description: {
                    Text("Add a podcast feed to get started.")
                } actions: {
                    Button("Add podcast") { showingAdd = true }
                }
            } else {
                List {
                    ForEach(sortedPodcasts) { podcast in
                        rowContainer(for: podcast, readOnlyIDs: readOnlyIDs)
                            // Same focus id on whichever row variant renders, so
                            // focus rides the row when select mode toggles and can
                            // be re-anchored after a batch (#757).
                            .accessibilityFocused($focusedRowID, equals: podcast.persistentModelID)
                    }
                }
                .refreshable { await performRefresh(trigger: .manualPullToRefresh) }
            }
        }
        // Persistent multi-select bar (#757): its primary button's label carries
        // the live count ("Add 3 podcasts to folder") and is the count's
        // accessibility source of truth. Only "Add" and "Move" here — "Remove
        // from folder" is folder-scoped and lives in FolderDetailScreen.
        .safeAreaInset(edge: .bottom) {
            if selection.isSelecting {
                MultiSelectBar(
                    count: selection.count,
                    primary: MultiSelectAction(
                        id: "add",
                        title: MultiSelectActionLabel.addToFolder(count: selection.count, itemSingular: "podcast"),
                        systemImage: "folder",
                        handler: { presentBatch(.add) }
                    ),
                    secondary: [
                        MultiSelectAction(
                            id: "move",
                            title: MultiSelectActionLabel.moveToFolder(count: selection.count, itemSingular: "podcast"),
                            systemImage: "folder",
                            handler: { presentBatch(.move) }
                        ),
                    ],
                    announcementNoun: "podcast"
                )
                .transition(.move(edge: .bottom))
            }
        }
        // Inline title + a `.principal` heading, matching Inbox/Queue (#490). With
        // a large title the four toolbar buttons (search, folders, sort, add) are
        // all swept before the content-area title, so "Library" was announced last;
        // the principal heading is traversed before the trailing items and carries
        // the heading trait. The plain `navigationTitle` keeps back-button identity.
        .navigationTitle("Library")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { requestLaunchHeadingFocus() }
        .onChange(of: runtime.launchFocusRequest) { _, _ in
            requestLaunchHeadingFocus()
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Library")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($focusLaunchHeading)
            }
            ToolbarItem(placement: .topBarLeading) {
                // Scoped to the user's OWN content — subscribed podcasts, episodes,
                // and bookmarks. Does NOT search the directory; finding new podcasts
                // lives behind the "Add podcast" button instead.
                NavigationLink {
                    SearchView(scope: .library)
                } label: {
                    Label("Search your library", systemImage: "magnifyingglass")
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink {
                    FoldersScreen()
                } label: {
                    Label("Folders", systemImage: "folder")
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    Task { await performRefresh(trigger: .manualToolbar) }
                } label: {
                    Label(
                        isRefreshing ? "Refreshing library" : "Refresh library",
                        systemImage: "arrow.clockwise"
                    )
                }
                .disabled(isRefreshing)
            }
            if !podcasts.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sort library", selection: Binding(
                            get: { settings.librarySortOrder },
                            set: { settings.librarySortOrder = $0 }
                        )) {
                            ForEach(LibrarySortOrder.allCases) { order in
                                Text(order.title).tag(order)
                            }
                        }
                    } label: {
                        Label("Sort library", systemImage: "arrow.up.arrow.down")
                    }
                    // Speak the active order on the menu button itself so VoiceOver
                    // users know the current sort without opening the menu.
                    .accessibilityValue(settings.librarySortOrder.title)
                }
            }
            // Enter/leave multi-select (#757). "Select" is the entry point (a
            // real Button, so it's reachable by VoiceOver swipe and rotor); while
            // selecting it becomes "Done", which exits and announces the change.
            if !podcasts.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    if selection.isSelecting {
                        Button("Done") { exitSelection(announce: true) }
                            .accessibilityHint("Leaves selection mode")
                    } else {
                        Button {
                            enterSelection()
                        } label: {
                            Label("Select podcasts", systemImage: "checkmark.circle")
                        }
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingAdd = true
                } label: {
                    Label("Add podcast", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAdd, onDismiss: loadPodcasts) { AddPodcastView() }
        .sheet(item: $sharingPodcast) { podcast in
            ShareSheet(items: shareItems(for: podcast))
        }
        .folderPicker($folderPickRequest)
        // The multi-select batch picker (#757): same shared FolderPickerView, but
        // it reports completion so we leave selection mode and re-anchor focus
        // only after a real pick (Cancel keeps the selection for a retry).
        .sheet(item: $batchRequest) { req in
            FolderPickerView(podcasts: req.podcasts, mode: req.mode) {
                finishBatch()
            }
        }
        .confirmationDialog(
            "Unfollow \(pendingUnsubscribe?.title ?? "this podcast")?",
            isPresented: Binding(
                get: { pendingUnsubscribe != nil },
                set: { if !$0 { pendingUnsubscribe = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingUnsubscribe
        ) { podcast in
            Button("Unfollow", role: .destructive) { unsubscribe(podcast) }
            Button("Cancel", role: .cancel) { pendingUnsubscribe = nil }
        } message: { podcast in
            Text("This removes \(podcast.title) and its episodes. This can't be undone.")
        }
        .navigationDestination(for: Podcast.self) { EpisodeListView(podcast: $0) }
        .task { loadPodcasts() }
        // Library intentionally avoids a live `@Query<Podcast>` because that
        // faults the inverse episode graph and froze large VoiceOver libraries.
        // Reload once after a completed CloudKit import so remote subscriptions
        // appear without polling or restoring that unbounded hot path.
        .onReceive(NotificationCenter.default.publisher(
            for: .earshotCloudKitImportDidFinish
        )) { _ in
            loadPodcasts()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: .earshotCloudProjectionDidApply
        )) { _ in
            loadPodcasts()
        }
        // Confirm the reorder for VoiceOver: the menu dismisses and the list
        // silently re-sorts, so without this the change gives no feedback. Mirrors
        // StatsScreen's period Picker. Announcer no-ops when VoiceOver is off.
        .onChange(of: settings.librarySortOrder) { _, newValue in
            Announcer.announce("Sorted by \(newValue.title)")
        }
        // Live entitlement transition (#635): the per-row "Read-only" label is a
        // passive disclosure — a user only hears it by landing on that specific
        // row. If Plus lapses (or is restored) while the Library is already open
        // (e.g. the background `Transaction.updates` listener in EntitlementStore
        // fires mid-session for an expiry/refund), several rows can flip status
        // at once with nothing telling the user it happened, unlike every other
        // consequential state change in this app (speed, sleep timer, queue
        // changes, etc., are all announced). Compare the read-only set just
        // before vs. just after the transition and announce only when it
        // actually changes the count — not on every `resync()` no-op.
        .onChange(of: entitlements.isEntitled) { oldValue, newValue in
            announceEntitlementTransitionIfNeeded(wasEntitled: oldValue, isNowEntitled: newValue)
        }
    }

    private func announceEntitlementTransitionIfNeeded(wasEntitled: Bool, isNowEntitled: Bool) {
        guard wasEntitled != isNowEntitled else { return }
        let grandfathered = AppSettingsStore(context: context).grandfatheredPodcastCount()
        let before = PodcastCapPolicy.readOnlyPodcastIDs(in: podcasts, isEntitled: wasEntitled, grandfatheredCount: grandfathered).count
        let after = PodcastCapPolicy.readOnlyPodcastIDs(in: podcasts, isEntitled: isNowEntitled, grandfatheredCount: grandfathered).count
        guard before != after else { return }
        if after > before {
            let newlyReadOnly = after - before
            let podcastPhrase = String(localized: "^[\(newlyReadOnly) podcast](inflect: true)")
            Announcer.announce(
                "Your Earshot Plus subscription has ended. \(podcastPhrase) in your library now read-only. Upgrade to Earshot Plus to make changes again.",
                assertive: true
            )
        } else {
            Announcer.announce("Your Earshot Plus subscription is active again. Your library is fully accessible.", assertive: true)
        }
    }

    /// The `persistentModelID`s of every podcast that is read-only right now
    /// because the free-tier cap (#635) is exceeded and Plus isn't active.
    /// Recomputed live off the current entitlement and podcast list — there is
    /// no persisted "read-only" flag anywhere, so resubscribing to Plus (or
    /// dropping back under the cap) restores full access immediately with no
    /// stale state to clear.
    private var readOnlyPodcastIDs: Set<PersistentIdentifier> {
        let grandfathered = AppSettingsStore(context: context).grandfatheredPodcastCount()
        return PodcastCapPolicy.readOnlyPodcastIDs(in: podcasts, isEntitled: entitlements.isEntitled, grandfatheredCount: grandfathered)
    }

    /// Whichever row variant applies: a selectable checkmark row while in
    /// selection mode (#757), otherwise the normal navigate-and-swipe row.
    @ViewBuilder
    private func rowContainer(for podcast: Podcast, readOnlyIDs: Set<PersistentIdentifier>) -> some View {
        if podcast.isDeleted {
            EmptyView()
        } else if selection.isSelecting {
            SelectableRow(
                isSelected: selection.isSelected(podcast.persistentModelID),
                accessibilityLabel: rowLabel(for: podcast, isReadOnly: readOnlyIDs.contains(podcast.persistentModelID)),
                accessibilityValue: voiceOverEnabled ? PodcastRowSpeech.value(
                    for: podcast,
                    mode: settings.spokenPodcastDescriptionMode
                ) : nil,
                onToggle: { selection.toggle(podcast.persistentModelID) }
            ) {
                rowVisual(for: podcast, readOnlyIDs: readOnlyIDs)
            }
        } else {
            normalRow(for: podcast, readOnlyIDs: readOnlyIDs)
        }
    }

    /// The normal Library row: tap to open, sighted swipes for unfollow and the
    /// inbox toggle, VoiceOver rotor Quick Actions. Unchanged from before
    /// multi-select — selection mode simply swaps it out (#757).
    @ViewBuilder
    private func normalRow(for podcast: Podcast, readOnlyIDs: Set<PersistentIdentifier>) -> some View {
        // Keep only stable enum identifiers in the row; runnable UUID/closure
        // objects are constructed for the single action activated by the user.
        let actions = rotorActions(for: podcast)
        let presentations = PodcastAction.presentations(actions, for: podcast)
        let podcastID = podcast.persistentModelID
        let performAction = { (action: PodcastAction) in
            guard PersistentModelLifetime.podcastExists(podcastID, in: context) else { return }
            perform(action, for: podcast)
        }
        let link = NavigationLink(value: podcast) {
            row(
                for: podcast,
                readOnlyIDs: readOnlyIDs,
                actions: presentations,
                performAction: performAction
            )
        }
        if voiceOverEnabled {
            link
        } else {
            // Sighted-only swipe (#597): VoiceOver's rotor Delete action,
            // generated by `.onDelete`, crashed intermittently because that API
            // assumes the row is removed synchronously within the same gesture's
            // transaction — but the confirmation dialog (#578) defers the real
            // delete to a later, disconnected gesture. `.swipeActions` carries no
            // such assumption, so it's safe to defer.
            link
                .podcastActionsContextMenu(
                    presentations, perform: performAction
                )
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        pendingUnsubscribe = podcast
                    } label: {
                        Label("Unfollow", systemImage: "xmark.bin")
                    }
                }
                // #668/#671: the only sighted affordance to opt a podcast in/out
                // of the inbox. Leading edge so it never collides with the
                // trailing Unfollow swipe; exactly one of the two modes is active.
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    if settings.inboxOptInOnly {
                        Button {
                            toggleInboxInclude(podcast)
                        } label: {
                            Label(
                                podcast.inboxIncluded ? "Remove from Inbox" : "Add to Inbox",
                                systemImage: podcast.inboxIncluded ? "tray.and.arrow.up" : "tray.and.arrow.down"
                            )
                        }
                        .tint(.accentColor)
                    } else {
                        Button {
                            toggleInboxExclude(podcast)
                        } label: {
                            Label(
                                podcast.inboxExcluded ? "Include in Inbox" : "Exclude from Inbox",
                                systemImage: podcast.inboxExcluded ? "tray.and.arrow.down" : "tray.and.arrow.up"
                            )
                        }
                        .tint(.accentColor)
                    }
                }
        }
    }

    /// Just the row's visuals — artwork, title, author, and the read-only badge —
    /// with no accessibility label or rotor. Shared by the normal row (which adds
    /// the label + Quick Actions) and the selectable row (which owns its own
    /// label + selection trait, #757).
    private func rowVisual(for podcast: Podcast, readOnlyIDs: Set<PersistentIdentifier>) -> some View {
        let isReadOnly = readOnlyIDs.contains(podcast.persistentModelID)
        return HStack(spacing: Spacing.md) {
            PodcastArtwork(urlString: podcast.artworkURL)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(podcast.title).font(.headline)
                if let author = podcast.author, !author.isEmpty {
                    Text(author)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        // Cosmetic truncation only (the author is in the row's
                        // accessibility label); two lines so large Dynamic Type
                        // isn't clipped to one.
                        .lineLimit(2)
                }
                if isReadOnly {
                    HStack(spacing: Spacing.xs) {
                        // Icon + text, not color alone (#635 / accessibility rules).
                        // The visible label is represented in the row's explicit
                        // accessibility label instead of being read twice.
                        Label("Read-only", systemImage: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
    }

    /// The normal row's accessible wrapper: one combined element carrying the
    /// full spoken label and the Quick Actions rotor.
    private func row(
        for podcast: Podcast,
        readOnlyIDs: Set<PersistentIdentifier>,
        actions: [DeferredActionPresentation<PodcastAction>],
        performAction: @escaping (PodcastAction) -> Void
    ) -> some View {
        let isReadOnly = readOnlyIDs.contains(podcast.persistentModelID)
        // The complete spoken label is supplied here, so resolving and combining
        // every Text/Image child is redundant. On a real device, rapid VoiceOver
        // navigation spent seconds rebuilding that attachment graph. Ignore the
        // decorative child tree and expose one stable row.
        return rowVisual(for: podcast, readOnlyIDs: readOnlyIDs)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(rowLabel(for: podcast, isReadOnly: isReadOnly))
            .modifier(OptionalSpokenValue(value: voiceOverEnabled ? PodcastRowSpeech.value(
                for: podcast,
                mode: settings.spokenPodcastDescriptionMode
            ) : nil))
            // Rotor order goes through the shared helper, which compensates for
            // the OS emitting `.accessibilityActions` children in reverse (#572).
            .podcastActionsRotor(actions, perform: performAction)
    }

    // MARK: Multi-select (#757)

    /// Enters selection mode: announces it, then moves VoiceOver focus to the
    /// list's first row so the user lands where they can start selecting. The
    /// focus move is deferred a beat so the selectable rows exist first.
    private func enterSelection() {
        withAnimation(Motion.preferred(.easeInOut(duration: 0.2))) {
            selection.enter()
        }
        Announcer.announce("Selection mode on")
        let firstID = sortedPodcasts.first?.persistentModelID
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            focusedRowID = firstID
        }
    }

    /// Leaves selection mode. `announce` is true for a manual "Done" (which says
    /// "Selection mode off"); a batch passes false because the picker has already
    /// announced its result — a second utterance would stack on it. Re-anchors
    /// focus to the first still-present row, never a removed one. `focusDelay`
    /// lets the batch path push the focus move (and its row-name utterance) PAST
    /// the picker's own +0.5s result announcement so the two don't collide.
    private func exitSelection(announce: Bool, focusDelay: TimeInterval = 0.5) {
        withAnimation(Motion.preferred(.easeInOut(duration: 0.2))) {
            selection.exit()
        }
        if announce {
            Announcer.announce("Selection mode off")
        }
        let firstID = sortedPodcasts.first?.persistentModelID
        DispatchQueue.main.asyncAfter(deadline: .now() + focusDelay) {
            focusedRowID = firstID
        }
    }

    /// Presents the shared picker for the whole selection. No-op with an empty
    /// selection (the bar's buttons are already disabled there).
    private func presentBatch(_ mode: FolderPickMode) {
        let selected = selectedPodcasts()
        guard !selected.isEmpty else { return }
        batchRequest = .podcasts(selected, mode: mode)
    }

    /// Called by the batch picker once it has applied the add/move. Leaves
    /// selection mode silently (the picker announced the result) — Library rows
    /// aren't removed by filing into a folder, so focus re-anchors to the first
    /// row, staggered past the picker's +0.5s result announcement.
    private func finishBatch() {
        exitSelection(announce: false, focusDelay: 0.9)
    }

    /// The selected podcasts, in the current display order.
    private func selectedPodcasts() -> [Podcast] {
        sortedPodcasts.filter { selection.isSelected($0.persistentModelID) }
    }

    /// The podcast Quick Actions for the row's VoiceOver rotor, in the user's
    /// configured order. "Open podcast detail" is the NavigationLink tap (a
    /// navigation row), so it's excluded from the rotor — never add it here or it
    /// double-navigates. See SWIFTUI_PLAN.md. Unsubscribe is destructive and
    /// routes through a confirmation dialog rather than firing immediately.
    private func rotorActions(for podcast: Podcast) -> [PodcastAction] {
        quickActions.podcastActions.filter {
            guard $0 != .openDetail else { return false }
            if $0 == .toggleInboxInclude { return settings.inboxOptInOnly }
            if $0 == .toggleInboxExclude { return !settings.inboxOptInOnly }
            return true
        }
    }

    private func perform(_ action: PodcastAction, for podcast: Podcast) {
        buildPodcastActions(
            podcast: podcast,
            // `.toggleInboxInclude` only does anything in opt-in mode (#668),
            // and `.toggleInboxExclude` only does anything in normal mode
            // (#671) — drop whichever one is inactive from the rotor entirely
            // so neither shows up as a confusing, no-effect-feeling action
            // outside its intended scope. The persisted Quick Action order
            // still lists both — this is a display-time filter, not a
            // stored-order change.
            order: [action],
            context: context,
            onOpenDetail: {},
            onShare: { sharingPodcast = podcast },
            onUnsubscribe: { pendingUnsubscribe = podcast },
            // Rotor "Add to folder" / "Move to folder" (#756): presents the
            // shared `FolderPickerView` for this single podcast. The picker files
            // it, announces, and dismisses.
            onAddToFolder: { folderPickRequest = .podcast($0, mode: .add) },
            onMoveToFolder: { folderPickRequest = .podcast($0, mode: .move) }
        ).first?.run()
    }

    /// Shared toggle+save+announce for opting a podcast into/out of the inbox
    /// while "Opt-in podcasts only" is on (#668). Used by both the leading-edge
    /// swipe action above and, indirectly via `buildPodcastActions`, the
    /// VoiceOver rotor — this one backs the swipe so the two surfaces share the
    /// exact same effect.
    private func toggleInboxInclude(_ podcast: Podcast) {
        podcast.inboxIncluded.toggle()
        savePodcastQuickAction(context, "inbox-include")
        Announcer.announce(podcast.inboxIncluded ? "Added to inbox" : "Removed from inbox")
    }

    /// Companion to `toggleInboxInclude` above for normal (non-opt-in) mode
    /// (#671). Backs the leading-edge swipe action; the VoiceOver rotor path
    /// runs the equivalent effect through `buildPodcastActions`.
    private func toggleInboxExclude(_ podcast: Podcast) {
        podcast.inboxExcluded.toggle()
        savePodcastQuickAction(context, "inbox-exclude")
        Announcer.announce(podcast.inboxExcluded ? "Excluded from inbox" : "Included in inbox")
    }

    private func unsubscribe(_ podcast: Podcast) {
        let title = podcast.title
        // Centralized unsubscribe (removeFromAllFolders + delete + save). The repo
        // logs failures; announce only on a successful delete (#499/#500).
        if SubscriptionRepository(context: context).unsubscribe(podcast) {
            podcasts.removeAll { $0.persistentModelID == podcast.persistentModelID }
            Announcer.announce("Unfollowed \(title)")
        }
    }

    private func shareItems(for podcast: Podcast) -> [Any] {
        if let url = URL(string: podcast.feedURL) {
            return [podcast.title, url]
        }
        return [podcast.title]
    }

    private func rowLabel(for podcast: Podcast, isReadOnly: Bool) -> String {
        PodcastRowSpeech.label(
            title: podcast.title,
            author: podcast.author,
            isReadOnly: isReadOnly
        )
    }

    private func performRefresh(trigger: FeedRefreshTrigger) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        Announcer.announce("Refreshing library")
        defer { isRefreshing = false }

        // Pull-to-refresh always forces (bypasses the FeedRefreshPolicy window)
        // and updates the throttle timestamp so the next background wake within
        // 15 minutes is skipped (#381).
        //
        // Capture and DELIVER the new-episode notifications this foreground pass
        // found. Because the pull stamps lastFeedRefresh, the next background
        // wake inside the 15-minute window is throttle-skipped — so whichever
        // path actually finds new episodes must be the path that notifies, or the
        // notification is lost (#421). deliver() coalesces per podcast by a stable
        // identifier, so the same show notifying from both paths can never stack.
        let report = await SubscriptionRepository(
            context: context,
            downloader: downloads,
            isEntitled: entitlements.isEntitled
        ).refreshAllReport(trigger: trigger)
        if report.completion == .full {
            AppSettingsStore(context: context).setDate(Date(), for: SettingsKey.lastFeedRefresh)
        }
        if !report.notifications.isEmpty {
            await NotificationService().deliver(report.notifications)
        }
        loadPodcasts()
        Announcer.announce(report.announcement)
    }

    /// Fetches only the scalar fields needed to construct and operate Library
    /// rows. Opening a podcast can fault its remaining fields and episodes on
    /// demand; merely entering Library cannot materialize every show's inverse
    /// episode relationship.
    private func loadPodcasts() {
        let interval = PerformanceSignposts.signposter.beginInterval("LibraryReload")
        defer { PerformanceSignposts.signposter.endInterval("LibraryReload", interval) }
        var descriptor = FetchDescriptor<Podcast>(sortBy: [SortDescriptor(\.title)])
        descriptor.propertiesToFetch = [
            \Podcast.feedURL,
            \Podcast.title,
            \Podcast.author,
            \Podcast.artworkURL,
            \Podcast.autoQueue,
            \Podcast.notificationEnabled,
            \Podcast.inboxExcluded,
            \Podcast.inboxIncluded,
            \Podcast.createdAt,
            \Podcast.lastSeenPubDate,
        ]
        podcasts = (try? context.fetch(descriptor)) ?? []
        hasLoadedPodcasts = true
    }

    private func requestLaunchHeadingFocus() {
        guard runtime.consumeLaunchFocus(.library) else { return }
        DispatchQueue.main.async { focusLaunchHeading = true }
    }
}
