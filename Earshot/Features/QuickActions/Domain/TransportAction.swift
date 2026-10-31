import Foundation

/// An optional skip control that can be enabled and ordered in Quick Actions.
/// The primary back/forward intervals remain in Playback settings; these
/// actions add extra skip buttons to the full player.
enum TransportAction: String, CaseIterable, Identifiable, Codable {
    case skipBack10
    case skipBack15
    case skipBack30
    case skipBack45
    case skipBack60
    case skipBack120
    case skipBack300
    case skipForward10
    case skipForward15
    case skipForward30
    case skipForward45
    case skipForward60
    case skipForward120
    case skipForward300

    var id: String { rawValue }

    var seconds: Int {
        switch self {
        case .skipBack10, .skipForward10: 10
        case .skipBack15, .skipForward15: 15
        case .skipBack30, .skipForward30: 30
        case .skipBack45, .skipForward45: 45
        case .skipBack60, .skipForward60: 60
        case .skipBack120, .skipForward120: 120
        case .skipBack300, .skipForward300: 300
        }
    }

    var direction: Direction {
        switch self {
        case .skipBack10, .skipBack15, .skipBack30, .skipBack45,
             .skipBack60, .skipBack120, .skipBack300:
            .backward
        case .skipForward10, .skipForward15, .skipForward30, .skipForward45,
             .skipForward60, .skipForward120, .skipForward300:
            .forward
        }
    }

    enum Direction: Equatable {
        case backward
        case forward
    }

    var label: String {
        let interval = secondsLabel
        return "Skip \(direction == .backward ? "back" : "forward") \(interval)"
    }

    /// Short visible text for compact player buttons. The accessibility label
    /// uses ``label`` and spells out the full interval.
    var buttonTitle: String {
        let sign = direction == .backward ? "−" : "+"
        if seconds.isMultiple(of: 60) {
            return "\(sign)\(seconds / 60)m"
        }
        return "\(sign)\(seconds)s"
    }

    var secondsLabel: String {
        if seconds.isMultiple(of: 60) {
            let minutes = seconds / 60
            return "\(minutes) minute\(minutes == 1 ? "" : "s")"
        }
        return "\(seconds) seconds"
    }

    func isPrimary(backSeconds: Int, forwardSeconds: Int) -> Bool {
        switch direction {
        case .backward: seconds == backSeconds
        case .forward: seconds == forwardSeconds
        }
    }
}

let defaultTransportActions: [TransportAction] = []

enum TransportActionVisibility {
    static func visible(
        _ actions: [TransportAction],
        backSeconds: Int,
        forwardSeconds: Int
    ) -> [TransportAction] {
        actions.filter { !$0.isPrimary(backSeconds: backSeconds, forwardSeconds: forwardSeconds) }
    }

    /// Reorders the visible subset while leaving temporarily hidden primary
    /// duplicates in their existing slots. If the Playback default later
    /// changes, the hidden action returns in its original relative position.
    static func movingVisible(
        _ actions: [TransportAction],
        visibleActions: [TransportAction],
        from offsets: IndexSet,
        to destination: Int
    ) -> [TransportAction] {
        var moved = visibleActions
        moved.move(fromOffsets: offsets, toOffset: destination)
        var iterator = moved.makeIterator()
        return actions.map { action in
            visibleActions.contains(action) ? (iterator.next() ?? action) : action
        }
    }
}
