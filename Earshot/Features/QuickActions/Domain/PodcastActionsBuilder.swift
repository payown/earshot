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
    onUnsubscribe: @escaping () -> Void,
    onChangeDownloadCount: (() -> Void)? = nil,
    onChangeQueueAgeLimit: ((Podcast) -> Void)? = nil,
    onEditPodcastSpeed: ((Podcast) -> Void)? = nil,
    onAddToFolder: ((Podcast) -> Void)? = nil,
    onMoveToFolder: ((Podcast) -> Void)? = nil
) -> [QuickActionItem] {
    order.compactMap { action -> QuickActionItem? in
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
                savePodcastQuickAction(context, "notifications")
                Announcer.announce(newValue ? "Notifications on" : "Notifications off")
            }
        case .toggleAutoQueue:
            let on = podcast.autoQueue
            return QuickActionItem(
                label: on ? "Turn off auto-queue" : "Turn on auto-queue",
                isDestructive: false
            ) {
                let newValue = !podcast.autoQueue
                QueueRepository(context: context).setAutoQueue(newValue, for: podcast)
                savePodcastQuickAction(context, "auto-queue")
                Announcer.announce(newValue ? "Auto-queue on" : "Auto-queue off")
            }
        case .toggleInboxInclude:
            let included = podcast.inboxIncluded
            return QuickActionItem(
                label: included ? "Remove from Inbox" : "Add to Inbox",
                isDestructive: false
            ) {
                podcast.inboxIncluded.toggle()
                savePodcastQuickAction(context, "inbox-include")
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
                savePodcastQuickAction(context, "inbox-exclude")
                Announcer.announce(podcast.inboxExcluded ? "Excluded from inbox" : "Included in inbox")
            }
        case .changeDownloadCount:
            guard let onChangeDownloadCount else { return nil }
            return QuickActionItem(label: action.label, isDestructive: false) {
                onChangeDownloadCount()
            }
        case .changeQueueAgeLimit:
            guard let onChangeQueueAgeLimit else { return nil }
            return QuickActionItem(label: action.label, isDestructive: false) {
                onChangeQueueAgeLimit(podcast)
            }
        case .editPodcastSpeed:
            guard let onEditPodcastSpeed else { return nil }
            return QuickActionItem(label: action.label, isDestructive: false) {
                onEditPodcastSpeed(podcast)
            }
        case .unsubscribe:
            return QuickActionItem(label: "Unfollow", isDestructive: true) {
                onUnsubscribe()
            }
        case .share:
            return QuickActionItem(label: "Share podcast", isDestructive: false) {
                onShare()
            }
        case .addToFolder:
            // Folders phase 2 (#756): opens the shared `FolderPickerView` in
            // `.add` mode for this single podcast. Omitted (nil) on surfaces that
            // don't wire folder assignment.
            guard let onAddToFolder else { return nil }
            return QuickActionItem(label: action.label, isDestructive: false) {
                onAddToFolder(podcast)
            }
        case .moveToFolder:
            // Folders phase 2 (#756): opens the shared `FolderPickerView` in
            // `.move` mode. Same opt-in contract as `.addToFolder`.
            guard let onMoveToFolder else { return nil }
            return QuickActionItem(label: action.label, isDestructive: false) {
                onMoveToFolder(podcast)
            }
        }
    }
}

@MainActor
@discardableResult
func savePodcastQuickAction(_ context: ModelContext, _ what: String) -> Bool {
    guard saveQuickAction(context, what) else { return false }
    NotificationCenter.default.post(name: .earshotSubscriptionsDidChange, object: nil)
    return true
}
