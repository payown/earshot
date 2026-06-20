import UIKit

/// Posts VoiceOver announcements for important state changes the user must know
/// about (e.g. "Playing", "Episode added to queue"). Reserve announcements for
/// meaningful changes — don't announce noise.
enum Announcer {
    /// Posts a polite VoiceOver announcement. Safe to call when VoiceOver is off
    /// (it simply does nothing).
    @MainActor
    static func announce(_ message: String) {
        guard !message.isEmpty else { return }
        guard UIAccessibility.isVoiceOverRunning else { return }
        let attributed = NSAttributedString(
            string: message,
            attributes: [.accessibilitySpeechQueueAnnouncement: true]
        )
        UIAccessibility.post(notification: .announcement, argument: attributed)
    }
}
