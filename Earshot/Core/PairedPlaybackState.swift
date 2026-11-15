import Foundation

/// A short-lived transport snapshot. Durable listening progress continues to use
/// the existing local stores and CloudKit projection, never this context.
struct PairedPlaybackState: Codable, Equatable, Sendable {
    static let schemaVersion = 1
    static let contextKey = "earshotPlaybackState"

    enum Owner: String, Codable, Sendable { case phone, watch }

    let version: Int
    let owner: Owner
    let feedURL: String
    let guid: String
    let title: String
    let podcastTitle: String
    let audioURL: String
    let position: Double
    let rate: Double
    let playing: Bool
    let observedAt: TimeInterval
    /// When the episode, position, rate, or transport actually changed. Unlike
    /// observedAt, this does not advance for a repeated lifecycle publication.
    let playbackChangedAt: TimeInterval?

    init(owner: Owner, feedURL: String = "", guid: String = "", title: String = "",
         podcastTitle: String = "", audioURL: String = "", position: Double = 0,
         rate: Double = 1, playing: Bool = false, observedAt: TimeInterval = Date.now.timeIntervalSince1970,
         playbackChangedAt: TimeInterval? = nil) {
        version = Self.schemaVersion
        self.owner = owner
        self.feedURL = feedURL
        self.guid = guid
        self.title = title
        self.podcastTitle = podcastTitle
        self.audioURL = audioURL
        self.position = position.isFinite ? max(0, position) : 0
        self.rate = rate.isFinite ? min(3, max(0.5, rate)) : 1
        self.playing = playing
        self.observedAt = observedAt
        self.playbackChangedAt = playbackChangedAt
    }

    var hasEpisode: Bool { !feedURL.isEmpty && !guid.isEmpty && !title.isEmpty }

    func isCurrent(at now: TimeInterval = Date.now.timeIntervalSince1970) -> Bool {
        observedAt <= now + 5 && now - observedAt < 45
    }

    /// The phone and watch each have one writer for their own state. Arrival
    /// order is not write order; old context must not undo a newer message.
    func supersedes(_ previous: Self?) -> Bool {
        guard version == Self.schemaVersion, position.isFinite, position >= 0,
              rate.isFinite, (0.5...3).contains(rate), observedAt.isFinite,
              observedAt > 0, !title.isEmpty || guid.isEmpty,
              playbackChangedAt.map({ $0.isFinite && $0 > 0 && $0 <= observedAt + 5 }) ?? true else { return false }
        guard let previous else { return true }
        return owner == previous.owner && observedAt > previous.observedAt
    }

    func matches(feedURL: String, guid: String) -> Bool {
        self.guid == guid && FeedURLIdentity.matches(self.feedURL, feedURL)
    }

    /// Publish immediately for identity, transport, rate or deliberate seek;
    /// otherwise a 20-second position checkpoint is enough for live display.
    func needsPublication(after previous: Self?) -> Bool {
        guard let previous else { return true }
        if feedURL != previous.feedURL || guid != previous.guid || playing != previous.playing ||
            rate != previous.rate { return true }
        let elapsed = max(0, observedAt - previous.observedAt)
        if abs(position - (previous.position + (previous.playing ? elapsed * previous.rate : 0))) > 3 {
            return true
        }
        return elapsed >= 20
    }

    func encoded() -> Data? { try? JSONEncoder().encode(self) }

    static func decode(_ value: Any?) -> Self? {
        guard let data = value as? Data, let state = try? JSONDecoder().decode(Self.self, from: data),
              state.version == schemaVersion, state.position.isFinite, state.position >= 0,
              state.rate.isFinite, (0.5...3).contains(state.rate),
              state.observedAt.isFinite, state.observedAt > 0,
              state.playbackChangedAt.map({ $0.isFinite && $0 > 0 && $0 <= state.observedAt + 5 }) ?? true else { return nil }
        return state
    }

    /// A fresh transport observation is not evidence of a new playback
    /// checkpoint. Exact position equality also preserves a seek back to zero.
    func hasPlaybackChange(comparedWith previous: Self?) -> Bool {
        guard let previous else { return true }
        return !matches(feedURL: previous.feedURL, guid: previous.guid) ||
            position != previous.position || rate != previous.rate || playing != previous.playing ||
            audioURL != previous.audioURL || title != previous.title ||
            podcastTitle != previous.podcastTitle
    }
}

enum PairedPlaybackHandoffDecision {
    static func sourcePaused(_ reply: [String: Any], owner: PairedPlaybackState.Owner,
                             feedURL: String, guid: String) -> Bool {
        reply["accepted"] as? Bool == true &&
        reply["owner"] as? String == owner.rawValue &&
        reply["playing"] as? Bool == false &&
        reply["guid"] as? String == guid &&
        (reply["feedURL"] as? String).map { FeedURLIdentity.matches($0, feedURL) } == true
    }

    /// The source's position at its confirmed pause is the handoff position.
    /// The earlier state snapshot can be many seconds old while the receiver buffers.
    static func pausedSourcePosition(_ reply: [String: Any], owner: PairedPlaybackState.Owner,
                                     feedURL: String, guid: String) -> Double? {
        guard sourcePaused(reply, owner: owner, feedURL: feedURL, guid: guid),
              let position = reply["position"] as? Double,
              position.isFinite, position >= 0 else { return nil }
        return position
    }
}
