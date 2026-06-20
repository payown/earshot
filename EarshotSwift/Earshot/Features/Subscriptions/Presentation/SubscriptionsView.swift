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
                            VStack(alignment: .leading, spacing: 2) {
                                Text(podcast.title).font(.headline)
                                Text("^[\(podcast.episodes.count) episode](inflect: true)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete(perform: delete)
                }
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

    private func delete(_ offsets: IndexSet) {
        for index in offsets { context.delete(podcasts[index]) }
        do {
            try context.save()
        } catch {
            AppLog.subscriptions.error("Failed to delete podcast: \(error.localizedDescription, privacy: .public)")
        }
    }
}
