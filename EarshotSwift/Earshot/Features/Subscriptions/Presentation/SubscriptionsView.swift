import SwiftUI
import SwiftData

struct SubscriptionsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Podcast.createdAt, order: .reverse) private var podcasts: [Podcast]
    @State private var showingAdd = false

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
        .navigationTitle("Podcasts")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingAdd = true
                } label: {
                    Label("Add podcast", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showingAdd) { AddFeedView() }
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
    }

    private func rowLabel(for podcast: Podcast) -> String {
        var parts = [podcast.title]
        if let author = podcast.author, !author.isEmpty { parts.append(author) }
        let count = podcast.episodes.count
        parts.append("\(count) \(count == 1 ? "episode" : "episodes")")
        return parts.joined(separator: ", ")
    }

    private func delete(_ offsets: IndexSet) {
        for index in offsets { context.delete(podcasts[index]) }
        do {
            try context.save()
        } catch {
            AppLog.subscriptions.error("Failed to delete podcast: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func refreshAll() async {
        await SubscriptionRepository(context: context).refreshAll()
        Announcer.announce("Podcasts refreshed")
    }
}
