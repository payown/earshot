import SwiftUI
import SwiftData

/// An episode's saved bookmarks, presented as a sheet. Each row jumps playback
/// to the bookmarked position; rows are deletable. Reached from the episode
/// Quick Actions ("Bookmarks").
struct BookmarksListView: View {
    @Environment(\.modelContext) private var context
    @Environment(PlayerService.self) private var player
    @Environment(\.dismiss) private var dismiss
    let episode: Episode

    // Held in @State and reloaded after each mutation: a recomputed array off
    // `episode.bookmarks` doesn't reliably invalidate `body` when a Bookmark is
    // deleted via the VoiceOver actions rotor (the delete mutates the Bookmark,
    // not `episode`), which would leave VoiceOver focused on a stale row.
    @State private var bookmarks: [Bookmark] = []

    var body: some View {
        NavigationStack {
            Group {
                if bookmarks.isEmpty {
                    ContentUnavailableView {
                        Label("No bookmarks", systemImage: "bookmark")
                    } description: {
                        Text("Add a bookmark from the player to save a spot in this episode.")
                    }
                } else {
                    List {
                        ForEach(bookmarks) { bookmark in
                            row(for: bookmark)
                        }
                        .onDelete(perform: delete)
                    }
                }
            }
            .navigationTitle("Bookmarks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        bookmarks = BookmarkRepository(context: context).bookmarks(for: episode)
    }

    private func row(for bookmark: Bookmark) -> some View {
        Button {
            jump(to: bookmark)
        } label: {
            HStack(spacing: Spacing.md) {
                Image(systemName: "bookmark.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(bookmark.note.isEmpty ? "Bookmark" : bookmark.note)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(BookmarkLogic.clock(bookmark.positionSeconds))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(rowLabel(for: bookmark))
        .accessibilityHint("Plays from this spot")
        .accessibilityActions {
            Button("Delete bookmark") { delete(bookmark) }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                delete(bookmark)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func rowLabel(for bookmark: Bookmark) -> String {
        let position = BookmarkLogic.spoken(bookmark.positionSeconds)
        if bookmark.note.isEmpty {
            return "Bookmark at \(position)"
        }
        return "\(bookmark.note), at \(position)"
    }

    private func jump(to bookmark: Bookmark) {
        player.play(episode, at: Double(bookmark.positionSeconds))
        Announcer.announce("Playing from \(BookmarkLogic.spoken(bookmark.positionSeconds))")
        dismiss()
    }

    private func delete(_ bookmark: Bookmark) {
        BookmarkRepository(context: context).delete(bookmark)
        reload()
        Announcer.announce("Bookmark deleted")
    }

    private func delete(_ offsets: IndexSet) {
        let repo = BookmarkRepository(context: context)
        for index in offsets { repo.delete(bookmarks[index]) }
        reload()
        Announcer.announce("Bookmark deleted")
    }
}
