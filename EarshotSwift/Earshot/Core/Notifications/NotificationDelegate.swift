import Foundation
import UserNotifications

/// `UNUserNotificationCenterDelegate` for the per-podcast "new episodes" feature.
///
/// Routes the default tap (deep link to the show) and the two custom actions
/// ("Add to queue", "Play now") into a ``NotificationRouter`` that ``RootView``
/// observes. Also lets notifications present while the app is foregrounded (#72).
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    private let router: NotificationRouter

    init(router: NotificationRouter) {
        self.router = router
        super.init()
    }

    /// Pure mapping from a response's action id + userInfo to an intent. Returns
    /// nil when the userInfo doesn't carry the feed URL we need (a malformed or
    /// foreign notification). Static + pure so it's unit-testable without a real
    /// `UNNotificationResponse`.
    static func intent(
        actionIdentifier: String,
        userInfo: [AnyHashable: Any]
    ) -> NotificationIntent? {
        guard let feedURL = userInfo[NotificationService.podcastFeedURLKey] as? String,
              !feedURL.isEmpty
        else { return nil }

        let episodeGUID = userInfo[NotificationService.episodeGUIDKey] as? String

        switch actionIdentifier {
        case NotificationService.addToQueueActionID:
            guard let episodeGUID, !episodeGUID.isEmpty else {
                return .openPodcast(feedURL: feedURL)
            }
            return .addEpisodeToQueue(feedURL: feedURL, episodeGUID: episodeGUID)
        case NotificationService.playNowActionID:
            guard let episodeGUID, !episodeGUID.isEmpty else {
                return .openPodcast(feedURL: feedURL)
            }
            return .playEpisode(feedURL: feedURL, episodeGUID: episodeGUID)
        default:
            // UNNotificationDefaultActionIdentifier (tap) or dismiss → open.
            return .openPodcast(feedURL: feedURL)
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let actionID = response.actionIdentifier
        if let intent = Self.intent(actionIdentifier: actionID, userInfo: userInfo) {
            Task { @MainActor in
                router.handle(intent)
            }
        } else {
            AppLog.notifications.error("Notification response missing routing info")
        }
        completionHandler()
    }

    /// Presentation options for a notification that arrives while the app is
    /// foregrounded. `willPresent` fires ONLY in the foreground.
    ///
    /// A new-episode notification can now be delivered from the foreground
    /// refresh path itself (pull-to-refresh / launch restore), where the user is
    /// already looking at the new episodes. Showing an interrupting banner + sound
    /// on top of that is noise (#421). We return `.list` so the notification is
    /// still delivered to Notification Center (the user can find it later, and the
    /// per-podcast coalescing identifier still applies), but suppress the banner
    /// and sound so it never interrupts the active session. Background-delivered
    /// notifications are unaffected — `willPresent` is not called for those.
    static let foregroundPresentationOptions: UNNotificationPresentationOptions = [.list, .badge]

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler(Self.foregroundPresentationOptions)
    }
}
