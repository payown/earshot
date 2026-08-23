import AppIntents
import Foundation

enum PlaybackSkipDirection: Sendable {
    case forward
    case backward
}

/// Shared bounds and copy for Siri/Shortcuts skip requests. Keeping parameter
/// normalization outside App Intents and AVFoundation makes the spoken command
/// behavior deterministic and unit-testable (#551).
enum PlaybackSkipIntentLogic {
    static let minimumSeconds = 1
    static let maximumSeconds = 600

    static func interval(requested: Int?, configured: Int) -> Int {
        min(max(requested ?? configured, minimumSeconds), maximumSeconds)
    }

    static func successDialog(direction: PlaybackSkipDirection, seconds: Int) -> String {
        let word = seconds == 1 ? "second" : "seconds"
        switch direction {
        case .forward:
            return "Skipped forward \(seconds) \(word)."
        case .backward:
            return "Skipped back \(seconds) \(word)."
        }
    }
}

/// Process-lifetime connection between system App Intents and Earshot's one
/// `PlayerService`. App intents may wake the app in the background; `AppRuntime`
/// installs its player as soon as the process is constructed.
@MainActor
final class PlaybackSkipIntentBridge {
    static let shared = PlaybackSkipIntentBridge()

    private weak var player: PlayerService?

    private init() {}

    func install(player: PlayerService) {
        self.player = player
    }

    func skip(_ direction: PlaybackSkipDirection, requestedSeconds: Int?) -> (Bool, Int) {
        guard let player else {
            return (false, PlaybackSkipIntentLogic.minimumSeconds)
        }
        let configured = direction == .forward
            ? player.skipForwardSeconds
            : player.skipBackSeconds
        let seconds = PlaybackSkipIntentLogic.interval(
            requested: requestedSeconds,
            configured: configured
        )
        let skipped: Bool
        switch direction {
        case .forward:
            skipped = player.skipForward(seconds: seconds)
        case .backward:
            skipped = player.skipBack(seconds: seconds)
        }
        return (skipped, seconds)
    }
}

struct SkipForwardIntent: AppIntent {
    static let title: LocalizedStringResource = "Skip Forward in Earshot"
    static let description = IntentDescription(
        "Skips the episode forward by a custom number of seconds. Leave Seconds empty to use Earshot's configured forward interval."
    )

    @Parameter(
        title: "Seconds",
        description: "How many seconds to skip. Leave empty to use Earshot's configured interval.",
        inclusiveRange: (lowerBound: 1, upperBound: 600)
    )
    var seconds: Int?

    static var parameterSummary: some ParameterSummary {
        Summary("Skip forward \(\.$seconds) in Earshot")
    }

    init() {}

    init(seconds: Int?) {
        self.seconds = seconds
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = await PlaybackSkipIntentBridge.shared.skip(
            .forward,
            requestedSeconds: seconds
        )
        guard result.0 else {
            return .result(dialog: "No episode is loaded in Earshot.")
        }
        if result.1 == 1 {
            return .result(dialog: "Skipped forward 1 second.")
        }
        return .result(dialog: "Skipped forward \(result.1) seconds.")
    }
}

struct SkipBackwardIntent: AppIntent {
    static let title: LocalizedStringResource = "Skip Back in Earshot"
    static let description = IntentDescription(
        "Skips the episode backward by a custom number of seconds. Leave Seconds empty to use Earshot's configured back interval."
    )

    @Parameter(
        title: "Seconds",
        description: "How many seconds to skip. Leave empty to use Earshot's configured interval.",
        inclusiveRange: (lowerBound: 1, upperBound: 600)
    )
    var seconds: Int?

    static var parameterSummary: some ParameterSummary {
        Summary("Skip back \(\.$seconds) in Earshot")
    }

    init() {}

    init(seconds: Int?) {
        self.seconds = seconds
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = await PlaybackSkipIntentBridge.shared.skip(
            .backward,
            requestedSeconds: seconds
        )
        guard result.0 else {
            return .result(dialog: "No episode is loaded in Earshot.")
        }
        if result.1 == 1 {
            return .result(dialog: "Skipped back 1 second.")
        }
        return .result(dialog: "Skipped back \(result.1) seconds.")
    }
}

struct EarshotAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SkipForwardIntent(),
            phrases: [
                "Skip forward in \(.applicationName)",
                "Skip ahead in \(.applicationName)",
            ],
            shortTitle: "Skip Forward",
            systemImageName: "goforward"
        )
        AppShortcut(
            intent: SkipBackwardIntent(),
            phrases: [
                "Skip back in \(.applicationName)",
                "Go back in \(.applicationName)",
            ],
            shortTitle: "Skip Back",
            systemImageName: "gobackward"
        )
    }

    static var shortcutTileColor: ShortcutTileColor { .navy }
}
