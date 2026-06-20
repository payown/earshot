import SwiftUI
import SwiftData

struct AddFeedView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var urlString = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    private let samples: [(name: String, url: String)] = [
        ("NPR Up First", "https://feeds.npr.org/510318/podcast.xml"),
        ("99% Invisible", "https://feeds.simplecast.com/BqbsxVfO"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Podcast feed URL") {
                    TextField("https://...", text: $urlString)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .accessibilityLabel("Podcast feed URL")
                }

                Section("Try a sample") {
                    ForEach(samples, id: \.url) { sample in
                        Button(sample.name) { urlString = sample.url }
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .accessibilityLabel("Error: \(errorMessage)")
                    }
                }
            }
            .navigationTitle("Add podcast")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isLoading {
                        ProgressView().accessibilityLabel("Adding podcast")
                    } else {
                        Button("Add") { Task { await add() } }
                            .disabled(urlString.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
    }

    private func add() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let feed = try await FeedService().fetch(urlString)
            let podcast = Podcast(
                feedURL: urlString.trimmingCharacters(in: .whitespacesAndNewlines),
                title: feed.title.isEmpty ? "Untitled podcast" : feed.title,
                podcastDescription: feed.description,
                artworkURL: feed.artworkURL
            )
            context.insert(podcast)
            for item in feed.episodes {
                let episode = Episode(
                    guid: item.guid,
                    title: item.title,
                    audioURL: item.audioURL,
                    episodeDescription: item.description,
                    pubDate: item.pubDate
                )
                episode.podcast = podcast
                context.insert(episode)
            }
            try context.save()
            dismiss()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }
}
