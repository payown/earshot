import SwiftUI

@MainActor
@Observable
final class WatchRuntime {
    let library: WatchLibrary
    let player: WatchPlayer
    let downloads: WatchDownloadManager
    let phone: WatchPhoneControl
    let cloud: WatchCloudSync?
    let cloudOpenError: String?
    private var syncTask: Task<Void, Never>?

    init() throws {
        library = try WatchLibrary()
        library.startObservingEntitlementUpdates()
        player = WatchPlayer(library: library)
        downloads = WatchDownloadManager(library: library)
        phone = WatchPhoneControl()
        do {
            cloud = try WatchCloudSync(library: library)
            cloudOpenError = nil
        } catch {
            cloud = nil
            cloudOpenError = error.localizedDescription
            AppLog.data.error("Watch projection unavailable: \(error.localizedDescription, privacy: .public)")
        }
        library.onLocalChange = { [weak self] in self?.scheduleSync() }
        WatchRuntimeRegistry.runtime = self
        phone.processPendingDownloads(library: library, downloads: downloads)
        phone.refreshQuickActions()
    }

    func scheduleSync() {
        guard syncTask == nil else { return }
        syncTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            self?.cloud?.reconcile()
            self?.syncTask = nil
        }
    }

    func syncNow() {
        syncTask?.cancel()
        syncTask = nil
        cloud?.reconcile()
    }
}

@MainActor
enum WatchRuntimeRegistry {
    static var runtime: WatchRuntime?

    static func currentOrCreate() -> WatchRuntime? {
        if let runtime { return runtime }
        return try? WatchRuntime()
    }
}

@main
struct EarshotWatchApp: App {
    var body: some Scene { WindowGroup { WatchLaunchView() } }
}

struct WatchLaunchView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var runtime: WatchRuntime?
    @State private var launchError = false

    var body: some View {
        Group {
            if let runtime { WatchHomeView(runtime: runtime) }
            else if launchError {
                ScrollView {
                    Text("Earshot could not open its watch library. Your saved data is still on this watch.")
                    Button("Try again") { launchError = false; open() }
                }
            } else { ProgressView("Opening Earshot") }
        }
        .task { if runtime == nil && !launchError { open() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { runtime?.syncNow() }
            if phase == .background { runtime?.player.saveForLifecycle(); runtime?.syncNow() }
        }
    }

    private func open() {
        do {
            runtime = try WatchRuntimeRegistry.runtime ?? WatchRuntime()
            Task { await runtime?.library.updateEntitlement() }
            runtime?.syncNow()
        } catch {
            launchError = true
            AppLog.data.error("Watch library open failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

struct WatchHomeView: View {
    let runtime: WatchRuntime
    @Environment(\.scenePhase) private var scenePhase
    @State private var path: [String] = []
    private var recentPodcasts: [WatchPodcast] {
        let watchedFeeds = runtime.library.episodes
            .filter { $0.positionSeconds > 0 }
            .sorted { $0.updatedAt > $1.updatedAt }
            .map(\.feedURL)
        var seen = Set<String>()
        return watchedFeeds.compactMap { feed in
            guard seen.insert(feed).inserted else { return nil }
            return runtime.library.podcasts.first { $0.feedURL == feed }
        }.prefix(3).map { $0 }
    }
    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let episode = runtime.player.episode {
                    Section("Continue Listening") {
                        NavigationLink {
                            WatchNowPlayingView(runtime: runtime)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(episode.title)
                                Text("\(Int(runtime.player.positionSeconds / 60)) minutes listened")
                                    .font(.caption)
                                if runtime.player.durationSeconds > 0 {
                                    ProgressView(value: runtime.player.positionSeconds,
                                                 total: runtime.player.durationSeconds)
                                }
                            }
                        }
                        .accessibilityLabel("Continue \(episode.title)")
                        .accessibilityValue("\(Int(runtime.player.positionSeconds / 60)) minutes listened")
                    }
                }
                Section("Listening") {
                    NavigationLink("Now Playing") { WatchNowPlayingView(runtime: runtime) }
                    NavigationLink("Up Next, \(runtime.library.queue.count)") { WatchQueueView(runtime: runtime) }
                    NavigationLink("Inbox, \(runtime.library.inbox.count)") { WatchInboxView(runtime: runtime) }
                }
                Section("Podcasts") {
                    NavigationLink("Library") { WatchLibraryView(runtime: runtime) }
                        .accessibilityIdentifier("watch.library")
                    NavigationLink("Downloads, \(runtime.library.downloads.count)") { WatchDownloadsView(runtime: runtime) }
                    NavigationLink("Bookmarks, \(runtime.library.bookmarks.count)") { WatchBookmarksView(runtime: runtime) }
                    NavigationLink("Settings") { WatchSettingsView(runtime: runtime) }
                    NavigationLink("iPhone Control") { WatchPhoneControlView(runtime: runtime) }
                }
                if let conflicts = runtime.cloud?.conflicts, !conflicts.isEmpty {
                    Section("Synchronization") {
                        NavigationLink("Review \(conflicts.count) device changes") {
                            WatchSettingsView(runtime: runtime)
                        }
                    }
                }
                if !recentPodcasts.isEmpty {
                    Section("Recent podcasts") {
                        ForEach(recentPodcasts) { podcast in
                            NavigationLink(podcast.title) { WatchPodcastView(runtime: runtime, podcast: podcast) }
                        }
                    }
                }
                if !runtime.library.downloads.isEmpty {
                    Section("Ready offline") {
                        ForEach(runtime.library.downloads.prefix(3)) { episode in
                            WatchPlayableEpisodeRow(runtime: runtime, episode: episode, context: .downloads)
                        }
                    }
                }
                if let message = runtime.library.message { Text(message) }
            }
            .navigationTitle("Earshot")
            .navigationDestination(for: String.self) { destination in
                if destination == "now-playing" { WatchNowPlayingView(runtime: runtime) }
            }
            .onOpenURL { url in
                if url.scheme == "earshot-watch", url.host == "now-playing" {
                    path.append("now-playing")
                }
            }
            .onAppear(perform: openPendingDestination)
            .onReceive(NotificationCenter.default.publisher(for: WatchNavigationRequest.changed)) { _ in
                openPendingDestination()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { openPendingDestination() }
            }
        }
    }

    private func openPendingDestination() {
        guard WatchNavigationRequest.consumeNowPlaying() else { return }
        if path.last != "now-playing" { path.append("now-playing") }
    }
}

struct WatchLibraryView: View {
    let runtime: WatchRuntime
    @State private var address = ""
    @State private var search = ""
    var body: some View {
        List {
            Section("Follow a podcast") {
                TextField("Podcast feed URL", text: $address)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityHint("Enter or dictate an HTTPS RSS feed address")
                Button("Subscribe") { Task { await runtime.library.subscribe(address) } }
                    .disabled(address.isEmpty || runtime.library.isBusy)
            }
            Section("Your podcasts") {
                ForEach(runtime.library.podcasts.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }) { podcast in
                    NavigationLink(podcast.title) { WatchPodcastView(runtime: runtime, podcast: podcast) }
                        .accessibilityValue("Subscribed podcast")
                }
                if runtime.library.podcasts.isEmpty { Text("No podcasts yet. Add a feed above.") }
            }
            if let folders = runtime.cloud?.folders, !folders.isEmpty {
                Section("Folders") {
                    ForEach(folders) { folder in
                        NavigationLink(folder.name) { WatchFolderView(runtime: runtime, folder: folder) }
                    }
                }
            }
        }
        .searchable(text: $search, prompt: "Find a podcast")
        .navigationTitle("Library")
    }
}

struct WatchFolderView: View {
    let runtime: WatchRuntime
    let folder: WatchFolderSnapshot

    var body: some View {
        List {
            ForEach(folder.members.sorted { $0.sortOrder < $1.sortOrder }, id: \.feedURL) { member in
                if let podcast = runtime.library.podcasts.first(where: { FeedURLIdentity.matches($0.feedURL, member.feedURL) }) {
                    NavigationLink(podcast.title) { WatchPodcastView(runtime: runtime, podcast: podcast) }
                }
            }
            if folder.members.isEmpty { Text("No podcasts in this folder") }
        }
        .navigationTitle(folder.name)
    }
}

struct WatchPodcastView: View {
    let runtime: WatchRuntime
    let podcast: WatchPodcast
    @State private var confirmingUnfollow = false
    var body: some View {
        List {
            if !podcast.summary.isEmpty { Section("About") { Text(EpisodeSummary.plainText(podcast.summary)) } }
            Section("Episodes") {
                ForEach(runtime.library.episodes.filter { $0.feedURL == podcast.feedURL }) { episode in
                    WatchPlayableEpisodeRow(runtime: runtime, episode: episode)
                }
            }
            Button("Refresh podcast") { Task { await runtime.library.refresh(feedURL: podcast.feedURL) } }
            Button("Unfollow podcast", role: .destructive) { confirmingUnfollow = true }
        }
        .navigationTitle(podcast.title)
        .task {
            if !runtime.library.episodes.contains(where: { $0.feedURL == podcast.feedURL }) {
                await runtime.library.refresh(feedURL: podcast.feedURL)
            }
        }
        .confirmationDialog("Unfollow \(podcast.title)?", isPresented: $confirmingUnfollow) {
            Button("Unfollow", role: .destructive) { runtime.library.unsubscribe(podcast) }
        } message: {
            Text("Downloads and listening history remain on this watch.")
        }
    }
}

struct WatchEpisodeLabel: View {
    let episode: WatchEpisode
    var body: some View {
        VStack(alignment: .leading) {
            Text(episode.title)
            Text(episode.podcastTitle).font(.caption).foregroundStyle(.secondary)
            Text(episode.downloadFilename == nil ? "Streaming" : "Downloaded").font(.caption)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(episode.isPlayed ? "Played" : episode.positionSeconds > 0 ? "Partly played" : "Unplayed")
    }
}

/// The first control is Play so a VoiceOver double tap starts listening.
/// Details remains a separate, discoverable control.
struct WatchPlayableEpisodeRow: View {
    enum Context: Equatable { case library, inbox, queue, downloads }
    let runtime: WatchRuntime
    let episode: WatchEpisode
    var context: Context = .library
    var afterRemoval: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                switch context {
                case .library:
                    playButton
                case .inbox:
                    playButton
                case .queue:
                    playButton
                        .accessibilityAction(named: "Move Up") { runtime.library.moveQueue(episode, offset: -1) }
                        .accessibilityAction(named: "Move Down") { runtime.library.moveQueue(episode, offset: 1) }
                        .accessibilityAction(named: "Remove from Queue") {
                            runtime.library.removeFromQueue(episode)
                            afterRemoval?()
                        }
                case .downloads:
                    playButton
                }
            }
            NavigationLink("Episode details") {
                WatchEpisodeView(runtime: runtime, episode: episode)
            }
            .font(.caption)
            .accessibilityLabel("Details for \(episode.title)")
        }
    }

    private var playButton: some View {
        Button {
            Task { await runtime.player.play(episode) }
        } label: {
            WatchEpisodeLabel(episode: episode)
        }
        .accessibilityLabel("Play \(episode.title)")
        .accessibilityValue(episode.isPlayed ? "Played" : episode.positionSeconds > 0 ? "Partly played" : "Unplayed")
        .accessibilityHint("Plays on Apple Watch")
        .accessibilityActions {
            ForEach(orderedActions, id: \.self) { action in
                Button(label(for: action)) { perform(action) }
            }
        }
    }

    private var orderedActions: [String] {
        let supported: Set<String> = ["playNow", "addToQueueTop", "addToQueueBottom",
                                      "addToQueueFront", "download", "markPlayed", "removeFromInbox"]
        return runtime.library.episodeActionOrder.filter {
            supported.contains($0) && ($0 != "removeFromInbox" || context == .inbox)
        }
    }

    private func label(for action: String) -> String {
        switch action {
        case "playNow": "Play now"
        case "addToQueueTop": "Play next"
        case "addToQueueBottom": "Add to end of queue"
        case "addToQueueFront": "Add to top of Queue"
        case "download": episode.downloadFilename == nil ? "Download" : "Remove download"
        case "markPlayed": episode.isPlayed ? "Mark as unplayed" : "Mark as played"
        case "removeFromInbox": "Remove from Inbox"
        default: action
        }
    }

    private func perform(_ action: String) {
        switch action {
        case "playNow": Task { await runtime.player.play(episode) }
        case "addToQueueTop", "addToQueueFront": runtime.library.enqueue(episode, next: true)
        case "addToQueueBottom": runtime.library.enqueue(episode, next: false)
        case "download":
            if episode.downloadFilename == nil { runtime.downloads.start(episode) }
            else { runtime.downloads.delete(episode); afterRemoval?() }
        case "markPlayed":
            runtime.library.markPlayed(episode, played: !episode.isPlayed)
            if context == .inbox { afterRemoval?() }
        case "removeFromInbox":
            runtime.library.dismissFromInbox(episode)
            afterRemoval?()
        default: break
        }
    }
}

struct WatchEpisodeView: View {
    let runtime: WatchRuntime
    let episode: WatchEpisode
    @AccessibilityFocusState private var focusDownloadAction: Bool
    var body: some View {
        List {
            Section("Episode") {
                Text(episode.title).font(.headline)
                Text(episode.podcastTitle)
                if let date = episode.publishedAt { Text(date, format: .dateTime.month().day().year()) }
                if let duration = episode.durationSeconds { Text("Duration \(duration / 60) minutes") }
                Text(episode.downloadFilename == nil ? "Available to stream" : "Downloaded to this watch")
            }
            Section("Actions") {
                Button("Play on Apple Watch") { Task { await runtime.player.play(episode) } }
                Button("Play Next") { runtime.library.enqueue(episode, next: true) }
                Button("Play Later") { runtime.library.enqueue(episode, next: false) }
                Button(episode.isPlayed ? "Mark Unplayed" : "Mark Played") { runtime.library.markPlayed(episode, played: !episode.isPlayed) }
                if runtime.downloads.activeIDs.contains(episode.identity) {
                    ProgressView(value: runtime.downloads.progressByID[episode.identity] ?? 0)
                        .accessibilityLabel("Download progress")
                        .accessibilityValue("\(Int((runtime.downloads.progressByID[episode.identity] ?? 0) * 100)) percent")
                    Button("Cancel download") { runtime.downloads.cancel(episode); refocusDownloadAction() }
                        .accessibilityFocused($focusDownloadAction)
                } else if episode.downloadFilename == nil {
                    Button("Download to Apple Watch") { runtime.downloads.start(episode) }
                        .accessibilityFocused($focusDownloadAction)
                } else {
                    Button("Delete download", role: .destructive) {
                        runtime.downloads.delete(episode)
                        refocusDownloadAction()
                    }
                    .accessibilityFocused($focusDownloadAction)
                }
                Button("Add bookmark") { runtime.library.addBookmark(episode) }
            }
            if !episode.summary.isEmpty {
                Section("Show notes") {
                    ForEach(Array(EpisodeSummary.paragraphs(episode.summary).enumerated()), id: \.offset) { _, paragraph in
                        Text(paragraph)
                    }
                }
            }
            if let error = runtime.downloads.errorByID[episode.identity] ?? episode.downloadError { Text("Download error: \(error)") }
        }
        .navigationTitle("Episode")
    }

    private func refocusDownloadAction() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            focusDownloadAction = true
        }
    }
}

struct WatchInboxView: View {
    let runtime: WatchRuntime
    @AccessibilityFocusState private var focusHeading: Bool
    @State private var showAllUnplayed = false
    @State private var oldestFirst = false

    private var visibleEpisodes: [WatchEpisode] {
        let feeds = Set(runtime.library.podcasts.map(\.feedURL))
        let filtered = runtime.library.episodes.filter {
            !$0.isPlayed && feeds.contains($0.feedURL) && (showAllUnplayed || !$0.inboxDismissed)
        }
        return filtered.sorted {
            let lhs = $0.publishedAt ?? .distantPast
            let rhs = $1.publishedAt ?? .distantPast
            return oldestFirst ? lhs < rhs : lhs > rhs
        }
    }
    var body: some View {
        List {
            Section("Filter and order") {
                Toggle("All unplayed episodes", isOn: $showAllUnplayed)
                Toggle("Oldest first", isOn: $oldestFirst)
            }
            Text("New episodes").font(.headline).accessibilityAddTraits(.isHeader)
                .accessibilityFocused($focusHeading)
            ForEach(visibleEpisodes) { episode in
                WatchPlayableEpisodeRow(runtime: runtime, episode: episode, context: .inbox,
                                        afterRemoval: {
                                            Task { @MainActor in
                                                try? await Task.sleep(for: .milliseconds(350))
                                                focusHeading = true
                                            }
                                        })
            }
            if visibleEpisodes.isEmpty { Text(showAllUnplayed ? "No unplayed episodes" : "No new episodes") }
        }
        .navigationTitle("Inbox")
    }
}

struct WatchQueueView: View {
    let runtime: WatchRuntime
    @AccessibilityFocusState private var focusHeading: Bool
    var body: some View {
        List {
            Text("Up Next").font(.headline).accessibilityAddTraits(.isHeader)
                .accessibilityFocused($focusHeading)
            ForEach(runtime.library.queue) { episode in
                WatchPlayableEpisodeRow(runtime: runtime, episode: episode, context: .queue,
                                        afterRemoval: {
                                            Task { @MainActor in
                                                try? await Task.sleep(for: .milliseconds(350))
                                                focusHeading = true
                                            }
                                        })
            }
            if runtime.library.queue.isEmpty { Text("Your queue is empty") }
        }
        .navigationTitle("Up Next")
    }
}

struct WatchDownloadsView: View {
    let runtime: WatchRuntime
    @AccessibilityFocusState private var focusHeading: Bool
    var body: some View {
        List {
            Text("Downloads").font(.headline).accessibilityAddTraits(.isHeader)
                .accessibilityFocused($focusHeading)
            if runtime.downloads.availableBytes > 0 {
                Text("Available space: \(ByteCountFormatter.string(fromByteCount: runtime.downloads.availableBytes, countStyle: .file))")
            } else { Text("Storage information unavailable") }
            ForEach(runtime.library.episodes.filter { runtime.downloads.activeIDs.contains($0.identity) }) { episode in
                VStack(alignment: .leading) {
                    Text(episode.title)
                    ProgressView(value: runtime.downloads.progressByID[episode.identity] ?? 0)
                        .accessibilityLabel("Download progress for \(episode.title)")
                        .accessibilityValue("\(Int((runtime.downloads.progressByID[episode.identity] ?? 0) * 100)) percent")
                    Button("Cancel download") { runtime.downloads.cancel(episode) }
                }
            }
            ForEach(runtime.library.downloads) { episode in
                WatchPlayableEpisodeRow(runtime: runtime, episode: episode, context: .downloads,
                                        afterRemoval: {
                                            Task { @MainActor in
                                                try? await Task.sleep(for: .milliseconds(350))
                                                focusHeading = true
                                            }
                                        })
            }
            ForEach(runtime.library.episodes.filter { $0.downloadState == "failed" }) { episode in
                VStack(alignment: .leading) {
                    Text(episode.title)
                    Text(episode.downloadError ?? "Download failed")
                    Button("Retry download") { runtime.downloads.start(episode) }
                }
            }
            if runtime.library.downloads.isEmpty && runtime.downloads.activeIDs.isEmpty {
                Text("No downloaded episodes")
            }
        }
        .navigationTitle("Downloads")
    }
}

struct WatchBookmarksView: View {
    let runtime: WatchRuntime
    @AccessibilityFocusState private var focusHeading: Bool
    var body: some View {
        List {
            Text("Bookmarks").font(.headline).accessibilityAddTraits(.isHeader)
                .accessibilityFocused($focusHeading)
            ForEach(runtime.library.bookmarks) { bookmark in
                Button("\(bookmark.episodeTitle), \(Int(bookmark.positionSeconds)) seconds") {
                    if let episode = runtime.library.episodes.first(where: { $0.identity == bookmark.episodeIdentity }) {
                        Task { await runtime.player.play(episode, at: bookmark.positionSeconds) }
                    } else {
                        runtime.library.report("This bookmarked episode is not available on Apple Watch")
                    }
                }
                .accessibilityAction(named: "Delete Bookmark") {
                    runtime.library.removeBookmark(bookmark)
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(350))
                        focusHeading = true
                    }
                }
            }
            if runtime.library.bookmarks.isEmpty { Text("No bookmarks") }
        }
        .navigationTitle("Bookmarks")
    }
}

struct WatchSettingsView: View {
    let runtime: WatchRuntime
    var body: some View {
        List {
            @Bindable var library = runtime.library
            Stepper("Back \(library.skipBackward) seconds", value: $library.skipBackward, in: 5...60, step: 5)
            Stepper("Forward \(library.skipForward) seconds", value: $library.skipForward, in: 5...120, step: 5)
            Text(library.isPlus ? "Earshot Plus active" : "Free plan: up to 10 podcasts")
            Text("Playback on Apple Watch works without iPhone")
            Button("Synchronize now") { runtime.syncNow() }
            if let error = runtime.cloudOpenError { Text("Sync unavailable: \(error)") }
            if let error = runtime.cloud?.lastError { Text("Sync will retry: \(error)") }
            if let cloud = runtime.cloud, !cloud.conflicts.isEmpty {
                Section("Review sync changes") {
                    ForEach(cloud.conflicts, id: \.self) { conflict in Text(conflict) }
                    Button("Clear reviewed changes") { cloud.clearConflicts() }
                }
            }
        }
        .navigationTitle("Settings")
    }
}
