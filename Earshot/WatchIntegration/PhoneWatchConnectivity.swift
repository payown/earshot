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
    private var lastPublished: PairedPlaybackState?
    private var lastWatchState: PairedPlaybackState?
    private var isObservingPlayer = false
    private var handoffPending = false
    private(set) var watchStatus = "Apple Watch state has not been checked"
    private(set) var watchPlaying = false
    private(set) var watchEpisodeTitle = ""
    private(set) var watchPosition: Double = 0
    private(set) var watchPodcastTitle = ""
    private(set) var watchFeedURL = ""
    private(set) var watchGUID = ""
    private(set) var watchAudioURL = ""
    private(set) var watchRate: Double = 1
    var watchSessionIsLive: Bool {
        WCSession.isSupported() && WCSession.default.activationState == .activated &&
        WCSession.default.isReachable && lastWatchState?.isCurrent() == true
    }
    var hasWatchEpisode: Bool { lastWatchState?.hasEpisode == true }

    func sendWatchControl(_ command: String, announce: Bool = true) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              WCSession.default.isWatchAppInstalled, WCSession.default.isReachable else {
            watchStatus = "Apple Watch is unreachable. No control was sent."
            if announce { AccessibilityNotification.Announcement(watchStatus).post() }
            return
        }
        watchStatus = "Contacting Apple Watch"
        WCSession.default.sendMessage(["version": 1, "id": UUID().uuidString,
                                       "command": command]) { @Sendable [weak self] response in
            let accepted = response["accepted"] as? Bool ?? false
            let owner = response["owner"] as? String ?? ""
            let reason = response["reason"] as? String ?? ""
            let state = PairedPlaybackState(owner: .watch,
                                            feedURL: response["feedURL"] as? String ?? "",
                                            guid: response["guid"] as? String ?? "",
                                            title: response["title"] as? String ?? "",
                                            podcastTitle: response["podcastTitle"] as? String ?? "",
                                            audioURL: response["audioURL"] as? String ?? "",
                                            position: response["position"] as? Double ?? 0,
                                            rate: response["rate"] as? Double ?? 1,
                                            playing: response["playing"] as? Bool ?? false,
                                            observedAt: response["observedAt"] as? Double ?? 0)
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard owner == "watch" else {
                    self.watchStatus = "Apple Watch response could not be verified."
                    if announce { AccessibilityNotification.Announcement(self.watchStatus).post() }
                    return
                }
                self.acceptWatchState(state)
                if !accepted { self.watchStatus = "Apple Watch request failed: \(reason)" }
                if announce { AccessibilityNotification.Announcement(self.watchStatus).post() }
            }
        } errorHandler: { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                self?.watchStatus = "Apple Watch did not confirm the request. Its playback is unchanged."
                if announce {
                    AccessibilityNotification.Announcement("Apple Watch did not confirm the request. Its playback is unchanged.").post()
                }
            }
        }
    }

    /// Starts the exact watch episode on iPhone, then asks the watch to pause.
    /// A lost or negative watch acknowledgement stops the new phone playback.
    func handoffFromWatch() {
        guard !handoffPending, WCSession.isSupported(), WCSession.default.activationState == .activated,
              WCSession.default.isWatchAppInstalled, WCSession.default.isReachable else {
            watchStatus = "Apple Watch is unreachable. No transfer was started."
            AccessibilityNotification.Announcement(watchStatus).post()
            return
        }
        handoffPending = true
        watchStatus = "Checking current Apple Watch playback"
        WCSession.default.sendMessage(["version": 1, "id": UUID().uuidString, "command": "state"]) {
            @Sendable [weak self] response in
            let valid = response["owner"] as? String == "watch" && response["accepted"] as? Bool == true
            let state = PairedPlaybackState(owner: .watch,
                                            feedURL: response["feedURL"] as? String ?? "",
                                            guid: response["guid"] as? String ?? "",
                                            title: response["title"] as? String ?? "",
                                            podcastTitle: response["podcastTitle"] as? String ?? "",
                                            audioURL: response["audioURL"] as? String ?? "",
                                            position: response["position"] as? Double ?? 0,
                                            rate: response["rate"] as? Double ?? 1,
                                            playing: response["playing"] as? Bool ?? false,
                                            observedAt: response["observedAt"] as? Double ?? 0)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.acceptWatchState(state)
                guard valid, state.hasEpisode, state.playing, state.isCurrent(),
                      let runtime = self.runtime, let container = runtime.readyContainer,
                      let episode = self.findEpisode(feedURL: state.feedURL, guid: state.guid,
                                                     container: container) else {
                    self.handoffPending = false
                    self.watchStatus = "Watch playback changed or this episode is unavailable on iPhone. No transfer occurred."
                    AccessibilityNotification.Announcement(self.watchStatus).post()
                    return
                }
                let player = runtime.player
                player.play(episode, at: state.position, handoffRate: state.rate)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    for _ in 0..<20 {
                        if player.isAudiblyPlayingForWatchHandoff,
                           player.nowPlayingEpisode?.guid == state.guid,
                           FeedURLIdentity.matches(player.nowPlayingEpisode?.podcast?.feedURL ?? "", state.feedURL) {
                            break
                        }
                        try? await Task.sleep(for: .milliseconds(500))
                    }
                    guard player.isAudiblyPlayingForWatchHandoff,
                          player.nowPlayingEpisode?.guid == state.guid,
                          FeedURLIdentity.matches(player.nowPlayingEpisode?.podcast?.feedURL ?? "", state.feedURL) else {
                        // Also cancels a delayed cleartext URL resolution before it
                        // can start after this timeout and create double playback.
                        player.pause()
                        self.handoffPending = false
                        self.watchStatus = "iPhone could not start audio. Apple Watch continues."
                        AccessibilityNotification.Announcement(self.watchStatus).post()
                        return
                    }
                    guard WCSession.default.isReachable else {
                        player.pause()
                        self.handoffPending = false
                        self.watchStatus = "Apple Watch disconnected before transfer completed. iPhone stopped."
                        AccessibilityNotification.Announcement(self.watchStatus).post()
                        return
                    }
                    self.watchStatus = "Stopping playback on Apple Watch"
                    WCSession.default.sendMessage(["version": 1, "id": UUID().uuidString,
                                                   "command": "pauseIfEpisode", "feedURL": state.feedURL,
                                                   "guid": state.guid]) { @Sendable [weak self] reply in
                        let paused = PairedPlaybackHandoffDecision.sourcePaused(reply, owner: .watch,
                                                                                 feedURL: state.feedURL,
                                                                                 guid: state.guid)
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            self.handoffPending = false
                            if paused {
                                self.watchPlaying = false
                                self.watchStatus = "Playback transferred to iPhone"
                            } else {
                                player.pause()
                                self.watchStatus = "Apple Watch did not confirm pause. iPhone playback stopped."
                            }
                            AccessibilityNotification.Announcement(self.watchStatus).post()
                        }
                    } errorHandler: { @Sendable [weak self] _ in
                        Task { @MainActor [weak self] in
                            player.pause()
                            self?.handoffPending = false
                            self?.watchStatus = "Apple Watch did not confirm pause. iPhone playback stopped."
                            AccessibilityNotification.Announcement("Apple Watch did not confirm pause. iPhone playback stopped.").post()
                        }
                    }
                }
            }
        } errorHandler: { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handoffPending = false
                self?.watchStatus = "Apple Watch did not confirm its playback state. No transfer occurred."
                AccessibilityNotification.Announcement("Apple Watch did not confirm its playback state. No transfer occurred.").post()
            }
        }
    }

    func start(runtime: AppRuntime) {
        guard WCSession.isSupported() else { return }
        self.runtime = runtime
        let session = WCSession.default
        session.delegate = self
        session.activate()
        if let state = PairedPlaybackState.decode(session.receivedApplicationContext[PairedPlaybackState.contextKey]),
           state.owner == .watch { acceptWatchState(state) }
        if !isObservingPlayer {
            isObservingPlayer = true
            observePlayer()
        }
    }

    private func observePlayer() {
        guard let player = runtime?.player else { return }
        withObservationTracking {
            _ = player.nowPlayingEpisodeID
            _ = player.isPlaying
            _ = player.currentPositionSeconds
            _ = player.effectiveRate
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observePlayer()
                self?.publishPlaybackState()
            }
        }
    }

    private func currentState() -> PairedPlaybackState {
        guard let player = runtime?.player,
              let episode = player.nowPlayingEpisode, !episode.isDeleted else {
            return PairedPlaybackState(owner: .phone)
        }
        return PairedPlaybackState(owner: .phone, feedURL: episode.podcast?.feedURL ?? "",
                                   guid: episode.guid, title: episode.title,
                                   podcastTitle: episode.podcast?.title ?? "Podcast",
                                   audioURL: episode.audioURL, position: player.currentPositionSeconds,
                                   rate: player.effectiveRate, playing: player.isPlaying)
    }

    private func publishPlaybackState(force: Bool = false) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        let state = currentState()
        guard force || state.needsPublication(after: lastPublished), let data = state.encoded() else { return }
        do {
            try session.updateApplicationContext([PairedPlaybackState.contextKey: data])
            lastPublished = state
        } catch {
            AppLog.player.info("Watch playback context deferred: \(error.localizedDescription, privacy: .public)")
        }
        if session.isReachable {
            session.sendMessage(["version": PairedPlaybackState.schemaVersion,
                                 "kind": "playbackState", PairedPlaybackState.contextKey: data],
                                replyHandler: nil, errorHandler: nil)
        }
    }

    func publishLifecycleState() {
        guard runtime != nil else { return }
        publishPlaybackState(force: true)
    }

    private func acceptWatchState(_ state: PairedPlaybackState) {
        guard state.owner == .watch, state.supersedes(lastWatchState) else { return }
        lastWatchState = state
        watchPlaying = state.playing
        watchEpisodeTitle = state.title
        watchPosition = state.position
        watchPodcastTitle = state.podcastTitle
        watchFeedURL = state.feedURL
        watchGUID = state.guid
        watchAudioURL = state.audioURL
        watchRate = state.rate
        watchStatus = state.hasEpisode
            ? (watchSessionIsLive ? (state.playing ? "Apple Watch is playing" : "Apple Watch is paused")
               : "Last reported Apple Watch playback")
            : "Apple Watch has no current episode"
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

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor [weak self] in
            if activationState == .activated { self?.publishPlaybackState(force: true) }
        }
    }
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor [weak self] in
            self?.publishPlaybackState(force: true)
            if !reachable, self?.hasWatchEpisode == true {
                self?.watchStatus = "Apple Watch is unavailable. Last reported playback is shown."
            }
        }
    }
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in self?.publishPlaybackState(force: true) }
    }
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let state = PairedPlaybackState.decode(applicationContext[PairedPlaybackState.contextKey]) else { return }
        Task { @MainActor [weak self] in self?.acceptWatchState(state) }
    }
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard message["kind"] as? String == "playbackState",
              let state = PairedPlaybackState.decode(message[PairedPlaybackState.contextKey]) else { return }
        Task { @MainActor [weak self] in self?.acceptWatchState(state) }
    }
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
                    // Cancel a deferred URL resolution too; it must not begin
                    // after the watch has received a failed start response.
                    player.pause()
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
        case "back":
            if player.nowPlayingEpisode == nil { accepted = false; reason = "Start an episode on iPhone first" }
            else { player.skipBack() }
        case "forward":
            if player.nowPlayingEpisode == nil { accepted = false; reason = "Start an episode on iPhone first" }
            else { player.skipForward() }
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
                if let rate { player.play(episode, at: max(0, position ?? 0), handoffRate: rate) }
                else { player.play(episode, at: max(0, position ?? 0)) }
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
        if command != "library" && command != "quickActions" { publishPlaybackState(force: true) }
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
