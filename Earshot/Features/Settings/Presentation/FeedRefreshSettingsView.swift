import SwiftUI
import SwiftData

private enum FeedRefreshPodcastQuickActionEditor: Identifiable {
    case downloadCount
    case podcast(Podcast, focus: PodcastSettingsFocus)

    var id: String {
        switch self {
        case .downloadCount:
            "download-count"
        case let .podcast(podcast, focus):
            "\(podcast.persistentModelID)-\(String(describing: focus))"
        }
    }
}

struct FeedRefreshInlineStatus: View {
    let snapshot: FeedRefreshStatusSnapshot

    static func shouldShow(_ snapshot: FeedRefreshStatusSnapshot) -> Bool {
        switch snapshot.state {
        case .running, .completedWithErrors, .interrupted, .failed:
            true
        case .never, .completed:
            false
        }
    }

    var body: some View {
        HStack(spacing: Spacing.md) {
            if snapshot.state == .running {
                ProgressView(value: Double(snapshot.checked), total: Double(max(snapshot.total, 1)))
                    .progressViewStyle(.circular)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Text(spokenText)
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
        .background(.regularMaterial)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenText)
    }

    var spokenText: String {
        switch snapshot.state {
        case .running:
            "Refreshing podcasts. \(snapshot.checked) of \(snapshot.total) checked. \(snapshot.newEpisodes) new episodes found."
        case .completedWithErrors:
            "Refresh completed with \(snapshot.failedFeeds) feed \(snapshot.failedFeeds == 1 ? "error" : "errors")."
        case .interrupted:
            "Refresh was interrupted after checking \(snapshot.checked) of \(snapshot.total) podcasts."
        case .failed:
            "Refresh failed. \(snapshot.failedFeeds) \(snapshot.failedFeeds == 1 ? "feed" : "feeds") failed."
        case .never, .completed:
            ""
        }
    }
}

struct FeedRefreshSettingsView: View {
    @Environment(AppRuntime.self) private var runtime
    @Environment(QuickActionStore.self) private var quickActions
    @Environment(SettingsStore.self) private var settings
    @Environment(\.modelContext) private var context

    @State private var failedPodcasts: [String: Podcast] = [:]
    @State private var pendingUnfollow: Podcast?
    @State private var sharingPodcast: Podcast?
    @State private var quickActionEditor: FeedRefreshPodcastQuickActionEditor?
    @State private var folderPickRequest: FolderPickRequest?

    var body: some View {
        let snapshot = runtime.feedRefreshStatus.snapshot
        Form {
            Section("Latest refresh") {
                Text(summary(snapshot))
                    .accessibilityLabel(summary(snapshot))

                LabeledContent("Status", value: FeedRefreshStatusPresentation.status(snapshot.state))
                LabeledContent("Started", value: dateText(snapshot.startedAt))
                LabeledContent("Finished", value: dateText(snapshot.endedAt))
                LabeledContent("Last completed", value: dateText(snapshot.lastCompletedAt))
                if let lastSkippedAt = snapshot.lastSkippedAt,
                   let trigger = snapshot.lastSkippedTrigger {
                    LabeledContent(
                        "Last check skipped",
                        value: "\(dateText(lastSkippedAt)), \(FeedRefreshStatusPresentation.trigger(trigger)), refresh was already recent"
                    )
                }
                LabeledContent("Refresh type", value: FeedRefreshStatusPresentation.trigger(snapshot.trigger))
                LabeledContent("Podcasts checked", value: "\(snapshot.checked) of \(snapshot.total)")
                LabeledContent("New episodes", value: "\(snapshot.newEpisodes)")
                LabeledContent("Unchanged feeds", value: "\(snapshot.unchangedFeeds)")
                LabeledContent("Failed feeds", value: "\(snapshot.failedFeeds)")
            }

            if !snapshot.failureDetails.isEmpty {
                Section("Feeds needing attention") {
                    ForEach(snapshot.failureDetails) { failure in
                        failedFeedRow(failure)
                    }
                }
            }

            Section("Background refresh") {
                Text(FeedRefreshStatusPresentation.scheduled(snapshot.scheduledAt) { dateText($0) })
                    .accessibilityLabel(
                        FeedRefreshStatusPresentation.scheduled(snapshot.scheduledAt) { dateText($0) }
                    )
                Text("iOS decides when Earshot runs in the background. A requested time is not a promised refresh time. Opening Earshot or using Refresh Library can start an eligible check sooner.")
                    .font(.footnote)
                    .foregroundStyle(AppColor.secondaryText)
            }
        }
        .navigationTitle("Feed Refresh")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: Podcast.self) { EpisodeListView(podcast: $0) }
        .task { loadFailedPodcasts() }
        .onChange(of: snapshot.failureDetails) { _, _ in loadFailedPodcasts() }
        .confirmationDialog(
            "Unfollow \(pendingUnfollow?.title ?? "this podcast")?",
            isPresented: Binding(
                get: { pendingUnfollow != nil },
                set: { if !$0 { pendingUnfollow = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingUnfollow
        ) { podcast in
            Button("Unfollow", role: .destructive) { unfollow(podcast) }
            Button("Cancel", role: .cancel) { pendingUnfollow = nil }
        } message: { podcast in
            Text("This removes \(podcast.title) and its episodes. This can't be undone.")
        }
        .sheet(item: $sharingPodcast) { podcast in
            ShareSheet(items: shareItems(for: podcast))
        }
        .sheet(item: $quickActionEditor) { editor in
            switch editor {
            case .downloadCount:
                NavigationStack {
                    DownloadsSettingsView(
                        initialFocus: .autoDownloadCount,
                        showsDoneButton: true
                    )
                }
            case let .podcast(podcast, focus):
                PodcastSettingsView(podcast: podcast, initialFocus: focus)
            }
        }
        .folderPicker($folderPickRequest)
    }

    @ViewBuilder
    private func failedFeedRow(_ failure: FeedRefreshFailure) -> some View {
        if let podcast = failedPodcasts[failure.id] {
            let actions = podcastActions(for: podcast)
            let presentations = PodcastAction.presentations(actions, for: podcast)
            let performAction = { (action: PodcastAction) in perform(action, for: podcast) }
            NavigationLink(value: podcast) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(failure.podcastTitle)
                        .font(.headline)
                    Text(failure.reason)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(failure.podcastTitle). Refresh failed. \(failure.reason)")
                .podcastActionsRotor(presentations, perform: performAction)
            }
            .podcastActionsContextMenu(presentations, perform: performAction)
        } else {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(failure.podcastTitle)
                    .font(.headline)
                Text(failure.reason)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func podcastActions(for podcast: Podcast) -> [PodcastAction] {
        visiblePodcastRowActions(
            quickActions.podcastActions,
            inboxOptInOnly: settings.inboxOptInOnly
        )
    }

    private func perform(_ action: PodcastAction, for podcast: Podcast) {
        buildPodcastActions(
            podcast: podcast,
            order: [action],
            context: context,
            onOpenDetail: {},
            onShare: { sharingPodcast = podcast },
            onUnsubscribe: { pendingUnfollow = podcast },
            onChangeDownloadCount: { quickActionEditor = .downloadCount },
            onChangeQueueAgeLimit: {
                quickActionEditor = .podcast($0, focus: .queueAgeLimit)
            },
            onEditPodcastSpeed: {
                quickActionEditor = .podcast($0, focus: .playbackSpeed)
            },
            onAddToFolder: { folderPickRequest = .podcast($0, mode: .add) },
            onMoveToFolder: { folderPickRequest = .podcast($0, mode: .move) }
        ).first?.run()
    }

    private func unfollow(_ podcast: Podcast) {
        let title = podcast.title
        let feedURL = podcast.feedURL
        guard SubscriptionRepository(context: context).unsubscribe(podcast) else { return }
        failedPodcasts.removeValue(forKey: FeedURLIdentity.canonical(feedURL))
        runtime.feedRefreshStatus.removeFailure(feedURL: feedURL)
        pendingUnfollow = nil
        Announcer.announce("Unfollowed \(title)")
    }

    private func loadFailedPodcasts() {
        var loaded: [String: Podcast] = [:]
        for failure in runtime.feedRefreshStatus.snapshot.failureDetails {
            guard let podcast = try? PodcastIdentityService(context: context)
                .existingFollowed(feedURL: failure.feedURL) else { continue }
            loaded[failure.id] = podcast
        }
        failedPodcasts = loaded
    }

    private func shareItems(for podcast: Podcast) -> [Any] {
        guard let url = URL(string: podcast.feedURL) else { return [podcast.title] }
        return [podcast.title, url]
    }

    private func summary(_ snapshot: FeedRefreshStatusSnapshot) -> String {
        FeedRefreshStatusPresentation.summary(snapshot) { dateText($0) }
    }

    private func dateText(_ date: Date?) -> String {
        guard let date else { return "Not available" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
