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
            let on = podcast.notificationEnabled
            return QuickActionItem(
                label: on ? "Turn off notifications" : "Turn on notifications",
                isDestructive: false
            ) {
                podcast.notificationEnabled.toggle()
                saveQuickAction(context, "notifications")
                Announcer.announce(podcast.notificationEnabled ? "Notifications on" : "Notifications off")
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
        case .unsubscribe:
            return QuickActionItem(label: "Unsubscribe", isDestructive: true) {
                onUnsubscribe()
            }
        case .share:
            return QuickActionItem(label: "Share podcast", isDestructive: false) {
                onShare()
            }
        }
    }
}
