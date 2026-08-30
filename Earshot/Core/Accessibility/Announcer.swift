import CoreHaptics
import UIKit

enum AnnouncementCompletionResult: Equatable {
    case completed
    case interrupted
    case timedOut
}

enum RefreshCompletionHapticStyle: Equatable {
    case light
}

struct RefreshCompletionHapticPlan: Equatable {
    let style: RefreshCompletionHapticStyle
    let impactCount: Int
    let spacingMilliseconds: Int64
}

/// A brief, nonverbal completion cue that never changes VoiceOver focus.
/// Background wakes are deliberately silent: a vibration without an active app
/// has no useful context and iOS may suppress it anyway.
@MainActor
enum RefreshCompletionHaptics {
    static func plan(
        trigger: FeedRefreshTrigger,
        succeeded: Bool,
        applicationIsActive: Bool,
        enabled: Bool
    ) -> RefreshCompletionHapticPlan? {
        guard enabled, succeeded, applicationIsActive else { return nil }
        switch trigger {
        case .manualToolbar, .manualPullToRefresh, .coldLaunch, .foreground:
            return RefreshCompletionHapticPlan(
                style: .light,
                impactCount: 2,
                spacingMilliseconds: 120
            )
        case .backgroundTask, .unspecified:
            return nil
        }
    }

    static func playIfNeeded(
        trigger: FeedRefreshTrigger,
        succeeded: Bool,
        enabled: Bool
    ) {
        guard let plan = plan(
            trigger: trigger,
            succeeded: succeeded,
            applicationIsActive: UIApplication.shared.applicationState == .active,
            enabled: enabled
        ) else { return }

        let feedbackStyle: UIImpactFeedbackGenerator.FeedbackStyle = switch plan.style {
        case .light: .light
        }
        let generator = UIImpactFeedbackGenerator(style: feedbackStyle)
        generator.prepare()
        generator.impactOccurred()
        guard plan.impactCount > 1 else { return }

        Task { @MainActor in
            for _ in 1..<plan.impactCount {
                do {
                    try await Task.sleep(for: .milliseconds(plan.spacingMilliseconds))
                } catch {
                    return
                }
                guard UIApplication.shared.applicationState == .active else { return }
                generator.prepare()
                generator.impactOccurred()
            }
        }
    }
}

enum PlaybackStartHapticMode: Equatable {
    case customMechanicalPress
    case heavyImpactFallback
}

struct PlaybackStartHapticPlan: Equatable {
    let mode: PlaybackStartHapticMode
    let totalDurationMilliseconds: Int
    let pressIntensity: Float
    let pressSharpness: Float
    let tailStartMilliseconds: Int
    let tailDurationMilliseconds: Int
    let tailIntensity: Float
    let tailSharpness: Float
    let tailDecay: Float
}

/// A single rounded pulse for deliberate Play and Resume actions. Automatic
/// queue advance and recovery paths never call this type, preserving the cue's
/// meaning as confirmation of the listener's action.
@MainActor
enum PlaybackStartHaptics {
    private static var engine: CHHapticEngine?

    static func plan(
        enabled: Bool,
        applicationIsActive: Bool,
        supportsCustomHaptics: Bool
    ) -> PlaybackStartHapticPlan? {
        guard enabled, applicationIsActive else { return nil }
        return PlaybackStartHapticPlan(
            mode: supportsCustomHaptics ? .customMechanicalPress : .heavyImpactFallback,
            totalDurationMilliseconds: 210,
            pressIntensity: 0.95,
            pressSharpness: 0.38,
            tailStartMilliseconds: 10,
            tailDurationMilliseconds: 200,
            tailIntensity: 0.46,
            tailSharpness: 0.02,
            tailDecay: 0.52
        )
    }

    static func playIfNeeded(enabled: Bool) {
        let supportsCustomHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics
        guard let plan = plan(
            enabled: enabled,
            applicationIsActive: UIApplication.shared.applicationState == .active,
            supportsCustomHaptics: supportsCustomHaptics
        ) else { return }

        guard plan.mode == .customMechanicalPress else {
            playFallback()
            return
        }

        do {
            let hapticEngine: CHHapticEngine
            if let engine {
                hapticEngine = engine
            } else {
                let created = try CHHapticEngine()
                created.playsHapticsOnly = true
                engine = created
                hapticEngine = created
            }
            try hapticEngine.start()
            let pressParameters = [
                CHHapticEventParameter(
                    parameterID: .hapticIntensity,
                    value: plan.pressIntensity
                ),
                CHHapticEventParameter(
                    parameterID: .hapticSharpness,
                    value: plan.pressSharpness
                ),
            ]
            let press = CHHapticEvent(
                eventType: .hapticTransient,
                parameters: pressParameters,
                relativeTime: 0
            )
            let tailParameters = [
                CHHapticEventParameter(
                    parameterID: .hapticIntensity,
                    value: plan.tailIntensity
                ),
                CHHapticEventParameter(
                    parameterID: .hapticSharpness,
                    value: plan.tailSharpness
                ),
                CHHapticEventParameter(parameterID: .decayTime, value: plan.tailDecay),
                CHHapticEventParameter(parameterID: .sustained, value: 0),
            ]
            let tail = CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: tailParameters,
                relativeTime: Double(plan.tailStartMilliseconds) / 1_000,
                duration: Double(plan.tailDurationMilliseconds) / 1_000
            )
            let pattern = try CHHapticPattern(events: [press, tail], parameters: [])
            let player = try hapticEngine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            engine = nil
            playFallback()
        }
    }

    private static func playFallback() {
        let generator = UIImpactFeedbackGenerator(style: .heavy)
        generator.prepare()
        generator.impactOccurred(intensity: 0.8)
    }
}

enum PlaybackPauseHapticMode: Equatable {
    case customMechanicalRelease
    case rigidImpactFallback
}

struct PlaybackPauseHapticPlan: Equatable {
    let mode: PlaybackPauseHapticMode
    let totalDurationMilliseconds: Int
    let leadDurationMilliseconds: Int
    let leadIntensity: Float
    let leadSharpness: Float
    let releaseStartMilliseconds: Int
    let releaseIntensity: Float
    let releaseSharpness: Float
}

/// A short mechanical-release cue for deliberate Pause actions. The custom
/// pattern reverses the start cue's transient-then-tail shape: a quiet lead-in
/// ends in one crisp tap. Automatic stops and interruptions never call this
/// type, preserving the cue's meaning as confirmation of the listener's action.
@MainActor
enum PlaybackPauseHaptics {
    private static var engine: CHHapticEngine?

    static func plan(
        enabled: Bool,
        applicationIsActive: Bool,
        supportsCustomHaptics: Bool
    ) -> PlaybackPauseHapticPlan? {
        guard enabled, applicationIsActive else { return nil }
        return PlaybackPauseHapticPlan(
            mode: supportsCustomHaptics ? .customMechanicalRelease : .rigidImpactFallback,
            totalDurationMilliseconds: 80,
            leadDurationMilliseconds: 72,
            leadIntensity: 0.18,
            leadSharpness: 0.05,
            releaseStartMilliseconds: 72,
            releaseIntensity: 0.62,
            releaseSharpness: 0.9
        )
    }

    static func playIfNeeded(enabled: Bool) {
        let supportsCustomHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics
        guard let plan = plan(
            enabled: enabled,
            applicationIsActive: UIApplication.shared.applicationState == .active,
            supportsCustomHaptics: supportsCustomHaptics
        ) else { return }

        guard plan.mode == .customMechanicalRelease else {
            playFallback()
            return
        }

        do {
            let hapticEngine: CHHapticEngine
            if let engine {
                hapticEngine = engine
            } else {
                let created = try CHHapticEngine()
                created.playsHapticsOnly = true
                engine = created
                hapticEngine = created
            }
            try hapticEngine.start()
            let lead = CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [
                    CHHapticEventParameter(
                        parameterID: .hapticIntensity,
                        value: plan.leadIntensity
                    ),
                    CHHapticEventParameter(
                        parameterID: .hapticSharpness,
                        value: plan.leadSharpness
                    ),
                ],
                relativeTime: 0,
                duration: Double(plan.leadDurationMilliseconds) / 1_000
            )
            let release = CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(
                        parameterID: .hapticIntensity,
                        value: plan.releaseIntensity
                    ),
                    CHHapticEventParameter(
                        parameterID: .hapticSharpness,
                        value: plan.releaseSharpness
                    ),
                ],
                relativeTime: Double(plan.releaseStartMilliseconds) / 1_000
            )
            let pattern = try CHHapticPattern(events: [lead, release], parameters: [])
            let player = try hapticEngine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            engine = nil
            playFallback()
        }
    }

    private static func playFallback() {
        let generator = UIImpactFeedbackGenerator(style: .rigid)
        generator.prepare()
        generator.impactOccurred(intensity: 0.55)
    }
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
    /// finished. Progress announcements never gate presentation of the ready UI.
    /// The final completion announcement retains its four-second fallback because
    /// UIKit may omit its completion notification (#781).
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
