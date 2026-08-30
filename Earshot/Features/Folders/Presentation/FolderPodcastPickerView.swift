import SwiftUI
import SwiftData

/// Multi-select sheet for adding podcasts to a folder. Lists podcasts not yet in
/// the folder; toggling adds or removes membership immediately so the change is
/// reflected the moment the sheet is dismissed.
struct FolderPodcastPickerView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Bindable var folder: PodcastFolder
    @Query(filter: PodcastQuery.followed, sort: \Podcast.title)
    private var podcasts: [Podcast]
    @Query private var memberships: [FolderMembership]

    var body: some View {
        NavigationStack {
            Group {
                if podcasts.isEmpty {
                    ContentUnavailableView {
                        Label("No podcasts", systemImage: "music.note")
                    } description: {
                        Text("Follow podcasts first, then add them here.")
                    }
                } else {
                    List(podcasts) { podcast in
                        row(for: podcast)
                    }
                }
            }
            .navigationTitle("Add to \(folder.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func row(for podcast: Podcast) -> some View {
        let isIn = isMember(podcast)
        return Button {
            toggle(podcast)
        } label: {
            HStack(spacing: Spacing.md) {
                PodcastArtwork(urlString: podcast.artworkURL)
                Text(podcast.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer(minLength: Spacing.sm)
                Image(systemName: isIn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isIn ? Color.accentColor : .secondary)
                    .accessibilityHidden(true)
            }
        }
        // `.isToggle` makes VoiceOver speak the on/off transition itself when the
        // row is activated, so membership state is never silent. `.isSelected`
        // reflects current state for the rotor. The visual checkmark stays as a
        // second, non-color signal.
        .accessibilityLabel(podcast.title)
        .accessibilityHint(isIn ? "Removes from folder" : "Adds to folder")
        .accessibilityAddTraits(isIn ? [.isToggle, .isSelected] : [.isToggle])
    }

    private func isMember(_ podcast: Podcast) -> Bool {
        let podcastID = podcast.persistentModelID
        let folderID = folder.persistentModelID
        return memberships.contains {
            $0.podcast?.persistentModelID == podcastID
                && $0.folder?.persistentModelID == folderID
        }
    }

    private func toggle(_ podcast: Podcast) {
        // No manual announcement here: the `.isToggle` trait makes VoiceOver
        // speak "selected"/"unselected" on activation, and a second spoken string
        // would talk over it.
        let repo = FolderRepository(context: context)
        if isMember(podcast) {
            repo.remove(podcast, from: folder)
        } else {
            repo.add(podcast, to: folder)
        }
    }
}
