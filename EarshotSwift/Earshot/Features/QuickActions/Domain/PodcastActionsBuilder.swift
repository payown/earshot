import Foundation
import SwiftData

/// Builds runnable actions for `podcast` in the user's configured `order`,
/// preserving order for the default tap + VoiceOver rotor. Toggle labels reflect
/// the podcast's current state.
@MainActor
func buildPodcastActions(
    podcast: Podcast,
    order: [PodcastAction],
    context: ModelContext,
    onOpenDetail: @escaping () -> Void,
    onShare: @escaping () -> Void,
    onUnsubscribe: @escaping () -> Void
) -> [QuickActionItem] {
    order.map { action in
        switch action {
        case .openDetail:
            return QuickActionItem(label: "Open podcast detail", isDestructive: false) {
                onOpenDetail()
            }
        case .toggleNotifications:
            // notificationEnabled is Bool? (nil = off, #425); coalesce on read
            // and write a concrete Bool back.
            let on = podcast.notificationEnabled ?? false
            return QuickActionItem(
                label: on ? "Turn off notifications" : "Turn on notifications",
                isDestructive: false
            ) {
                let newValue = !(podcast.notificationEnabled ?? false)
                podcast.notificationEnabled = newValue
                saveQuickAction(context, "notifications")
                Announcer.announce(newValue ? "Notifications on" : "Notifications off")
            }
        case .toggleAutoQueue:
            let on = podcast.autoQueue
            return QuickActionItem(
                label: on ? "Turn off auto-queue" : "Turn on auto-queue",
                isDestructive: false
            ) {
                podcast.autoQueue.toggle()
                saveQuickAction(context, "auto-queue")
                Announcer.announce(podcast.autoQueue ? "Auto-queue on" : "Auto-queue off")
            }
        case .toggleInboxInclude:
            let included = podcast.inboxIncluded
            return QuickActionItem(
                label: included ? "Remove from Inbox" : "Add to Inbox",
                isDestructive: false
            ) {
                podcast.inboxIncluded.toggle()
                saveQuickAction(context, "inbox-include")
                Announcer.announce(podcast.inboxIncluded ? "Added to inbox" : "Removed from inbox")
            }
        case .toggleInboxExclude:
            // Companion to .toggleInboxInclude above, for normal (non-opt-in)
            // mode (#671): opt-in mode has "everything excluded unless
            // included," normal mode is "everything included unless
            // excluded." Same non-destructive, announced toggle shape.
            let excluded = podcast.inboxExcluded
            return QuickActionItem(
                label: excluded ? "Include in Inbox" : "Exclude from Inbox",
                isDestructive: false
            ) {
                podcast.inboxExcluded.toggle()
                saveQuickAction(context, "inbox-exclude")
                Announcer.announce(podcast.inboxExcluded ? "Excluded from inbox" : "Included in inbox")
            }
        case .unsubscribe:
            return QuickActionItem(label: "Unfollow", isDestructive: true) {
                onUnsubscribe()
            }
        case .share:
            return QuickActionItem(label: "Share podcast", isDestructive: false) {
                onShare()
            }
        }
    }
}
