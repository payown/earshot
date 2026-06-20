import Foundation
import Observation

/// Holds the user's configured episode-action order, persisted in UserDefaults.
/// Mutating `actions` (e.g. from the settings reorder) updates every episode
/// row's VoiceOver rotor live — no relaunch needed.
@Observable
final class QuickActionStore {
    private let key = "episodeActionOrder"

    var actions: [EpisodeAction] {
        didSet { persist() }
    }

    init() {
        let raw = UserDefaults.standard.string(forKey: key) ?? ""
        let parsed = raw
            .split(separator: ",")
            .compactMap { EpisodeAction(rawValue: String($0)) }
        actions = parsed.isEmpty ? defaultEpisodeActions : parsed
    }

    private func persist() {
        let raw = actions.map(\.rawValue).joined(separator: ",")
        UserDefaults.standard.set(raw, forKey: key)
    }
}
