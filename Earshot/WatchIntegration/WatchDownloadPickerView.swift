import SwiftData
import SwiftUI
import Accessibility

/// A separate phone screen keeps existing episode row actions and VoiceOver
/// order unchanged while allowing an explicit watch download selection.
struct WatchDownloadPickerView: View {
    @Environment(\.modelContext) private var context
    @State private var podcasts: [Podcast] = []
    @State private var error: String?

    var body: some View {
        List {
            Section {
                Text("Choose a podcast, then an episode. The Apple Watch downloads audio directly when it receives the request.")
            }
            ForEach(podcasts) { podcast in
                NavigationLink(podcast.displayName) {
                    WatchPodcastDownloadPickerView(podcast: podcast)
                }
            }
            if podcasts.isEmpty { Text(error ?? "No followed podcasts available") }
        }
        .navigationTitle("Apple Watch Downloads")
        .task { load() }
    }

    private func load() {
        do {
            let descriptor = FetchDescriptor<Podcast>(predicate: #Predicate { $0.isFollowed },
                                                      sortBy: [SortDescriptor(\.title)])
            podcasts = try context.fetch(descriptor)
        } catch {
            self.error = "Could not load podcasts. Try again."
        }
    }
}

private struct WatchPodcastDownloadPickerView: View {
    @Environment(\.modelContext) private var context
    let podcast: Podcast
    @State private var episodes: [Episode] = []
    @State private var search = ""
    @State private var offset = 0
    @State private var hasMore = true
    @State private var status: String?

    private var shown: [Episode] {
        episodes.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        List {
            if let status { Text(status) }
            ForEach(shown) { episode in
                Button("Download \(episode.title) on Apple Watch") {
                    let queued = PhoneWatchConnectivity.shared.queueWatchDownload(episode: episode)
                    status = queued
                        ? "Request queued for Apple Watch. Check Downloads on the watch for progress."
                        : "Apple Watch is not ready. The episode was not queued."
                    if let status { AccessibilityNotification.Announcement(status).post() }
                }
                .accessibilityHint("Requests a direct download on the paired Apple Watch")
            }
            if hasMore {
                Button("Load more episodes") { loadNextPage() }
            }
            if episodes.isEmpty { Text("No episodes available") }
        }
        .searchable(text: $search, prompt: "Filter loaded episodes")
        .navigationTitle(podcast.displayName)
        .task { if episodes.isEmpty { loadNextPage() } }
    }

    private func loadNextPage() {
        let podcastID = podcast.persistentModelID
        var descriptor = FetchDescriptor<Episode>(predicate: #Predicate {
            $0.podcast?.persistentModelID == podcastID
        }, sortBy: [SortDescriptor(\.pubDate, order: .reverse)])
        descriptor.fetchLimit = 100
        descriptor.fetchOffset = offset
        do {
            let page = try context.fetch(descriptor)
            episodes += page
            offset += page.count
            hasMore = page.count == 100
        } catch {
            status = "Could not load more episodes."
        }
    }
}
