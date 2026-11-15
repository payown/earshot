import Foundation

/// The phone's last *playback* checkpoint, saved independently of its short-lived
/// reachability state. An older transport message may update the live display,
/// but must never replace the offline continuation.
struct WatchContinuation: Equatable, Sendable {
    let state: PairedPlaybackState

    init?(_ state: PairedPlaybackState) {
        guard state.owner == .phone, state.hasEpisode,
              let changedAt = state.playbackChangedAt, changedAt.isFinite,
              changedAt > 0, changedAt <= state.observedAt + 5,
              let url = URL(string: state.audioURL),
              ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        self.state = state
    }

    var checkpointAt: TimeInterval { state.playbackChangedAt ?? 0 }

    func supersedes(_ previous: Self?) -> Bool {
        guard let previous else { return true }
        return checkpointAt > previous.checkpointAt
    }

    func isNewerThanWatch(_ watchCheckpoint: Date?) -> Bool {
        guard let watchCheckpoint, watchCheckpoint != .distantPast else { return true }
        return checkpointAt > watchCheckpoint.timeIntervalSince1970
    }
}

enum WatchContinuationReply {
    static func pausedCandidate(_ response: [String: Any], matching saved: WatchContinuation,
                                latest: WatchContinuation?,
                                now: TimeInterval = Date.now.timeIntervalSince1970) -> WatchContinuation? {
        guard response["accepted"] as? Bool == true, response["owner"] as? String == "phone",
              response["playing"] as? Bool == false,
              let position = response["position"] as? Double, position.isFinite, position >= 0,
              let rate = response["rate"] as? Double, rate.isFinite, (0.5...3).contains(rate),
              let observedAt = response["observedAt"] as? Double,
              let changedAt = response["playbackChangedAt"] as? Double,
              changedAt.isFinite, changedAt > 0, changedAt <= observedAt + 5 else { return nil }
        let state = PairedPlaybackState(owner: .phone,
                                        feedURL: response["feedURL"] as? String ?? "",
                                        guid: response["guid"] as? String ?? "",
                                        title: response["title"] as? String ?? "",
                                        podcastTitle: response["podcastTitle"] as? String ?? "Podcast",
                                        audioURL: response["audioURL"] as? String ?? "",
                                        position: position, rate: rate, playing: false,
                                        observedAt: observedAt, playbackChangedAt: changedAt)
        guard state.isCurrent(at: now),
              state.matches(feedURL: saved.state.feedURL, guid: saved.state.guid),
              let candidate = WatchContinuation(state),
              candidate.checkpointAt >= saved.checkpointAt,
              candidate.checkpointAt >= (latest?.checkpointAt ?? 0),
              latest?.state.matches(feedURL: state.feedURL, guid: state.guid) != false else { return nil }
        return candidate
    }
}

@MainActor
final class WatchContinuationStore {
    private let defaults: UserDefaults
    private static let key = "watchPhoneContinuation"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var latest: WatchContinuation? {
        guard let state = PairedPlaybackState.decode(defaults.data(forKey: Self.key)) else { return nil }
        return WatchContinuation(state)
    }

    @discardableResult
    func accept(_ state: PairedPlaybackState) -> Bool {
        guard let candidate = WatchContinuation(state), candidate.supersedes(latest),
              let data = state.encoded() else { return false }
        defaults.set(data, forKey: Self.key)
        return true
    }
}
