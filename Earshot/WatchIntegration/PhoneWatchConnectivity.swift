import Foundation
import SwiftData
import WatchConnectivity
import Observation
import Accessibility

/// An optional, immediate control channel. The phone library remains authoritative
/// in its own store; no watch store or CloudKit record is opened here.
@MainActor
@Observable
final class PhoneWatchConnectivity: NSObject, WCSessionDelegate {
    static let shared = PhoneWatchConnectivity()
    private weak var runtime: AppRuntime?
    private var seenCommands: [String: [String: Any]] = [:]
    private(set) var watchStatus = "Apple Watch state has not been checked"
    private(set) var watchPlaying = false
    private(set) var watchEpisodeTitle = ""
    private(set) var watchPosition: Double = 0

    func sendWatchControl(_ command: String) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              WCSession.default.isWatchAppInstalled, WCSession.default.isReachable else {
            watchStatus = "Apple Watch is unreachable. No control was sent."
            AccessibilityNotification.Announcement(watchStatus).post()
            return
        }
        watchStatus = "Contacting Apple Watch"
        WCSession.default.sendMessage(["version": 1, "id": UUID().uuidString,
                                       "command": command]) { @Sendable [weak self] response in
            let accepted = response["accepted"] as? Bool ?? false
            let owner = response["owner"] as? String ?? ""
            let playing = response["playing"] as? Bool ?? false
            let title = response["title"] as? String ?? ""
            let position = response["position"] as? Double ?? 0
            let reason = response["reason"] as? String ?? ""
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard owner == "watch" else {
                    self.watchStatus = "Apple Watch response could not be verified."
                    AccessibilityNotification.Announcement(self.watchStatus).post()
                    return
                }
                self.watchPlaying = playing
                self.watchEpisodeTitle = title
                self.watchPosition = position
                self.watchStatus = accepted
                    ? (playing ? "Apple Watch reports playback active" : "Apple Watch reports playback paused")
                    : "Apple Watch request failed: \(reason)"
                AccessibilityNotification.Announcement(self.watchStatus).post()
            }
        } errorHandler: { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                self?.watchStatus = "Apple Watch did not confirm the request. Its playback is unchanged."
                AccessibilityNotification.Announcement("Apple Watch did not confirm the request. Its playback is unchanged.").post()
            }
        }
    }

    func start(runtime: AppRuntime) {
        guard WCSession.isSupported() else { return }
        self.runtime = runtime
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func queueWatchDownload(_ record: SearchContent) -> Bool {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              WCSession.default.isPaired, WCSession.default.isWatchAppInstalled,
              let guid = record.guid, let runtime, let container = runtime.readyContainer else {
            return false
        }
        guard let episode = findEpisode(feedURL: record.feedURL, guid: guid, container: container),
              episode.podcast != nil else {
            return false
        }
        return queueWatchDownload(episode: episode)
    }

    func queueWatchDownload(episode: Episode) -> Bool {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              WCSession.default.isPaired, WCSession.default.isWatchAppInstalled,
              let podcast = episode.podcast,
              let url = URL(string: episode.audioURL), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else {
            return false
        }
        let request = WatchDownloadRequest(id: UUID(), feedURL: podcast.feedURL, guid: episode.guid,
                                           title: episode.title, podcastTitle: podcast.title,
                                           audioURL: url.absoluteString)
        guard let data = try? JSONEncoder().encode(request) else { return false }
        WCSession.default.transferUserInfo(["version": 1, "kind": "downloadRequest", "data": data])
        return true
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
            var result = self.perform(id: id, command: command, feedURL: feed, guid: guid,
                                      position: position, rate: rate, offset: offset)
            if command == "play", result["accepted"] as? Bool == true,
               let player = self.runtime?.player {
                for _ in 0..<20 {
                    if player.isAudiblyPlayingForWatchHandoff,
                       player.nowPlayingEpisode?.guid == guid,
                       FeedURLIdentity.matches(player.nowPlayingEpisode?.podcast?.feedURL ?? "", feed ?? "") { break }
                    try? await Task.sleep(for: .milliseconds(500))
                }
                if player.isAudiblyPlayingForWatchHandoff,
                   player.nowPlayingEpisode?.guid == guid,
                   FeedURLIdentity.matches(player.nowPlayingEpisode?.podcast?.feedURL ?? "", feed ?? "") {
                    result = self.snapshot(player: player)
                    result["accepted"] = true
                } else {
                    if player.nowPlayingEpisode?.guid == guid,
                       FeedURLIdentity.matches(player.nowPlayingEpisode?.podcast?.feedURL ?? "", feed ?? "") { player.pause() }
                    result = self.snapshot(player: player)
                    result["accepted"] = false
                    result["reason"] = "Phone audio did not become ready"
                }
                self.seenCommands[id] = result
            }
            reply.send(result)
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
        case "quickActions":
            guard let container = runtime.readyContainer else {
                return ["accepted": false, "reason": "Phone settings unavailable"]
            }
            let order = QuickActionRepository(context: container.mainContext).episodeOrder().map(\.rawValue)
            return ["accepted": true, "episodeActions": order]
        case "toggle": player.togglePlayPause()
        case "pause": player.pause()
        case "pauseIfEpisode":
            if let feedURL, let guid,
               player.nowPlayingEpisode?.guid == guid,
               FeedURLIdentity.matches(player.nowPlayingEpisode?.podcast?.feedURL ?? "", feedURL) {
                player.pause()
            } else {
                accepted = false
                reason = "Phone playback changed before handoff"
            }
        case "back": player.skipBack()
        case "forward": player.skipForward()
        case "prepareHandoff":
            guard let feedURL, let guid, let container = runtime.readyContainer else {
                return ["accepted": false, "reason": "Phone library unavailable"]
            }
            if findEpisode(feedURL: feedURL, guid: guid, container: container) == nil {
                accepted = false
                reason = "Episode is not in the phone library"
            }
        case "play":
            guard let feedURL, let guid, let container = runtime.readyContainer else {
                return ["accepted": false, "reason": "Phone library unavailable"]
            }
            if let episode = findEpisode(feedURL: feedURL, guid: guid, container: container) {
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
            result["podcastTitle"] = episode.podcast?.title ?? "Podcast"
        }
        return result
    }

    private func findEpisode(feedURL: String, guid: String, container: ModelContainer) -> Episode? {
        let context = container.mainContext
        guard let podcast = try? PodcastIdentityService(context: context).existingAnyState(feedURL: feedURL) else {
            return nil
        }
        let podcastID = podcast.persistentModelID
        let descriptor = FetchDescriptor<Episode>(predicate: #Predicate {
            $0.guid == guid && $0.podcast?.persistentModelID == podcastID
        })
        return try? context.fetch(descriptor).first
    }
}

/// WCSession's reply closure is delivered on a framework queue. This wrapper
/// transfers ownership once to the main actor and calls it exactly once.
private final class WatchReplyBox: @unchecked Sendable {
    private let callback: ([String: Any]) -> Void
    init(_ callback: @escaping ([String: Any]) -> Void) { self.callback = callback }
    func send(_ value: [String: Any]) { callback(value) }
}
