import SwiftUI

enum ListDetailLayoutPolicy {
    // The list and detail each need a readable column. Accessibility text
    // needs more room per column; a narrow window uses the same detail sheet.
    static func usesTwoPanes(width: CGFloat, accessibilityText: Bool) -> Bool {
        width >= (accessibilityText ? 1_100 : 800)
    }
}

/// In-tab episode detail. Selection never starts audio; only the Play button
/// calls the shared player service.
struct EpisodeDetailPane: View {
    let episode: Episode
    @Environment(PlayerService.self) private var player

    var body: some View {
        if episode.isDeleted {
            ContentUnavailableView("Episode unavailable", systemImage: "music.note")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    Text(episode.title)
                        .font(.title2)
                        .fontWeight(.semibold)
                        .accessibilityAddTraits(.isHeader)
                    if let podcast = episode.podcast {
                        Text(podcast.displayName)
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    if let date = episode.pubDate {
                        Text(date, style: .date)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        player.playFromEpisodeList(episode)
                    } label: {
                        Label("Play episode", systemImage: "play.fill")
                            .frame(minHeight: Spacing.minTouchTarget)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Play \(episode.title)")
                    .accessibilityHint("Starts playback immediately")
                    .accessibilityIdentifier("episode.detail.play")
                    Text("Show notes")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    ShowNotesContent(episode: episode)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .accessibilityIdentifier("episode.detail")
        }
    }
}

struct EpisodeDetailSheet: View {
    let episode: Episode
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            EpisodeDetailPane(episode: episode)
                .navigationTitle("Episode details")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

/// Show description shown before an episode is selected in the Library pane.
struct PodcastDetailPane: View {
    let podcast: Podcast

    var body: some View {
        if podcast.isDeleted {
            ContentUnavailableView("Show unavailable", systemImage: "music.note")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    Text(podcast.displayName)
                        .font(.title2)
                        .fontWeight(.semibold)
                        .accessibilityAddTraits(.isHeader)
                    Text("Show description")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    let paragraphs = EpisodeSummary.paragraphs(podcast.podcastDescription)
                    if paragraphs.isEmpty {
                        Text("No description is available for this show.")
                    } else {
                        ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                            Text(paragraph)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .accessibilityIdentifier("library.showDetail")
        }
    }
}
