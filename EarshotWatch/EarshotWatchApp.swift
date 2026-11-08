import SwiftUI

@MainActor
@Observable
final class WatchRuntime {
    let library: WatchLibrary
    let player: WatchPlayer
    let downloads: WatchDownloadManager
    let phone: WatchPhoneControl

    init() throws {
        library = try WatchLibrary()
        player = WatchPlayer(library: library)
        downloads = WatchDownloadManager(library: library)
        phone = WatchPhoneControl()
        WatchRuntimeRegistry.runtime = self
    }
}

@MainActor
enum WatchRuntimeRegistry {
    static weak var runtime: WatchRuntime?
}

@main
struct EarshotWatchApp: App {
    var body: some Scene { WindowGroup { WatchLaunchView() } }
}

struct WatchLaunchView: View {
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
    }

    private func open() {
        do {
            runtime = try WatchRuntime()
            Task { await runtime?.library.updateEntitlement() }
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
    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let episode = runtime.player.episode {
                    Section("Continue Listening") {
                        NavigationLink(episode.title) { WatchNowPlayingView(runtime: runtime) }
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
        }
        .searchable(text: $search, prompt: "Find a podcast")
        .navigationTitle("Library")
    }
}

struct WatchPodcastView: View {
    let runtime: WatchRuntime
    let podcast: WatchPodcast
    var body: some View {
        List {
            if !podcast.summary.isEmpty { Section("About") { Text(EpisodeSummary.plainText(podcast.summary)) } }
            Section("Episodes") {
                ForEach(runtime.library.episodes.filter { $0.feedURL == podcast.feedURL }) { episode in
                    WatchPlayableEpisodeRow(runtime: runtime, episode: episode)
                }
            }
            Button("Refresh podcast") { Task { await runtime.library.refresh(feedURL: podcast.feedURL) } }
            Button("Unfollow podcast", role: .destructive) { runtime.library.unsubscribe(podcast) }
        }
        .navigationTitle(podcast.title)
        .task {
            if !runtime.library.episodes.contains(where: { $0.feedURL == podcast.feedURL }) {
                await runtime.library.refresh(feedURL: podcast.feedURL)
            }
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
    enum Context { case library, inbox, queue, downloads }
    let runtime: WatchRuntime
    let episode: WatchEpisode
    var context: Context = .library

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                switch context {
                case .library:
                    playButton
                case .inbox:
                    playButton
                        .accessibilityAction(named: "Mark Played") { runtime.library.markPlayed(episode, played: true) }
                case .queue:
                    playButton
                        .accessibilityAction(named: "Move Up") { runtime.library.moveQueue(episode, offset: -1) }
                        .accessibilityAction(named: "Move Down") { runtime.library.moveQueue(episode, offset: 1) }
                        .accessibilityAction(named: "Remove from Queue") { runtime.library.removeFromQueue(episode) }
                case .downloads:
                    playButton
                        .accessibilityAction(named: "Delete Download") { runtime.downloads.delete(episode) }
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
        .accessibilityAction(named: "Play Next") { runtime.library.enqueue(episode, next: true) }
        .accessibilityAction(named: "Play Later") { runtime.library.enqueue(episode, next: false) }
    }
}

struct WatchEpisodeView: View {
    let runtime: WatchRuntime
    let episode: WatchEpisode
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
                    Button("Cancel download") { runtime.downloads.cancel(episode) }
                } else if episode.downloadFilename == nil {
                    Button("Download to Apple Watch") { runtime.downloads.start(episode) }
                } else {
                    Button("Delete download", role: .destructive) { runtime.downloads.delete(episode) }
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
}

struct WatchInboxView: View {
    let runtime: WatchRuntime
    var body: some View {
        List {
            ForEach(runtime.library.inbox) { episode in
                WatchPlayableEpisodeRow(runtime: runtime, episode: episode, context: .inbox)
            }
            if runtime.library.inbox.isEmpty { Text("No new episodes") }
        }
        .navigationTitle("Inbox")
    }
}

struct WatchQueueView: View {
    let runtime: WatchRuntime
    var body: some View {
        List {
            ForEach(runtime.library.queue) { episode in
                WatchPlayableEpisodeRow(runtime: runtime, episode: episode, context: .queue)
            }
            if runtime.library.queue.isEmpty { Text("Your queue is empty") }
        }
        .navigationTitle("Up Next")
    }
}

struct WatchDownloadsView: View {
    let runtime: WatchRuntime
    var body: some View {
        List {
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
                WatchPlayableEpisodeRow(runtime: runtime, episode: episode, context: .downloads)
            }
            if runtime.library.downloads.isEmpty { Text("No downloaded episodes") }
        }
        .navigationTitle("Downloads")
    }
}

struct WatchBookmarksView: View {
    let runtime: WatchRuntime
    var body: some View {
        List {
            ForEach(runtime.library.bookmarks) { bookmark in
                Button("\(bookmark.episodeTitle), \(Int(bookmark.positionSeconds)) seconds") {
                    if let episode = runtime.library.episodes.first(where: { $0.identity == bookmark.episodeIdentity }) {
                        Task { await runtime.player.play(episode, at: bookmark.positionSeconds) }
                    } else {
                        runtime.library.report("This bookmarked episode is not available on Apple Watch")
                    }
                }
                .accessibilityAction(named: "Delete Bookmark") { runtime.library.removeBookmark(bookmark) }
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
        }
        .navigationTitle("Settings")
    }
}
