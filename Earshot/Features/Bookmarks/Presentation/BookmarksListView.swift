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

    // The share-text payload for a bookmark, driving a `.sheet(item:)` so the
    // system share sheet presents over this view. Plain text (not a deep link):
    // there's no episode deep-link handler in SwiftUI yet (#383).
    @State private var shareItem: BookmarkShareItem?

    // Tracked by SwiftUI, so toggling VoiceOver while this sheet is open
    // re-renders the rows and attaches/removes the sighted-only swipe actions
    // immediately. Mirrors the Queue's SightedRowActions / Inbox gate (#573):
    // iOS mirrors swipe actions into the VoiceOver rotor, which duplicated the
    // rows' custom Share/Delete actions (#577).
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

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
                        // Sighted-only, like the explicit swipes below: with the
                        // custom swipes gated off under VoiceOver, an ungated
                        // `.onDelete` would surface its own system delete swipe
                        // and mirror a second "Delete" into the rotor (#577).
                        .onDelete(perform: voiceOverEnabled ? nil : { delete($0) })
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
            .sheet(item: $shareItem) { item in
                ShareSheet(items: [item.text])
            }
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        bookmarks = BookmarkRepository(context: context).bookmarks(for: episode)
    }

    @ViewBuilder
    private func row(for bookmark: Bookmark) -> some View {
        let base = HStack(spacing: Spacing.md) {
            // The jump target: the label area. Tapping (or activating with
            // VoiceOver) plays from the bookmarked spot.
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
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // The jump Button is already a single VoiceOver element with the
            // button trait, carrying the explicit label below plus delete/share as
            // custom rotor actions. No `.accessibilityElement(children: .combine)`
            // is needed — combining re-walked and merged the label subtree only for
            // the explicit `.accessibilityLabel` to discard it. The visible share
            // button below stays hidden from VoiceOver to avoid a duplicate stop;
            // rotor users reach share through the custom action. (#479)
            .accessibilityLabel(rowLabel(for: bookmark))
            .accessibilityHint("Plays from this spot")
            // Routed through the shared helper so the rotor announces Share
            // before Delete — never the destructive action first — despite the
            // OS's reversed emission (#572, #577).
            .rotorActions([
                QuickActionItem(id: "shareBookmark", label: "Share bookmark", isDestructive: false) { share(bookmark) },
                QuickActionItem(id: "deleteBookmark", label: "Delete bookmark", isDestructive: true) { delete(bookmark) },
            ])

            // A visible, sighted-only share control. Its 44pt target sits beside
            // the label so a tap doesn't also trigger the jump. Hidden from
            // VoiceOver: the row's custom "Share bookmark" action covers it.
            Button {
                share(bookmark)
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .frame(minWidth: Spacing.minTouchTarget, minHeight: Spacing.minTouchTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .accessibilityHidden(true)
        }

        // The swipes are sighted-only affordances, attached only when VoiceOver
        // is off: iOS mirrors swipe actions into the VoiceOver rotor, which
        // announced Delete and Share twice each — destructive Delete first —
        // alongside the row's custom actions above (#577). The custom actions
        // cover everything the swipes offer. Toggling VoiceOver mid-session
        // updates `voiceOverEnabled` and re-renders — no relaunch needed.
        if voiceOverEnabled {
            base
        } else {
            base.swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                    delete(bookmark)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                Button {
                    share(bookmark)
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .tint(.accentColor)
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

    private func share(_ bookmark: Bookmark) {
        let text = BookmarkShareLogic.shareText(
            episodeTitle: episode.title,
            positionSeconds: bookmark.positionSeconds,
            note: bookmark.note,
            audioURL: episode.audioURL
        )
        shareItem = BookmarkShareItem(text: text)
    }
}

/// Identifiable wrapper so a bookmark's share text can drive a `.sheet(item:)`
/// for the system share sheet.
private struct BookmarkShareItem: Identifiable {
    let text: String
    let id = UUID()
}
