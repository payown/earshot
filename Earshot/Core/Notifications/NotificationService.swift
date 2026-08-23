import Foundation
import UserNotifications

/// Wraps Earshot's local-notification scheduling. LOCAL notifications only —
/// no remote push, no APNs.
///
/// Responsibilities:
///   - Request notification authorization, idempotently (never re-prompts once
///     the user has decided).
///   - Register the "new episodes" category with the two PRD actions
///     ("Add to queue", "Play now").
///   - Deliver a single summarizing notification per podcast.
///
/// All `UNUserNotificationCenter` work goes through the injectable
/// ``NotificationScheduling`` protocol so the logic is unit-testable. Every call
/// is wrapped so a failure is logged and swallowed — notification delivery must
/// NEVER throw out of the background refresh task (#381 / #72).
struct NotificationService: Sendable {

    // MARK: Stable identifiers

    /// Category identifier carrying the two action buttons. Stable so the system
    /// keeps matching delivered notifications to the registered actions.
    static let newEpisodesCategoryID = "media.payown.earshot.newEpisodes"
    static let downloadCompletedCategoryID = "media.payown.earshot.downloadCompleted"

    /// Action identifiers. Stable strings the delegate matches on.
    static let addToQueueActionID = "media.payown.earshot.action.addToQueue"
    static let playNowActionID = "media.payown.earshot.action.playNow"

    /// `userInfo` keys carried on each request, read back by the delegate to
    /// deep-link and to drive the actions. Values are the models' natural keys.
    static let podcastFeedURLKey = "podcastFeedURL"
    static let episodeGUIDKey = "episodeGUID"

    private let center: NotificationScheduling

    init(center: NotificationScheduling = SystemNotificationCenter()) {
        self.center = center
    }

    // MARK: Category registration

    /// The "new episodes" category with the two PRD action buttons. Foreground
    /// actions so tapping either brings the app forward to act (enqueue / play).
    static func newEpisodesCategory() -> UNNotificationCategory {
        let addToQueue = UNNotificationAction(
            identifier: addToQueueActionID,
            title: "Add to queue",
            options: [.foreground]
        )
        let playNow = UNNotificationAction(
            identifier: playNowActionID,
            title: "Play now",
            options: [.foreground]
        )
        return UNNotificationCategory(
            identifier: newEpisodesCategoryID,
            actions: [addToQueue, playNow],
            intentIdentifiers: [],
            options: []
        )
    }

    /// Download-completion notifications have no custom actions. A default tap
    /// uses the episode identity in `userInfo` to open its podcast.
    static func downloadCompletedCategory() -> UNNotificationCategory {
        UNNotificationCategory(
            identifier: downloadCompletedCategoryID,
            actions: [],
            intentIdentifiers: [],
            options: []
        )
    }

    /// Registers the category. Safe to call repeatedly (e.g. at launch).
    func registerCategories() async {
        await center.setNotificationCategories([
            Self.newEpisodesCategory(),
            Self.downloadCompletedCategory(),
        ])
    }

    // MARK: Authorization

    /// The current authorization status, without prompting. Used to detect and
    /// surface a prior denial in the UI (#600): `requestAuthorization()`
    /// intentionally never re-prompts once the user has decided, so a user who
    /// denied the one-time system prompt gets no further feedback anywhere in
    /// the app unless a caller explicitly checks this and tells them.
    func currentAuthorizationStatus() async -> UNAuthorizationStatus {
        await center.authorizationStatus()
    }

    /// Requests `.alert, .sound, .badge` authorization, but only if the user has
    /// not yet decided. Returns whether notifications are authorized after the
    /// call. Idempotent: a `.denied`/`.authorized`/`.provisional` status is left
    /// untouched and never re-prompts (#72).
    @discardableResult
    func requestAuthorization() async -> Bool {
        let status = await center.authorizationStatus()
        switch status {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            do {
                let granted = try await center.requestAuthorization(
                    options: [.alert, .sound, .badge]
                )
                // Register categories on first grant so actions are available.
                if granted { await registerCategories() }
                return granted
            } catch {
                AppLog.notifications.error(
                    "Notification authorization request failed: \(error.localizedDescription, privacy: .public)"
                )
                return false
            }
        @unknown default:
            return false
        }
    }

    // MARK: Delivery

    /// Delivers one "new episodes" notification for `notification`. Fires
    /// immediately (nil trigger). Never throws — failures are logged and
    /// swallowed so the caller's background task always completes (#72).
    func deliver(_ notification: NewEpisodeNotification) async {
        let content = UNMutableNotificationContent()
        // Plain text only — no emoji (VoiceOver reads emoji names aloud) (#72).
        content.title = notification.podcastTitle
        content.body = notification.body
        content.sound = .default
        content.categoryIdentifier = Self.newEpisodesCategoryID
        content.userInfo = [
            Self.podcastFeedURLKey: notification.podcastFeedURL,
            Self.episodeGUIDKey: notification.episodeGUID,
        ]

        // A per-podcast identifier coalesces repeat notifications for the same
        // show into a single pending/delivered item rather than stacking.
        let request = UNNotificationRequest(
            identifier: "\(Self.newEpisodesCategoryID).\(notification.podcastFeedURL)",
            content: content,
            trigger: nil
        )

        do {
            try await center.add(request)
            AppLog.notifications.info(
                "Delivered new-episode notification for \(notification.podcastTitle, privacy: .public)"
            )
        } catch {
            AppLog.notifications.error(
                "Failed to deliver notification: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Convenience for delivering a batch (one per podcast).
    func deliver(_ notifications: [NewEpisodeNotification]) async {
        for notification in notifications {
            await deliver(notification)
        }
    }

    /// Delivers an immediate local notification after an audio download has
    /// been committed to the on-device store. Failures never affect the
    /// completed download (#453).
    func deliverDownloadCompleted(
        episodeTitle: String,
        podcastFeedURL: String,
        episodeGUID: String
    ) async {
        let content = UNMutableNotificationContent()
        content.title = "Download complete"
        content.body = episodeTitle
        content.sound = .default
        content.categoryIdentifier = Self.downloadCompletedCategoryID
        content.userInfo = [
            Self.podcastFeedURLKey: podcastFeedURL,
            Self.episodeGUIDKey: episodeGUID,
        ]

        let request = UNNotificationRequest(
            identifier: "\(Self.downloadCompletedCategoryID).\(podcastFeedURL).\(episodeGUID)",
            content: content,
            trigger: nil
        )

        do {
            try await center.add(request)
            AppLog.notifications.info(
                "Delivered download-completion notification for \(episodeTitle, privacy: .public)"
            )
        } catch {
            AppLog.notifications.error(
                "Failed to deliver download-completion notification: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
