import SwiftUI
import SwiftData

struct AddFeedView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(DownloadManager.self) private var downloads
    @Environment(EntitlementStore.self) private var entitlements

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
                        Button(sample.name) {
                            urlString = sample.url
                            Announcer.announce("\(sample.name) URL filled in")
                        }
                        .accessibilityHint("Fills in the feed URL")
                    }
                }

                if let errorMessage {
                    Section {
                        // Error is signalled by a red icon + default-color text, never
                        // colour alone. Bare systemRed body text is only ~3.6:1 in light
                        // mode (below AA); the icon carries the red (graphical, ≥3:1) and
                        // the message stays at label contrast (~21:1). Matches
                        // PodcastPreviewView's error pattern (#462).
                        Label {
                            Text(errorMessage)
                                .font(.callout)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(AppColor.error)
                        }
                        .accessibilityElement(children: .combine)
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
            let podcast = try await SubscriptionRepository(context: context, downloader: downloads, isEntitled: entitlements.isEntitled).subscribe(feedURL: urlString)
            Announcer.announce("Now following \(podcast.title)")
            dismiss()
        } catch {
            // Keep the raw error for diagnostics, but never surface it: a raw
            // transport string (FeedError.network) garbles VoiceOver (#688). The
            // curated message drives the visible text, the a11y label (:55), and
            // the announcement alike.
            AppLog.subscriptions.error("Add feed failed: \(error.localizedDescription, privacy: .public)")
            let message = SubscribeErrorMessage.userFacing(error)
            errorMessage = message
            Announcer.announce("Couldn't add podcast. \(message)")
        }
    }
}
