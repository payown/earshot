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
    // The podcast a pending "Unfollow this podcast" action targets, from either
    // the episode Quick Action rotor entry (#528) or the sighted swipe (#500).
    // Non-nil drives the shared `.unfollowConfirmation` dialog.
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
                        EpisodeRow(episode: episode, actions: actions(for: episode))
                            // Unfollow the whole show straight from one of its
                            // inbox episodes (#500/#528). For VoiceOver users the
                            // affordance is now a first-class episode Quick Action
                            // ("Unfollow this podcast") in the row's Actions rotor,
                            // so it can be reordered (#523) and hidden (#524) like
                            // every other action — and there's a single rotor
                            // source. Sighted users still get the trailing swipe
                            // they expect, but SIGHTED-ONLY (mirroring
                            // `QueueScreen.SightedRowActions`): the swipe is
                            // suppressed under VoiceOver so it can't promote a
                            // duplicate rotor entry. `allowsFullSwipe` is off so an
                            // over-swipe can't fast-path a podcast-level delete;
                            // every path lands on the shared confirmation below.
                            // The Label gives the destructive action an icon +
                            // text (never color alone).
                            .sightedSwipeActions(allowsFullSwipe: false) {
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
        // Podcast-level destructive confirmation for the inbox-row "Unfollow this
        // podcast" affordance — reached from either the episode Quick Action rotor
        // entry (#528) or the sighted swipe (#500). Uses the shared
        // `.unfollowConfirmation` modifier so the wording/structure match Library's
        // dialog and every episode surface guards the destructive action
        // identically. On success, if the unfollow emptied the inbox the focused
        // row is gone, so move VoiceOver focus to the empty state (mirrors
        // `clearInbox`).
        .unfollowConfirmation($pendingUnfollow, context: context) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if InboxRepository(context: context).inboxEpisodes().isEmpty {
                    focusEmpty = true
                }
            }
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

    private func actions(for episode: Episode) -> [QuickActionItem] {
        buildEpisodeActions(
            episode: episode,
            order: quickActions.visibleEpisodeActions,
            player: player,
            downloads: downloads,
            context: context,
            onShowNotes: { showNotesEpisode = episode },
            onShare: { sharingEpisode = episode },
            onBookmarks: { bookmarksEpisode = episode },
            // Nil when the episode has no persisted podcast, which drops the
            // action; otherwise route to the shared confirmation dialog.
            onUnfollow: episode.podcast.map { podcast in { pendingUnfollow = podcast } }
        )
    }

    private func shareItems(for episode: Episode) -> [Any] {
        if let url = URL(string: episode.audioURL) {
            return [episode.title, url]
        }
        return [episode.title]
    }
}
