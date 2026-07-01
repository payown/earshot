import SwiftUI
import SwiftData

/// Presents the shared podcast-unfollow confirmation dialog for a pending
/// `Podcast`, and performs the unfollow via the centralized
/// ``SubscriptionRepository`` path (never an inline delete). Wording and
/// structure match Library's unfollow flow so the destructive confirmation reads
/// identically on every surface that offers the "Unfollow this podcast" episode
/// Quick Action (#528) — a single source of truth instead of duplicating the
/// dialog and unfollow logic in Inbox, Library, Downloads, and Search.
///
/// `onUnfollowed` runs after a successful unsubscribe for surface-specific
/// follow-up (e.g. Inbox moves VoiceOver focus to its empty state when the row
/// vanishes). The action is confirmation-guarded on every surface: no host may
/// unfollow without routing through this dialog.
struct UnfollowConfirmation: ViewModifier {
    @Binding var pending: Podcast?
    let context: ModelContext
    var onUnfollowed: ((Podcast) -> Void)?

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Unfollow \(pending?.title ?? "this podcast")?",
            isPresented: Binding(
                get: { pending != nil },
                set: { if !$0 { pending = nil } }
            ),
            titleVisibility: .visible,
            presenting: pending
        ) { podcast in
            Button("Unfollow", role: .destructive) { unfollow(podcast) }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: { podcast in
            Text("This removes \(podcast.title) and its episodes from your library. This can't be undone.")
        }
    }

    /// Unfollows via the centralized repository path shared with Library and
    /// search (#499/#500). The repo logs failures and returns whether the delete
    /// saved, so success is announced only on `true`.
    private func unfollow(_ podcast: Podcast) {
        let title = podcast.title
        let removed = SubscriptionRepository(context: context).unsubscribe(podcast)
        pending = nil
        guard removed else { return }
        Announcer.announce("Unfollowed \(title)")
        onUnfollowed?(podcast)
    }
}

extension View {
    /// Attaches the shared podcast-unfollow confirmation dialog, driven by
    /// `pending`. Set `pending` to a podcast (e.g. from the "Unfollow this
    /// podcast" episode Quick Action or a sighted swipe) to present it.
    func unfollowConfirmation(
        _ pending: Binding<Podcast?>,
        context: ModelContext,
        onUnfollowed: ((Podcast) -> Void)? = nil
    ) -> some View {
        modifier(UnfollowConfirmation(pending: pending, context: context, onUnfollowed: onUnfollowed))
    }
}
