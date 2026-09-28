import Foundation

/// Stable identity for the source currently using Earshot's single player.
/// Episode restoration values retain their historical encoding; local audio is
/// explicitly namespaced so it can never be mistaken for an RSS episode key.
enum PlaybackContentIdentity: Equatable, Sendable {
    case episode(String)
    case personalAudio(String)

    static let personalAudioPrefix = "personal-audio:"

    var restorationValue: String {
        switch self {
        case .episode(let value): value
        case .personalAudio(let id): Self.personalAudioPrefix + id
        }
    }

    init?(restorationValue: String) {
        guard !restorationValue.isEmpty else { return nil }
        if restorationValue.hasPrefix(Self.personalAudioPrefix) {
            let id = String(restorationValue.dropFirst(Self.personalAudioPrefix.count))
            guard !id.isEmpty else { return nil }
            self = .personalAudio(id)
        } else {
            self = .episode(restorationValue)
        }
    }
}
