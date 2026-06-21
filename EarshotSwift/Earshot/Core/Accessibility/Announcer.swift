import UIKit

/// Posts VoiceOver announcements for important state changes the user must know
/// about (e.g. "Playing", "Episode added to queue"). Reserve announcements for
/// meaningful changes — don't announce noise.
enum Announcer {
    /// Posts a VoiceOver announcement. Safe to call when VoiceOver is off (it
    /// simply does nothing). Polite by default (queued behind the user's current
    /// speech); pass `assertive: true` only for moments the user must hear
    /// promptly, like an operation completing — it interrupts current speech.
    @MainActor
    static func announce(_ message: String, assertive: Bool = false) {
        guard !message.isEmpty else { return }
        guard UIAccessibility.isVoiceOverRunning else { return }
        let attributes: [NSAttributedString.Key: Any] =
            assertive ? [:] : [.accessibilitySpeechQueueAnnouncement: true]
        let attributed = NSAttributedString(string: message, attributes: attributes)
        UIAccessibility.post(notification: .announcement, argument: attributed)
    }
}
