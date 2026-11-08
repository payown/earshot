import SwiftUI
import SwiftData

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
    let onPlay: (() -> Void)?
    @Environment(PlayerService.self) private var player
    @Environment(\.modelContext) private var context

    init(episode: Episode, onPlay: (() -> Void)? = nil) {
        self.episode = episode
        self.onPlay = onPlay
    }

    var body: some View {
        if !PersistentModelLifetime.episodeExists(episode.persistentModelID, in: context) || episode.isDeleted {
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
                        guard PersistentModelLifetime.episodeExists(episode.persistentModelID, in: context) else { return }
                        if let onPlay { onPlay() } else { player.playFromEpisodeList(episode) }
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
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding()
            }
            .accessibilityIdentifier("episode.detail")
        }
    }
}

struct EpisodeDetailSheet: View {
    let episode: Episode
    let onPlay: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            EpisodeDetailPane(episode: episode, onPlay: onPlay)
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

private struct EpisodeDetailSheetModifier: ViewModifier {
    @Binding var episode: Episode?
    @State private var pendingPlayID: PersistentIdentifier?
    @Environment(\.modelContext) private var context
    @Environment(PlayerService.self) private var player

    func body(content: Content) -> some View {
        content.sheet(item: $episode, onDismiss: {
            guard let id = pendingPlayID else { return }
            pendingPlayID = nil
            guard PersistentModelLifetime.episodeExists(id, in: context),
                  let liveEpisode = context.model(for: id) as? Episode else { return }
            player.playFromEpisodeList(liveEpisode)
        }) { selected in
            EpisodeDetailSheet(episode: selected) {
                pendingPlayID = selected.persistentModelID
                episode = nil
            }
        }
    }
}

extension View {
    func episodeDetailSheet(_ episode: Binding<Episode?>) -> some View {
        modifier(EpisodeDetailSheetModifier(episode: episode))
    }
}

/// Clears retained detail selections before a model deletion or reset can
/// leave a view holding a detached SwiftData object.
enum EpisodeDetailSelection {
    static func isAffected(_ episode: Episode?, by note: Notification, in context: ModelContext) -> Bool {
        guard let episode else { return false }
        let id = episode.persistentModelID
        if !PersistentModelLifetime.episodeExists(id, in: context) { return true }
        if let ids = note.userInfo?[PlayerService.willDeleteEpisodeIDsKey] as? Set<PersistentIdentifier>,
           ids.contains(id) { return true }
        if let podcastID = note.userInfo?[PlayerService.willDeletePodcastIDKey] as? PersistentIdentifier {
            return episode.podcast?.persistentModelID == podcastID
        }
        return note.userInfo?[PlayerService.willDeleteEpisodeIDsKey] == nil
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
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding()
            }
            .accessibilityIdentifier("library.showDetail")
        }
    }
}
