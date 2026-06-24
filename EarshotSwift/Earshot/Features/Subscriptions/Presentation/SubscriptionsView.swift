import SwiftUI
import SwiftData

struct SubscriptionsView: View {
    @Environment(\.modelContext) private var context
    @Environment(QuickActionStore.self) private var quickActions
    @Query(sort: \Podcast.createdAt, order: .reverse) private var podcasts: [Podcast]
    @State private var showingAdd = false
    @State private var sharingPodcast: Podcast?
    @State private var pendingUnsubscribe: Podcast?

    var body: some View {
        Group {
            if podcasts.isEmpty {
                ContentUnavailableView {
                    Label("No podcasts yet", systemImage: "music.note")
                } description: {
                    Text("Add a podcast feed to get started.")
                } actions: {
                    Button("Add podcast") { showingAdd = true }
                }
            } else {
                List {
                    ForEach(podcasts) { podcast in
                        NavigationLink(value: podcast) {
                            row(for: podcast)
                        }
                    }
                    .onDelete(perform: delete)
                }
                .refreshable { await refreshAll() }
            }
        }
        .navigationTitle("Library")
        .toolbar {
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
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingAdd = true
                } label: {
                    Label("Add podcast", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAdd) { AddPodcastView() }
        .sheet(item: $sharingPodcast) { podcast in
            ShareSheet(items: shareItems(for: podcast))
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
    }

    private func row(for podcast: Podcast) -> some View {
        HStack(spacing: Spacing.md) {
            PodcastArtwork(urlString: podcast.artworkURL)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(podcast.title).font(.headline)
                if let author = podcast.author, !author.isEmpty {
                    Text(author)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text("^[\(podcast.episodes.count) episode](inflect: true)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(rowLabel(for: podcast))
        .accessibilityActions {
            ForEach(rotorActions(for: podcast)) { action in
                Button(action.label) { action.run() }
            }
        }
    }

    /// The podcast Quick Actions for the row's VoiceOver rotor, in the user's
    /// configured order. "Open podcast detail" is the NavigationLink tap (a
    /// navigation row), so it's excluded from the rotor — never add it here or it
    /// double-navigates. See SWIFTUI_PLAN.md. Unsubscribe is destructive and
    /// routes through a confirmation dialog rather than firing immediately.
    private func rotorActions(for podcast: Podcast) -> [QuickActionItem] {
        buildPodcastActions(
            podcast: podcast,
            order: quickActions.podcastActions.filter { $0 != .openDetail },
            context: context,
            onOpenDetail: {},
            onShare: { sharingPodcast = podcast },
            onUnsubscribe: { pendingUnsubscribe = podcast }
        )
    }

    private func unsubscribe(_ podcast: Podcast) {
        let title = podcast.title
        FolderRepository(context: context).removeFromAllFolders(podcast)
        context.delete(podcast)
        do {
            try context.save()
            Announcer.announce("Unfollowed \(title)")
        } catch {
            AppLog.subscriptions.error("Failed to unsubscribe: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func shareItems(for podcast: Podcast) -> [Any] {
        if let url = URL(string: podcast.feedURL) {
            return [podcast.title, url]
        }
        return [podcast.title]
    }

    private func rowLabel(for podcast: Podcast) -> String {
        var parts = [podcast.title]
        if let author = podcast.author, !author.isEmpty { parts.append(author) }
        let count = podcast.episodes.count
        parts.append("\(count) \(count == 1 ? "episode" : "episodes")")
        return parts.joined(separator: ", ")
    }

    private func delete(_ offsets: IndexSet) {
        let repo = FolderRepository(context: context)
        for index in offsets {
            let podcast = podcasts[index]
            repo.removeFromAllFolders(podcast)
            context.delete(podcast)
        }
        do {
            try context.save()
        } catch {
            AppLog.subscriptions.error("Failed to delete podcast: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func refreshAll() async {
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
        let notifications = await SubscriptionRepository(context: context).refreshAll()
        AppSettingsStore(context: context).setDate(Date(), for: SettingsKey.lastFeedRefresh)
        if !notifications.isEmpty {
            await NotificationService().deliver(notifications)
        }
        Announcer.announce("Library refreshed")
    }
}
