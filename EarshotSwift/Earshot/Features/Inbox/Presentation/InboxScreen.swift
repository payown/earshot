import SwiftUI
import SwiftData

/// The Inbox: new, untriaged episodes. Each row carries the configured episode
/// Quick Actions (rotor + default tap). "Clear inbox" dismisses everything
/// currently shown.
struct InboxScreen: View {
    @Environment(\.modelContext) private var context
    @Environment(PlayerService.self) private var player
    @Environment(DownloadManager.self) private var downloads
    @Environment(QuickActionStore.self) private var quickActions

    // Candidate inbox episodes: non-dismissed, newest first. SwiftData keeps this
    // result current, so it both drives re-rendering when inbox membership changes
    // AND supplies the rows the list/count come from — without a fresh
    // `context.fetch` on every body evaluation. The remaining in-memory rules
    // (status + per-podcast exclusion) are applied by `InboxRepository.inbox(from:)`,
    // so the filtering rules still live in one place. The predicate matches
    // `inboxEpisodes()` exactly, preserving contents and order.
    @Query(filter: #Predicate<Episode> { $0.inboxDismissed == false },
           sort: \Episode.pubDate, order: .reverse)
    private var inboxCandidates: [Episode]

    @State private var showNotesEpisode: Episode?
    @State private var sharingEpisode: Episode?
    @State private var bookmarksEpisode: Episode?
    @State private var confirmingClear = false
    // The podcast a pending "Unfollow this podcast" swipe targets. Non-nil drives
    // the destructive confirmation dialog (#500). Mirrors the Library unfollow
    // flow (`SubscriptionsView.pendingUnsubscribe`) so the UX is identical.
    @State private var pendingUnfollow: Podcast?
    @AccessibilityFocusState private var focusEmpty: Bool

    var body: some View {
        // Compute the inbox once per body so the list, empty-state check, title,
        // count, and Clear dialog all read a single value instead of re-running
        // the filter (formerly a re-fetch) several times per render.
        let inbox = InboxRepository(context: context).inbox(from: inboxCandidates)
        return Group {
            if inbox.isEmpty {
                ContentUnavailableView(
                    "Inbox is empty",
                    systemImage: "tray",
                    description: Text("New episodes you haven't triaged appear here.")
                )
                .accessibilityElement(children: .combine)
                .accessibilityFocused($focusEmpty)
            } else {
                List {
                    ForEach(inbox) { episode in
                        EpisodeRow(episode: episode, actions: actions(for: episode), includesPodcastName: true)
                            // Visible affordance for sighted users to clear a
                            // finished episode out of the inbox (#546): a leading
                            // swipe marks it played and dismisses it. Testers had
                            // no visible way to do this — the mark-played Quick
                            // Action only surfaced in the VoiceOver rotor / default
                            // tap. Leading edge + a constructive green tint keeps it
                            // distinct from the trailing destructive unfollow swipe;
                            // a full swipe completes it since the action is safe and
                            // reversible (the episode stays in the podcast). SwiftUI
                            // also mirrors this swipe into the VoiceOver Actions
                            // rotor, so it reaches VoiceOver users too. The Label
                            // gives it an icon + text (never color alone).
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button {
                                    markPlayed(episode)
                                } label: {
                                    Label("Mark as played", systemImage: "checkmark.circle")
                                }
                                .tint(.green)
                                // The row already exposes "Mark as played" in the
                                // VoiceOver Actions rotor via the `.markPlayed`
                                // episode Quick Action (always present — Quick
                                // Actions are reorder-only, never removable, so
                                // `resolve()` always includes it). SwiftUI mirrors
                                // this swipe button into the SAME rotor, which would
                                // give VoiceOver users a duplicate "Mark as played"
                                // stop. This swipe is purely the visible affordance
                                // sighted users lacked (#546), so hide it from
                                // VoiceOver and let the single Quick Action own the
                                // rotor — mirroring the Downloads "Restore" pattern
                                // (visible button + `.accessibilityHidden(true)`,
                                // action lives in the rotor).
                                .accessibilityHidden(true)
                            }
                            // Unfollow the whole show straight from one of its
                            // inbox episodes (#500). A trailing swipe is the
                            // visible affordance sighted users expect; SwiftUI
                            // also surfaces a swipe action to the VoiceOver
                            // Actions rotor automatically, so the SAME single
                            // control reaches VoiceOver users (Robin) in the same
                            // rotor as the row's episode Quick Actions — without
                            // adding a duplicate rotor entry that a second,
                            // explicit `.accessibilityActions` source would. It
                            // does not touch the row's existing episode actions,
                            // so their order can't regress. `allowsFullSwipe` is
                            // off so an over-swipe can't fast-path a podcast-level
                            // delete; every path lands on the confirmation below.
                            // The Label gives the destructive action an icon +
                            // text (never color alone).
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if let podcast = episode.podcast {
                                    Button(role: .destructive) {
                                        pendingUnfollow = podcast
                                    } label: {
                                        Label("Unfollow this podcast", systemImage: "xmark.bin")
                                    }
                                }
                            }
                    }
                }
            }
        }
        // The visible title and its VoiceOver label both derive from
        // `inbox.count`, which comes from the @Query-backed `inbox` — so they
        // re-render live as episodes are triaged or the inbox is cleared, with
        // no separate state to go stale. Visible string stays compact
        // ("Inbox (12)"); VoiceOver gets a naturally-spoken label
        // ("Inbox, 12 episodes").
        //
        // The count-bearing title rides on a `.principal` toolbar item rather
        // than `.navigationTitle`. A `.navigationTitle(Text(...))` plus a
        // standalone `.accessibilityLabel` puts the label on the content view,
        // not the title element, so VoiceOver still spells out "open paren,
        // 12, close paren". Even moving the label onto the `Text` passed to
        // `navigationTitle` is unreliable here: on this project's iOS 17
        // deployment target SwiftUI's navigation-bar bridge does not
        // consistently carry a custom accessibility label into the LARGE
        // title. The `.principal` item is a single, real bar element we fully
        // own, so the label is guaranteed. `.accessibilityAddTraits(.isHeader)`
        // restores the heading role that a plain `navigationTitle` grants for
        // free. Tradeoff: a principal item presents inline-style with no
        // large-title spring — acceptable for an accessibility-first app where
        // the guaranteed reading matters more than the large-title animation.
        // The plain `navigationTitle("Inbox")` keeps the bar's title identity
        // (e.g. for back-button context) without duplicating the principal.
        .navigationTitle("Inbox")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(InboxLogic.inboxTitle(count: inbox.count))
                    .font(.headline)
                    .accessibilityLabel(InboxLogic.inboxTitleAccessibilityLabel(count: inbox.count))
                    .accessibilityAddTraits(.isHeader)
            }
            if !inbox.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        confirmingClear = true
                    } label: {
                        Label("Clear inbox", systemImage: "tray.and.arrow.down")
                    }
                }
            }
        }
        .confirmationDialog(
            "Clear inbox?",
            isPresented: $confirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear inbox", role: .destructive) { clearInbox() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Hides all \(inbox.count) episodes from the inbox. They stay in your podcasts.")
        }
        // Podcast-level destructive confirmation for the inbox-row "Unfollow"
        // swipe (#500). Wording and structure mirror Library's unfollow dialog
        // (`SubscriptionsView`) for consistency; the message spells out that the
        // whole show leaves the library, since the action is reached from a single
        // episode's context and shouldn't be mistaken for an inbox-only dismiss.
        .confirmationDialog(
            "Unfollow \(pendingUnfollow?.title ?? "this podcast")?",
            isPresented: Binding(
                get: { pendingUnfollow != nil },
                set: { if !$0 { pendingUnfollow = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingUnfollow
        ) { podcast in
            Button("Unfollow", role: .destructive) { unfollow(podcast) }
            Button("Cancel", role: .cancel) { pendingUnfollow = nil }
        } message: { podcast in
            Text("This removes \(podcast.title) and its episodes from your library. This can't be undone.")
        }
        .sheet(item: $showNotesEpisode) { ShowNotesView(episode: $0) }
        .sheet(item: $bookmarksEpisode) { BookmarksListView(episode: $0) }
        .sheet(item: $sharingEpisode) { ShareSheet(items: shareItems(for: $0)) }
    }

    private func clearInbox() {
        InboxRepository(context: context).clearInbox()
        Announcer.announce("Inbox cleared")
        // The list collapses to the empty state; move focus there so VoiceOver
        // isn't orphaned on the vanished Clear button.
        // Delay so the list has collapsed to the empty state (the focus target)
        // before we request focus on it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { focusEmpty = true }
    }

    /// Marks `episode` played and dismisses it from the inbox via the shared
    /// repository path (#546), then announces it. If that empties the inbox the
    /// focused row is gone, so move VoiceOver focus to the empty state (mirrors
    /// `clearInbox` / `unfollow`).
    private func markPlayed(_ episode: Episode) {
        InboxRepository(context: context).markPlayed(episode)
        Announcer.announce("Marked as played")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if InboxRepository(context: context).inboxEpisodes().isEmpty {
                focusEmpty = true
            }
        }
    }

    /// Unfollows `podcast` via the centralized repository path shared with
    /// Library and search (#499/#500) — never an inline delete. The repo logs
    /// failures and returns whether the delete saved, so we announce success only
    /// on `true`. The unfollowed show's episodes drop out of the @Query-backed
    /// inbox automatically; if that empties the inbox the focused row is gone, so
    /// move VoiceOver focus to the empty state (mirrors `clearInbox`).
    private func unfollow(_ podcast: Podcast) {
        let title = podcast.title
        let removed = SubscriptionRepository(context: context).unsubscribe(podcast)
        pendingUnfollow = nil
        guard removed else { return }
        Announcer.announce("Unfollowed \(title)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if InboxRepository(context: context).inboxEpisodes().isEmpty {
                focusEmpty = true
            }
        }
    }

    private func actions(for episode: Episode) -> [QuickActionItem] {
        buildEpisodeActions(
            episode: episode,
            order: quickActions.episodeActions,
            player: player,
            downloads: downloads,
            context: context,
            onShowNotes: { showNotesEpisode = episode },
            onShare: { sharingEpisode = episode },
            onBookmarks: { bookmarksEpisode = episode }
        )
    }

    private func shareItems(for episode: Episode) -> [Any] {
        if let url = URL(string: episode.audioURL) {
            return [episode.title, url]
        }
        return [episode.title]
    }
}
