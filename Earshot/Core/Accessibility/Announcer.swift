import UIKit

enum AnnouncementCompletionResult: Equatable {
    case completed
    case interrupted
    case timedOut
}

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
        let attributed = NSAttributedString(
            string: message,
            attributes: announcementAttributes(assertive: assertive, languageTag: localeBCP47)
        )
        UIAccessibility.post(notification: .announcement, argument: attributed)
    }

    /// Posts an announcement and waits until VoiceOver reports whether it
    /// finished. Every launch announcement has a bounded timeout: UIKit may omit
    /// its completion notification, and missing speech must never hold the ready
    /// UI indefinitely. Progress remains serialized; the completion retains its
    /// four-second fallback before the launch screen is removed (#781).
    @MainActor
    static func announceAndWaitForCompletion(
        _ message: String,
        assertive: Bool,
        timeout: Duration?
    ) async -> AnnouncementCompletionResult {
        guard !message.isEmpty, UIAccessibility.isVoiceOverRunning else { return .completed }
        let waiter = AnnouncementCompletionWaiter(message: message)
        return await waiter.wait(timeout: timeout) {
            announce(message, assertive: assertive)
        }
    }

    /// Builds the attribute dictionary for an announcement. Pure and testable —
    /// the `UIAccessibility.post` side effect can't be unit-tested, but the
    /// attribute wiring (queue behavior + pinned language, #688) can.
    ///
    /// Pins `accessibilitySpeechLanguage` to the user's system language so
    /// VoiceOver's automatic language detection can't switch voices mid-utterance
    /// (#688). Announcements routinely interpolate UNTRUSTED feed data — episode
    /// and podcast titles from RSS, which often embed raw URLs or tracking tokens
    /// (`…?utm=…`). Without a pinned language, VoiceOver reads such a fragment,
    /// decides it is another language, and flips to a different (often
    /// higher-pitched) voice partway through the sentence — the garbled
    /// announcement a VoiceOver tester reported.
    ///
    /// TRADE-OFF (deliberate, NOT a bug): a genuinely foreign-language title
    /// (e.g. a Spanish podcast title for a user whose system language is English)
    /// is now spoken in the user's system voice, which may mispronounce it. That
    /// is the right call — a mispronounced real title beats a garbled voice-switch
    /// every time — but it means a future "why is my Spanish podcast title
    /// anglicized" report is EXPECTED behavior, not a regression. If per-title
    /// language ever matters, the correct fix is tagging the specific title span
    /// with its own language, not removing this pin.
    static func announcementAttributes(
        assertive: Bool,
        languageTag: String?
    ) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] =
            assertive ? [:] : [.accessibilitySpeechQueueAnnouncement: true]
        if let languageTag, !languageTag.isEmpty {
            attributes[.accessibilitySpeechLanguage] = languageTag
        }
        return attributes
    }

    /// The user's current language as a BCP-47 tag (e.g. `en-US`) for
    /// `accessibilitySpeechLanguage`. `Locale.identifier(.bcp47)` yields the
    /// hyphenated form VoiceOver expects, unlike the POSIX `en_US`.
    static var localeBCP47: String? {
        let tag = Locale.current.identifier(.bcp47)
        return tag.isEmpty ? nil : tag
    }

    static func completionResult(wasSuccessful: Bool?) -> AnnouncementCompletionResult {
        wasSuccessful == false ? .interrupted : .completed
    }
}

/// Bridges UIKit's callback notification into one bounded async wait. Kept
/// private to ``Announcer``'s file so launch code never observes UIKit directly.
@MainActor
private final class AnnouncementCompletionWaiter {
    private let message: String
    private var observer: NSObjectProtocol?
    private var timeoutTask: Task<Void, Never>?
    private var continuation: CheckedContinuation<AnnouncementCompletionResult, Never>?

    init(message: String) {
        self.message = message
    }

    func wait(
        timeout: Duration?,
        post: () -> Void
    ) async -> AnnouncementCompletionResult {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            observer = NotificationCenter.default.addObserver(
                forName: UIAccessibility.announcementDidFinishNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let value = notification.userInfo?[
                    UIAccessibility.announcementStringValueUserInfoKey
                ]
                let finishedMessage = (value as? String)
                    ?? (value as? NSAttributedString)?.string
                let wasSuccessful = notification.userInfo?[
                    UIAccessibility.announcementWasSuccessfulUserInfoKey
                ] as? Bool
                Task { @MainActor [weak self] in
                    self?.received(finishedMessage, wasSuccessful: wasSuccessful)
                }
            }
            if let timeout {
                timeoutTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    self?.finish(.timedOut)
                }
            }
            post()
        }
    }

    private func received(_ finishedMessage: String?, wasSuccessful: Bool?) {
        guard finishedMessage == message else { return }
        finish(Announcer.completionResult(wasSuccessful: wasSuccessful))
    }

    private func finish(_ result: AnnouncementCompletionResult) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        continuation.resume(returning: result)
    }
}
