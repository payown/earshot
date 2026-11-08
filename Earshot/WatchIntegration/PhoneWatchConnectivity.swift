import Foundation
import SwiftData
import WatchConnectivity

/// An optional, immediate control channel. The phone library remains authoritative
/// in its own store; no watch store or CloudKit record is opened here.
@MainActor
final class PhoneWatchConnectivity: NSObject, WCSessionDelegate {
    static let shared = PhoneWatchConnectivity()
    private weak var runtime: AppRuntime?
    private var seenCommands: [String: [String: Any]] = [:]

    func start(runtime: AppRuntime) {
        guard WCSession.isSupported() else { return }
        self.runtime = runtime
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        let id = message["id"] as? String ?? ""
        let command = message["command"] as? String ?? ""
        let feed = message["feedURL"] as? String
        let guid = message["guid"] as? String
        let position = message["position"] as? Double
        let rate = message["rate"] as? Double
        let offset = message["offset"] as? Int ?? 0
        let reply = WatchReplyBox(replyHandler)
        Task { @MainActor [weak self] in
            guard let self else { reply.send(["accepted": false, "reason": "Phone service unavailable"]); return }
            reply.send(self.perform(id: id, command: command, feedURL: feed, guid: guid, position: position, rate: rate, offset: offset))
        }
    }

    private func perform(id: String, command: String, feedURL: String?, guid: String?, position: Double?, rate: Double?, offset: Int) -> [String: Any] {
        guard !id.isEmpty else { return ["accepted": false, "reason": "Invalid request"] }
        if let prior = seenCommands[id] { return prior }
        guard let runtime else { return ["accepted": false, "reason": "Phone service unavailable"] }
        let player = runtime.player
        var accepted = true
        var reason = ""
        switch command {
        case "state": break
        case "library":
            guard let container = runtime.readyContainer else {
                return ["accepted": false, "reason": "Phone library unavailable"]
            }
            let descriptor = FetchDescriptor<Podcast>(sortBy: [SortDescriptor(\.feedURL)])
            let subscriptions = ((try? container.mainContext.fetch(descriptor)) ?? []).filter(\.isFollowed)
            let page = subscriptions.dropFirst(max(0, offset)).prefix(50).map {
                WatchFeedSnapshot(feedURL: $0.feedURL, title: $0.title, author: $0.author ?? "", summary: $0.podcastDescription ?? "", artworkURL: $0.artworkURL)
            }
            guard let data = try? JSONEncoder().encode(page) else {
                return ["accepted": false, "reason": "Could not encode library page"]
            }
            return ["accepted": true, "feeds": data, "nextOffset": offset + page.count,
                    "hasMore": offset + page.count < subscriptions.count]
        case "toggle": player.togglePlayPause()
        case "pause": player.pause()
        case "back": player.skipBack()
        case "forward": player.skipForward()
        case "play":
            guard let feedURL, let guid, let container = runtime.readyContainer else {
                return ["accepted": false, "reason": "Phone library unavailable"]
            }
            let descriptor = FetchDescriptor<Episode>(predicate: #Predicate {
                $0.guid == guid && $0.podcast?.feedURL == feedURL
            })
            if let episode = try? container.mainContext.fetch(descriptor).first {
                if let rate { player.setGlobalSpeed(rate, announce: false) }
                player.play(episode, at: max(0, position ?? 0))
            } else {
                accepted = false
                reason = "Episode is not in the phone library"
            }
        default:
            accepted = false
            reason = "Unsupported request"
        }
        var result = snapshot(player: player)
        result["accepted"] = accepted
        if !accepted { result["reason"] = reason }
        if command != "state" {
            seenCommands[id] = result
            if seenCommands.count > 128 { seenCommands.removeAll() }
        }
        return result
    }

    private func snapshot(player: PlayerService) -> [String: Any] {
        var result: [String: Any] = [
            "version": 1,
            "owner": "phone",
            "playing": player.isPlaying,
            "position": player.currentPositionSeconds,
            "rate": player.effectiveRate,
            "observedAt": Date.now.timeIntervalSince1970
        ]
        if let episode = player.nowPlayingEpisode {
            result["title"] = episode.title
            result["guid"] = episode.guid
            result["feedURL"] = episode.podcast?.feedURL ?? ""
            result["audioURL"] = episode.audioURL
        }
        return result
    }
}

/// WCSession's reply closure is delivered on a framework queue. This wrapper
/// transfers ownership once to the main actor and calls it exactly once.
private final class WatchReplyBox: @unchecked Sendable {
    private let callback: ([String: Any]) -> Void
    init(_ callback: @escaping ([String: Any]) -> Void) { self.callback = callback }
    func send(_ value: [String: Any]) { callback(value) }
}
