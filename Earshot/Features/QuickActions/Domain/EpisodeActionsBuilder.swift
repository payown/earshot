import Foundation
import SwiftData

/// A resolved, runnable Quick Action for one content item (episode, podcast, or
/// queue row). The user's configured order drives both the default double-tap
/// (first) and the VoiceOver Actions rotor order.
struct QuickActionItem: Identifiable {
    let id: String
    let label: String
    let isDestructive: Bool
    let run: () -> Void

    init(
        id: String = UUID().uuidString,
        label: String,
        isDestructive: Bool,
        run: @escaping () -> Void
    ) {
        self.id = id
        self.label = label
        self.isDestructive = isDestructive
        self.run = run
    }
}

/// Resolves only which configured actions this surface can expose, without
/// constructing UUID-backed runnable items. Large lazy lists keep this stable
/// enum array in each row and call ``buildEpisodeActions`` for the single action
/// the user actually activates.
func availableEpisodeActions(
    episode: Episode,
    order: [EpisodeAction],
    supportsUnfollow: Bool = false,
    supportsExport: Bool = false,
    supportsAddToFolder: Bool = false,
    supportsMoveToFolder: Bool = false
) -> [EpisodeAction] {
    order.filter { action in
        switch action {
        case .exportAudio:
            return supportsExport && !episode.audioURL.isEmpty
        case .addToFolder:
            return supportsAddToFolder
        case .moveToFolder:
            return supportsMoveToFolder
        case .unfollow:
            return supportsUnfollow && episode.podcast != nil
        default:
            return true
        }
    }
}

/// Builds the runnable actions for `episode` in the user's configured `order`.
/// The order is preserved exactly. Dynamic labels (Mark as played/unplayed) are
/// resolved here from the episode's state.
///
/// `onUnfollow` is optional: surfaces that can't unfollow (the search preview's
/// detached episodes — zero store writes, #517 contract) pass nil and the
/// `.unfollow` action is simply omitted from their rotor. Surfaces that pass a
/// runner must open a confirmation dialog, never unfollow directly.
///
/// `onMarkPlayed` is optional (#579): surfaces where marking played removes the
/// row from the visible list (Inbox always; a podcast's episode list under the
/// Unheard filter; the Downloads list under its Unheard filter, #641) pass a
/// runner to keep VoiceOver focus oriented — it's invoked with the NEW played
/// value BEFORE the state flips, so the surface can still find the row's neighbor
/// in its visible list and move focus to it once the list re-renders. nil (the
/// default) means no focus management, which is right for surfaces where the row
/// stays put (the search preview, or Downloads under the All filter).
///
/// `onWillQueue` is the queueing analogue for Inbox-like surfaces (#763): Play
/// now, Play next, and Add to end invoke it before changing status so the caller
/// can capture the still-visible row's neighbor and restore VoiceOver focus.
@MainActor
func buildEpisodeActions(
    episode: Episode,
    order: [EpisodeAction],
    player: PlayerService,
    downloads: DownloadManager,
    context: ModelContext,
    onShowNotes: @escaping () -> Void,
    onShare: @escaping () -> Void,
    onBookmarks: @escaping () -> Void,
    onUnfollow: (() -> Void)? = nil,
    onMarkPlayed: ((Bool) -> Void)? = nil,
    onWillQueue: (() -> Void)? = nil,
    onExport: (() -> Void)? = nil,
    onAddToFolder: ((Episode) -> Void)? = nil,
    onMoveToFolder: ((Episode) -> Void)? = nil
) -> [QuickActionItem] {
    let episodeID = episode.persistentModelID
    return order.compactMap { action -> QuickActionItem? in
        switch action {
        case .playNow:
            return QuickActionItem(label: "Play now", isDestructive: false) {
                onWillQueue?()
                // Row "Play now" — raises the full player when the user's
                // openPlayerOnPlay setting is on (#562).
                player.playFromEpisodeList(episode)
            }
        case .download:
            let downloaded = episode.downloadStatus == .downloaded
            return QuickActionItem(
                label: downloaded ? "Remove download" : "Download",
                isDestructive: downloaded
            ) {
                if downloaded {
                    downloads.removeDownload(episode)
                } else {
                    Task { @MainActor in
                        guard PersistentModelLifetime.episodeExists(episodeID, in: context) else { return }
                        await downloads.download(episode)
                    }
                }
            }
        case .addToQueueTop:
            return QuickActionItem(label: "Play next", isDestructive: false) {
                onWillQueue?()
                QueueRepository(context: context).playNext(episode, after: player.nowPlayingEpisode)
                player.registerPlayNext(episode)
                Announcer.announce("\(episode.title) will play next")
            }
        case .addToQueueBottom:
            return QuickActionItem(label: "Add to end of queue", isDestructive: false) {
                onWillQueue?()
                QueueRepository(context: context).add(episode)
                Announcer.announce("Added \(episode.title) to the end of the queue")
            }
        case .markPlayed:
            let played = episode.isPlayed
            return QuickActionItem(
                label: played ? "Mark as unplayed" : "Mark as played",
                isDestructive: false
            ) {
                // Marking played dismisses the episode from the inbox durably;
                // marking unplayed leaves any dismissal sticky so a triaged
                // episode never jumps back into the inbox (#546).
                let nowPlayed = !played
                // Invoked before the flip so the surface can still find this
                // row's neighbor in its visible list (#579).
                onMarkPlayed?(nowPlayed)
                episode.isPlayed = nowPlayed
                episode.inboxDismissed = InboxLogic.inboxDismissedAfterPlayedChange(
                    nowPlayed: nowPlayed, wasDismissed: episode.inboxDismissed
                )
                // Auto-delete the download when this marks it played and the user
                // opted in. Only on the played direction, never on unplayed.
                if nowPlayed {
                    DownloadCleanup.removeDownloadAfterPlayedIfEnabled(episode, in: context)
                }
                if saveQuickAction(context, "played state") {
                    postEpisodeUserStateChanges(
                        [episode],
                        playedChangedExplicitly: true
                    )
                }
                // The rotor path's only announcement (#579). The sighted swipe
                // announces on its own path (InboxScreen.markPlayed) and never
                // runs this runner, so exactly one announcement fires per
                // activation. Wording matches that swipe path.
                Announcer.announce(nowPlayed ? "Marked as played" : "Marked as unplayed")
            }
        case .viewBookmarks:
            return QuickActionItem(label: "Bookmarks", isDestructive: false) {
                onBookmarks()
            }
        case .openShowNotes:
            return QuickActionItem(label: "Open show notes", isDestructive: false) {
                onShowNotes()
            }
        case .share:
            return QuickActionItem(label: "Share", isDestructive: false) {
                onShare()
            }
        case .exportAudio:
            // Downloads (if needed) then shares the LOCAL audio file (#689).
            // Omitted (nil) when the surface can't export — the search-preview's
            // detached episodes (no store/download) pass no runner — or when the
            // episode has no audio URL to export at all, mirroring `.unfollow`.
            guard let onExport, !episode.audioURL.isEmpty else { return nil }
            return QuickActionItem(label: "Export audio", isDestructive: false) {
                onExport()
            }
        case .addToFolder:
            // Folders phase 2 (#756): opens the shared `FolderPickerView` in
            // `.add` mode for this single episode. Omitted (nil) on surfaces that
            // don't file into folders — e.g. the search preview's detached
            // episodes (no store writes, #517) pass no runner.
            guard let onAddToFolder else { return nil }
            return QuickActionItem(label: action.label, isDestructive: false) {
                onAddToFolder(episode)
            }
        case .moveToFolder:
            // Folders phase 2 (#756): opens the shared `FolderPickerView` in
            // `.move` mode. Same opt-in contract as `.addToFolder`.
            guard let onMoveToFolder else { return nil }
            return QuickActionItem(label: action.label, isDestructive: false) {
                onMoveToFolder(episode)
            }
        case .unfollow:
            // Podcast-level unfollow from an episode row (#500/#572). Omitted
            // (nil) when the surface can't unfollow or the episode has no
            // podcast (a detached search-preview episode). The runner opens the
            // caller's confirmation dialog; the actual delete goes through the
            // one `SubscriptionRepository.unsubscribe` path (sessions/#377 +
            // folders cleanup live there).
            guard let onUnfollow, episode.podcast != nil else { return nil }
            return QuickActionItem(label: "Unfollow this podcast", isDestructive: true) {
                onUnfollow()
            }
        }
    }
}

/// Saves the context, logging (not throwing) on failure — Quick Action runners
/// are fire-and-forget from a VoiceOver gesture.
@MainActor
@discardableResult
func saveQuickAction(_ context: ModelContext, _ what: String) -> Bool {
    guard context.hasChanges else { return false }
    do {
        try context.save()
        // User-triggered played/include/exclude mutations can change both the
        // global Inbox badge and folder-scoped Inbox snapshots (#763). Other
        // Quick Action saves may cause one harmless event-driven recompute; this
        // path runs only on an explicit action, never playback-position saves.
        NotificationCenter.default.post(name: .earshotInboxDidChange, object: nil)
        return true
    } catch {
        AppLog.quickActions.error("Failed to save \(what, privacy: .public): \(error.localizedDescription, privacy: .public)")
        return false
    }
}
