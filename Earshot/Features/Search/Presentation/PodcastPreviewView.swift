import SwiftUI
import SwiftData

/// A read-only preview of an UN-subscribed directory search result (#499). Reached
/// by the primary Activate / tap on a directory row so a user can read about a show
/// — artwork, title, author, description, and the episodes exposed by its feed —
/// and decide
/// before following. The Follow / Unfollow control here mirrors the row's toggle, so
/// the user can act either from the list or from the detail.
///
/// This is deliberately NOT `EpisodeListView`: that view takes a subscribed
/// `Podcast` `@Model` and reads `podcast.episodes` from the store. A directory hit
/// has no stored podcast or episodes, so the preview fetches the feed itself (via
/// ``PodcastPreviewModel``) and shows value-type ``PreviewEpisode``s. Already-
/// subscribed results route to `EpisodeListView` upstream and never land here.
struct PodcastPreviewView: View {
    let result: PodcastSearchResult

    @Environment(\.modelContext) private var context

    /// The shared playback engine, so a preview episode can STREAM directly from
    /// here without subscribing or downloading (#517). Injected the same way the
    /// search flow injects it (see `SearchView`).
    @Environment(PlayerService.self) private var player

    /// The shared downloader, so subscribing from a preview auto-downloads the
    /// newest episodes just like following from search or the Library (#639).
    @Environment(DownloadManager.self) private var downloads

    /// Earshot Plus entitlement, for the free-tier podcast cap gate (#635).
    @Environment(EntitlementStore.self) private var entitlements

    /// Context menus are a sighted convenience. SwiftUI promotes their buttons
    /// into VoiceOver's Actions rotor, so the live environment value removes the
    /// menu while VoiceOver is running and prevents duplicate actions.
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    /// Subscriptions, so the Follow / Unfollow control reflects live state and the
    /// label flips the moment the toggle completes — without re-entering the view.
    @Query(filter: PodcastQuery.followed) private var podcasts: [Podcast]

    /// Drives the subscribe-to-folder offer (#764): the picker is only offered when
    /// the user already has at least one folder (decision F8).
    @Query private var folders: [PodcastFolder]

    @State private var model = PodcastPreviewModel()

    /// Preview-only presentation choices. They deliberately do not write the
    /// saved-podcast sort preference because auditing a feed is a separate
    /// workflow from browsing the Library.
    @State private var searchText = ""
    @State private var sortOrder: PreviewEpisodeSortOrder = .newestFirst

    /// Screen-scoped, value-only queue state. Refreshed from a single durable
    /// snapshot after committed queue notifications; no row retains SwiftData
    /// models or performs its own fetch.
    @State private var queuedEpisodeIdentities: Set<CatalogEpisodeIdentity> = []

    /// The preview owns at most one queue mutation. Leaving the screen or
    /// activating another preview action cancels a waiter before it can acquire
    /// the feed identity gate and mutate or announce on a different screen.
    @State private var queueMutationTask: Task<Void, Never>?

    /// A pending subscribe-to-folder offer (#764). Set to the just-followed podcast
    /// when folders already exist; presents the shared ``FolderPickerView`` in
    /// `.add` mode, or Cancel to skip.
    @State private var subscribeFolderPick: FolderPickRequest?

    /// Presents the Earshot Plus paywall (#632) when following this podcast
    /// would hit the free-tier cap. Set from `toggleFollow()`'s catch block,
    /// in ADDITION to the existing VoiceOver announcement.
    @State private var showPaywall = false

    private var subscribed: Bool {
        podcasts.contains { FeedURLIdentity.matches($0.feedURL, result.feedURL) }
    }

    var body: some View {
        List {
            Section { header }

            switch model.state {
            case .loading:
                loadingRow
            case .failed:
                failedRow
            case let .loaded(description, episodes):
                if let description {
                    Section("About") {
                        Text(description)
                            .font(.body)
                            .foregroundStyle(AppColor.primaryText)
                    }
                }
                if !episodes.isEmpty {
                    Section {
                        chronologicalSortButton
                    }
                    let visibleEpisodes = visibleEpisodes(from: episodes)
                    if visibleEpisodes.isEmpty {
                        Section {
                            NoSearchMatchesView(query: searchText)
                        }
                    } else {
                        Section {
                            ForEach(visibleEpisodes) { episode in
                                episodeRow(episode)
                            }
                        } header: {
                            Text("^[\(visibleEpisodes.count) available episode](inflect: true)")
                        }
                    }
                }
            }
        }
        .navigationTitle(result.title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search available episodes")
        .onSubmit(of: .search) {
            guard PreviewEpisodeSearchFilter.isActive(searchText),
                  case let .loaded(_, episodes) = model.state else { return }
            Announcer.announce(
                EpisodeSearchFilter.resultAnnouncement(count: visibleEpisodes(from: episodes).count)
            )
        }
        // Earshot Plus paywall (#632), dismissible via its own explicit Close
        // button, never drag-only.
        .sheet(isPresented: $showPaywall) { PaywallView() }
        // Subscribe-to-folder offer (#764): only presented when folders already
        // exist (decision F8, gated in `toggleFollow`). The shared picker files the
        // new show and announces the result, or Cancel skips.
        .folderPicker($subscribeFolderPick)
        .task {
            refreshQueuedEpisodeIdentities()
            await model.load(
                feedURL: result.feedURL,
                podcastTitle: result.title,
                podcastArtworkURL: result.artworkURL
            )
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .earshotQueueDidChange)
                .receive(on: DispatchQueue.main)
        ) { _ in
            refreshQueuedEpisodeIdentities()
        }
        .onDisappear {
            queueMutationTask?.cancel()
            queueMutationTask = nil
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .center, spacing: Spacing.sm) {
            PodcastArtwork(urlString: result.artworkURL, size: 120, cornerRadius: 12)
            Text(result.title)
                .font(.headline)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            if let author = result.author, !author.isEmpty {
                Text(author)
                    .font(.subheadline)
                    .foregroundStyle(AppColor.secondaryText)
                    .multilineTextAlignment(.center)
            }
            followButton
                .padding(.top, Spacing.xs)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.sm)
    }

    /// The prominent Follow / Unfollow control. A real `Button` so VoiceOver gets
    /// the correct role; the label flips with `subscribed`, and `accessibilityValue`
    /// carries the "Following" state without colour alone signalling it. Large
    /// control size keeps it past the 44pt minimum at every Dynamic Type size.
    private var followButton: some View {
        Button {
            toggleFollow()
        } label: {
            Label(
                FollowToggle.actionLabel(subscribed: subscribed),
                systemImage: subscribed ? "checkmark.circle.fill" : "plus.circle"
            )
            .frame(minHeight: Spacing.minTouchTarget)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .modifier(SubscribedAccessibilityValue(subscribed: subscribed))
        .accessibilityHint(subscribed
            ? "Unfollows this podcast"
            : "Follows this podcast and adds recent episodes to your inbox")
    }

    // MARK: Loaded content rows

    private func visibleEpisodes(from episodes: [PreviewEpisode]) -> [PreviewEpisode] {
        PreviewEpisodeSearchFilter.filter(sortOrder.sorted(episodes), query: searchText)
    }

    /// Matches the chronological toggle on a followed podcast while keeping
    /// the choice local to this preview and making its effect explicit to
    /// VoiceOver users.
    private var chronologicalSortButton: some View {
        let target = sortOrder.toggleTarget
        return Button {
            sortOrder = target
            Announcer.announce(target.announcement)
        } label: {
            Label(sortOrder.toggleTitle, systemImage: "arrow.up.arrow.down")
        }
        .accessibilityHint("Changes the available episode order without starting playback")
    }

    @ViewBuilder
    private func episodeRow(_ episode: PreviewEpisode) -> some View {
        let actions = PreviewEpisodeActions.resolved(
            audioURL: episode.audioURL,
            isQueued: episode.catalogIdentity.map(queuedEpisodeIdentities.contains) ?? false
        )
        if actions.isEmpty {
            // No enclosure URL: render a static, non-playable row so a feed missing
            // audio degrades gracefully rather than offering a dead play action.
            episodeRowContent(episode)
                .accessibilityElement(children: .combine)
        } else {
            // A Button is already a single VoiceOver element with the button trait,
            // so the one-stop-per-row requirement is preserved without combining.
            let base = Button {
                streamPreview(episode)
            } label: {
                episodeRowContent(episode)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Streams this episode")
            .stableActionsRotor(actions) { action in
                performPreviewAction(action, episode: episode)
            }
            if voiceOverEnabled {
                base
            } else {
                base.stableActionsContextMenu(actions) { action in
                    performPreviewAction(action, episode: episode)
                }
            }
        }
    }

    private func episodeRowContent(_ episode: PreviewEpisode) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(episode.title)
                .font(.body)
                .lineLimit(2)
            if let meta = episodeMeta(episode) {
                Text(meta)
                    .font(.caption)
                    .foregroundStyle(AppColor.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Visible date + length line for a preview episode. Returns nil when neither
    /// is known so no empty caption (and no dead VoiceOver value) is rendered.
    private func episodeMeta(_ episode: PreviewEpisode) -> String? {
        var parts: [String] = []
        if let date = episode.pubDate {
            parts.append(date.formatted(date: .abbreviated, time: .omitted))
        }
        if let seconds = episode.durationSeconds, seconds > 0 {
            parts.append(StatsLogic.spokenDuration(seconds))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var loadingRow: some View {
        Section {
            HStack(spacing: Spacing.sm) {
                ProgressView()
                Text("Loading episodes…")
                    .foregroundStyle(AppColor.secondaryText)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Loading episodes")
            .accessibilityAddTraits(.updatesFrequently)
        }
    }

    private var failedRow: some View {
        Section {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                // Error is signalled by icon + text, never colour alone.
                Label {
                    Text("Couldn't load this podcast. Check your connection.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(AppColor.error)
                }
                .accessibilityElement(children: .combine)
                Button {
                    Task {
                        await model.load(
                            feedURL: result.feedURL,
                            podcastTitle: result.title,
                            podcastArtworkURL: result.artworkURL
                        )
                    }
                } label: {
                    Label("Try Again", systemImage: "arrow.clockwise")
                        .frame(minWidth: Spacing.minTouchTarget, minHeight: Spacing.minTouchTarget)
                        .contentShape(Rectangle())
                }
                .accessibilityHint("Retry loading this podcast's details")
            }
        }
    }

    // MARK: Actions

    /// Streams a preview episode straight from the player engine WITHOUT
    /// subscribing, downloading, or persisting anything (#517). Falls back to the
    /// show artwork for the Now Playing surfaces when the episode has none, and
    /// passes the show title so the lock screen reads the podcast name.
    private func streamPreview(_ episode: PreviewEpisode) {
        player.playPreview(
            guid: episode.id,
            title: episode.title,
            audioURL: episode.audioURL,
            showTitle: result.title,
            episodeDescription: episode.episodeDescription,
            artworkURL: episode.artworkURL ?? result.artworkURL,
            chapterURL: episode.chapterURL,
            durationSeconds: episode.durationSeconds
        )
    }

    private func performPreviewAction(
        _ action: PreviewEpisodeAction,
        episode: PreviewEpisode
    ) {
        queueMutationTask?.cancel()
        queueMutationTask = nil

        guard action != .playNow else {
            streamPreview(episode)
            return
        }

        let currentIdentity = persistedNowPlayingIdentity()
        let repository = CatalogEpisodeQueueRepository(container: context.container)
        queueMutationTask = Task { @MainActor in
            let result: Result<CatalogEpisodeQueueOutcome, CatalogEpisodeQueueFailure>
            switch action {
            case .playNow:
                return
            case .addToQueueEnd:
                result = await repository.add(episode)
            case .removeFromQueue:
                guard let identity = episode.catalogIdentity else {
                    Announcer.announce("Couldn't remove \(episode.title) from the queue")
                    return
                }
                result = await repository.remove(identity)
            case .playNext:
                result = await repository.playNext(episode, after: currentIdentity)
            }

            // Cancellation can occur while the repository waits for the feed
            // identity gate. Never reconcile state or speak after this view has
            // disappeared or a newer action has superseded this one.
            guard !Task.isCancelled else { return }

            switch result {
            case let .success(outcome):
                if PreviewEpisodeActions.needsNoOpMembershipRefresh(after: outcome) {
                    refreshQueuedEpisodeIdentities()
                }
                if let announcement = PreviewEpisodeActions.announcement(
                    for: action,
                    outcome: outcome,
                    title: episode.title
                ) {
                    Announcer.announce(announcement)
                }
            case let .failure(failure):
                if let announcement = PreviewEpisodeActions.failureAnnouncement(
                    for: action,
                    failure: failure,
                    title: episode.title
                ) {
                    Announcer.announce(announcement)
                }
            }
        }
    }

    /// A detached preview has no Podcast relationship, so it naturally yields
    /// no persisted anchor and Play Next moves to the front. Only this value
    /// crosses the repository's async boundary.
    private func persistedNowPlayingIdentity() -> CatalogEpisodeIdentity? {
        guard let episode = player.nowPlayingEpisode,
              let feedURL = episode.podcast?.feedURL else { return nil }
        let canonicalFeedURL = FeedURLIdentity.canonical(feedURL)
        let guid = episode.guid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !canonicalFeedURL.isEmpty, !guid.isEmpty else { return nil }
        return CatalogEpisodeIdentity(feedURL: canonicalFeedURL, guid: guid)
    }

    private func refreshQueuedEpisodeIdentities() {
        do {
            queuedEpisodeIdentities = try CatalogEpisodeQueueRepository(
                container: context.container
            ).queuedEpisodeIdentities()
        } catch {
            AppLog.player.error(
                "Discovery queue membership refresh failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Follow when not subscribed, unfollow when subscribed. The `@Query` updates
    /// reactively, so the button label and value flip on completion without the
    /// user re-entering the view. Subscribe is async (it fetches and seeds the
    /// inbox); unsubscribe is a synchronous local delete.
    private func toggleFollow() {
        if let existing = podcasts.first(where: {
            FeedURLIdentity.matches($0.feedURL, result.feedURL)
        }) {
            if SubscriptionRepository(context: context).unsubscribe(existing) {
                Announcer.announce(FollowToggle.announcement(nowFollowing: false, title: result.title))
            }
        } else {
            Task {
                do {
                    let podcast = try await SubscriptionRepository(context: context, downloader: downloads, isEntitled: entitlements.isEntitled).subscribe(feedURL: result.feedURL)
                    Announcer.announce(FollowToggle.announcement(nowFollowing: true, title: result.title))
                    // Offer to file the new show only when folders already exist
                    // (decision F8, #764). The presentation is deferred ~0.6s so the
                    // "Now following" announcement lands before the sheet's
                    // .screenChanged utterance would otherwise preempt it — the
                    // presentation-side mirror of the picker's own 0.5s post-dismiss
                    // deferral. The picker announces its own outcome.
                    if FolderLogic.shouldOfferSubscribeToFolder(existingFolderCount: folders.count) {
                        try? await Task.sleep(for: .milliseconds(600))
                        subscribeFolderPick = .podcast(podcast, mode: .add)
                    }
                } catch {
                    AppLog.networking.error(
                        "Follow from preview failed for \(result.feedURL, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                    // Curated, VoiceOver-safe message — never the raw transport
                    // string (#688). The title is safe via the Announcer language-pin.
                    Announcer.announce("Couldn't follow \(result.title). \(SubscribeErrorMessage.userFacing(error))")
                    // In addition to the announcement above: an 11th-podcast
                    // attempt is exactly the moment a paywall should offer the
                    // upgrade (#632).
                    if case SubscriptionError.podcastCapReached = error {
                        showPaywall = true
                    }
                }
            }
        }
    }
}

/// Applies an `accessibilityValue` of "Following" only when subscribed. Omitting
/// the modifier entirely (rather than passing "") keeps VoiceOver from speaking an
/// empty value as a stray pause on a not-yet-followed control.
private struct SubscribedAccessibilityValue: ViewModifier {
    let subscribed: Bool

    func body(content: Content) -> some View {
        if subscribed {
            content.accessibilityValue("Following")
        } else {
            content
        }
    }
}
