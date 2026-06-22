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

    /// Show the banner + sound even when the app is in the foreground, so a
    /// notification that arrives during a foreground refresh isn't silently
    /// dropped.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
