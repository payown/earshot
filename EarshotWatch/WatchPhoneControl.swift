import Foundation
import Observation
import SwiftUI
import WatchConnectivity
import Accessibility

enum WatchHandoffDecision {
    static func phoneConfirmed(_ reply: [String: Any], feedURL: String, guid: String) -> Bool {
        reply["owner"] as? String == "phone" &&
        reply["accepted"] as? Bool == true &&
        reply["playing"] as? Bool == true &&
        (reply["feedURL"] as? String).map { FeedURLIdentity.matches($0, feedURL) } == true &&
        reply["guid"] as? String == guid
    }
}

@MainActor
@Observable
final class WatchPhoneControl: NSObject, WCSessionDelegate {
    private(set) var phoneAvailable = false
    private(set) var phonePlaying = false
    private(set) var phoneEpisodeTitle = ""
    private(set) var phonePosition: Double = 0
    private(set) var phoneFeedURL = ""
    private(set) var phoneGUID = ""
    private(set) var phoneAudioURL = ""
    private(set) var phonePodcastTitle = "Podcast"
    private(set) var phoneRate: Float = 1
    private(set) var phoneObservedAt: Date = .distantPast
    private(set) var status = "iPhone unavailable. Watch playback works independently."
    private var pending = false
    private var syncingLibrary = false
    private var seenRemoteCommands: [String: [String: Any]] = [:]

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let available = activationState == .activated && session.isReachable
        Task { @MainActor [weak self] in
            self?.phoneAvailable = available
            if available {
                self?.refreshQuickActions()
                self?.refresh()
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let available = session.isReachable
        Task { @MainActor [weak self] in
            self?.phoneAvailable = available
            if available {
                self?.refreshQuickActions()
                self?.refresh()
            }
            if !available { self?.status = "iPhone unavailable. Watch playback works independently." }
        }
    }

    func refreshQuickActions() {
        guard WCSession.isSupported(), WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(["version": 1, "id": UUID().uuidString,
                                       "command": "quickActions"]) { @Sendable response in
            guard response["accepted"] as? Bool == true,
                  let order = response["episodeActions"] as? [String] else { return }
            Task { @MainActor in WatchRuntimeRegistry.runtime?.library.updateEpisodeActionOrder(order) }
        } errorHandler: { @Sendable _ in }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard userInfo["version"] as? Int == 1,
              userInfo["kind"] as? String == "downloadRequest",
              let data = userInfo["data"] as? Data else { return }
        Task { @MainActor [weak self] in self?.acceptDownloadRequest(data) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                            replyHandler: @escaping ([String: Any]) -> Void) {
        let version = message["version"] as? Int ?? 0
        let id = message["id"] as? String ?? ""
        let command = message["command"] as? String ?? ""
        let reply = WatchControlReplyBox(replyHandler)
        Task { @MainActor [weak self] in
            guard let self, version == 1, !id.isEmpty else {
                reply.send(["accepted": false, "reason": "Invalid watch control request"])
                return
            }
            if let prior = self.seenRemoteCommands[id] { reply.send(prior); return }
            guard let runtime = WatchRuntimeRegistry.currentOrCreate() else {
                reply.send(["accepted": false, "reason": "Watch player unavailable"])
                return
            }
            let player = runtime.player
            var accepted = true
            var reason = ""
            switch command {
            case "state": break
            case "toggle":
                if player.episode == nil { accepted = false; reason = "Choose an episode on watch first" }
                else { await player.toggle() }
            case "pause": player.pause()
            case "back":
                if !player.hasLoadedItem { accepted = false; reason = "Start an episode on watch first" }
                else { await player.skipBackward() }
            case "forward":
                if !player.hasLoadedItem { accepted = false; reason = "Start an episode on watch first" }
                else { await player.skipForward() }
            default: accepted = false; reason = "Unsupported watch control"
            }
            var result: [String: Any] = ["version": 1, "owner": "watch", "accepted": accepted,
                                         "playing": player.isPlaying, "position": player.positionSeconds,
                                         "rate": Double(player.rate),
                                         "observedAt": Date.now.timeIntervalSince1970]
            if let episode = player.episode { result["title"] = episode.title }
            if !accepted { result["reason"] = reason }
            if command != "state" {
                self.seenRemoteCommands[id] = result
                if self.seenRemoteCommands.count > 128 { self.seenRemoteCommands.removeAll() }
            }
            reply.send(result)
        }
    }

    private func acceptDownloadRequest(_ data: Data) {
        guard let request = try? JSONDecoder().decode(WatchDownloadRequest.self, from: data) else { return }
        let seen = Set(UserDefaults.standard.stringArray(forKey: "watchReceivedDownloadRequests") ?? [])
        guard !seen.contains(request.id.uuidString) else { return }
        var pending = UserDefaults.standard.array(forKey: "watchPendingDownloadRequests") as? [Data] ?? []
        pending.append(data)
        UserDefaults.standard.set(Array(pending.suffix(100)), forKey: "watchPendingDownloadRequests")
        var recent = Array(seen)
        recent.append(request.id.uuidString)
        UserDefaults.standard.set(Array(recent.suffix(200)), forKey: "watchReceivedDownloadRequests")
        if let runtime = WatchRuntimeRegistry.runtime {
            processPendingDownloads(library: runtime.library, downloads: runtime.downloads)
        }
    }

    func processPendingDownloads(library: WatchLibrary, downloads: WatchDownloadManager) {
        let pending = UserDefaults.standard.array(forKey: "watchPendingDownloadRequests") as? [Data] ?? []
        guard !pending.isEmpty else { return }
        var failed: [Data] = []
        for data in pending {
            guard let request = try? JSONDecoder().decode(WatchDownloadRequest.self, from: data),
                  let episode = library.playablePhoneEpisode(feedURL: request.feedURL, guid: request.guid,
                                                             title: request.title, podcastTitle: request.podcastTitle,
                                                             audioURL: request.audioURL) else {
                failed.append(data)
                continue
            }
            if episode.downloadFilename == nil { downloads.start(episode) }
        }
        UserDefaults.standard.set(failed, forKey: "watchPendingDownloadRequests")
        status = "Received an iPhone download request. Apple Watch is downloading directly."
        AccessibilityNotification.Announcement(status).post()
    }

    func refresh() { send("state") }
    func toggle() { send("toggle") }
    func pause() { send("pause") }
    func back() { send("back") }
    func forward() { send("forward") }

    func handoffToWatch(library: WatchLibrary, watchPlayer: WatchPlayer) {
        guard !pending, phonePlaying, Date.now.timeIntervalSince(phoneObservedAt) < 30,
              !phoneFeedURL.isEmpty, !phoneGUID.isEmpty,
              let episode = library.playablePhoneEpisode(feedURL: phoneFeedURL, guid: phoneGUID,
                                                        title: phoneEpisodeTitle,
                                                        podcastTitle: phonePodcastTitle,
                                                        audioURL: phoneAudioURL) else {
            status = "Refresh iPhone state before transferring playback"
            AccessibilityNotification.Announcement(status).post()
            return
        }
        let position = phonePosition
        let rate = phoneRate
        let expectedFeed = phoneFeedURL
        let expectedGUID = phoneGUID
        Task { @MainActor [weak self] in
            guard let self else { return }
            watchPlayer.setRate(rate)
            await watchPlayer.play(episode, at: position)
            guard watchPlayer.isPlaying else {
                self.status = "Apple Watch could not start audio. iPhone continues."
                AccessibilityNotification.Announcement(self.status).post()
                return
            }
            guard WCSession.default.isReachable else {
                watchPlayer.pause(announce: false)
                self.status = "iPhone disconnected before transfer completed."
                AccessibilityNotification.Announcement(self.status).post()
                return
            }
            self.pending = true
            self.status = "Stopping playback on iPhone"
            WCSession.default.sendMessage(["version": 1, "id": UUID().uuidString,
                                           "command": "pauseIfEpisode",
                                           "feedURL": expectedFeed, "guid": expectedGUID]) { @Sendable [weak self] response in
                let accepted = response["accepted"] as? Bool == true
                let stillPlaying = response["playing"] as? Bool == true
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.pending = false
                    if accepted, !stillPlaying {
                        self.phonePlaying = false
                        self.status = "Playback transferred to Apple Watch"
                    } else {
                        watchPlayer.pause(announce: false)
                        self.status = "iPhone did not confirm pause. Watch playback stopped."
                    }
                    AccessibilityNotification.Announcement(self.status).post()
                }
            } errorHandler: { @Sendable [weak self] _ in
                Task { @MainActor [weak self] in
                        watchPlayer.pause(announce: false)
                    self?.pending = false
                    self?.status = "iPhone did not confirm pause. Watch playback stopped."
                    AccessibilityNotification.Announcement("iPhone did not confirm pause. Watch playback stopped.").post()
                }
            }
        }
    }

    func requestPhonePlayback(_ episode: WatchEpisode, position: Double, rate: Float) {
        send("play", extra: [
            "feedURL": episode.feedURL,
            "guid": episode.guid,
            "position": position,
            "rate": Double(rate)
        ])
    }

    /// The watch keeps playing until the phone confirms that it started the
    /// requested episode. A failed prepare or commit leaves watch audio alone.
    func handoffToPhone(episode: WatchEpisode, position: Double, rate: Float, watchPlayer: WatchPlayer) {
        guard !pending else { status = "Wait for the previous iPhone request"; return }
        guard WCSession.isSupported(), WCSession.default.isReachable else {
            status = "iPhone is unreachable. Playback remains on Apple Watch."
            AccessibilityNotification.Announcement(status).post()
            return
        }
        pending = true
        status = "Checking iPhone playback"
        let feedURL = episode.feedURL
        let guid = episode.guid
        var prepare: [String: Any] = ["feedURL": feedURL, "guid": guid]
        prepare["version"] = 1
        prepare["id"] = UUID().uuidString
        prepare["command"] = "prepareHandoff"
        WCSession.default.sendMessage(prepare) { @Sendable [weak self] response in
            let accepted = response["accepted"] as? Bool == true
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard accepted else {
                    self.pending = false
                    self.status = "iPhone cannot play this episode. Playback remains on Apple Watch."
                    AccessibilityNotification.Announcement(self.status).post()
                    return
                }
                guard WCSession.default.isReachable else {
                    self.pending = false
                    self.status = "iPhone disconnected. Playback remains on Apple Watch."
                    AccessibilityNotification.Announcement(self.status).post()
                    return
                }
                var commit: [String: Any] = ["feedURL": feedURL, "guid": guid]
                commit["version"] = 1
                commit["id"] = UUID().uuidString
                commit["command"] = "play"
                commit["position"] = position
                commit["rate"] = Double(rate)
                self.status = "Starting playback on iPhone"
                WCSession.default.sendMessage(commit) { @Sendable [weak self] response in
                    let confirmed = WatchHandoffDecision.phoneConfirmed(response, feedURL: feedURL, guid: guid)
                    let title = response["title"] as? String ?? ""
                    let confirmedPosition = response["position"] as? Double ?? position
                    let confirmedFeed = response["feedURL"] as? String ?? ""
                    let confirmedGUID = response["guid"] as? String ?? ""
                    let confirmedAudio = response["audioURL"] as? String ?? ""
                    let podcastTitle = response["podcastTitle"] as? String ?? "Podcast"
                    let confirmedRate = response["rate"] as? Double ?? Double(rate)
                    let observedAt = response["observedAt"] as? Double ?? 0
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.pending = false
                        if confirmed {
                            watchPlayer.pause(announce: false)
                            self.phoneAvailable = true
                            self.phonePlaying = true
                            self.phoneEpisodeTitle = title
                            self.phonePosition = confirmedPosition
                            self.phoneFeedURL = confirmedFeed
                            self.phoneGUID = confirmedGUID
                            self.phoneAudioURL = confirmedAudio
                            self.phonePodcastTitle = podcastTitle
                            self.phoneRate = Float(confirmedRate)
                            self.phoneObservedAt = Date(timeIntervalSince1970: observedAt)
                            self.status = "Playback transferred to iPhone"
                        } else {
                            self.status = "iPhone did not confirm playback. Apple Watch continues."
                        }
                        AccessibilityNotification.Announcement(self.status).post()
                    }
                } errorHandler: { @Sendable [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        guard WCSession.default.isReachable else {
                            self.pending = false
                            self.status = "iPhone confirmation was lost. Apple Watch continues; check iPhone audio before retrying."
                            AccessibilityNotification.Announcement(self.status).post()
                            return
                        }
                        WCSession.default.sendMessage(["version": 1, "id": UUID().uuidString,
                                                       "command": "state"]) { @Sendable [weak self] state in
                            let confirmed = WatchHandoffDecision.phoneConfirmed(state, feedURL: feedURL, guid: guid)
                            Task { @MainActor [weak self] in
                                guard let self else { return }
                                self.pending = false
                                if confirmed {
                                    watchPlayer.pause(announce: false)
                                    self.status = "iPhone playback confirmed after reconnect. Watch paused."
                                } else {
                                    self.status = "iPhone playback was not confirmed. Apple Watch continues."
                                }
                                AccessibilityNotification.Announcement(self.status).post()
                            }
                        } errorHandler: { @Sendable [weak self] _ in
                            Task { @MainActor [weak self] in
                                self?.pending = false
                                self?.status = "iPhone confirmation was lost. Apple Watch continues; check iPhone audio before retrying."
                                AccessibilityNotification.Announcement("iPhone confirmation was lost. Apple Watch continues; check iPhone audio before retrying.").post()
                            }
                        }
                    }
                }
            }
        } errorHandler: { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pending = false
                self?.status = "iPhone did not respond. Apple Watch continues."
                AccessibilityNotification.Announcement("iPhone did not respond. Apple Watch continues.").post()
            }
        }
    }

    func importLibrary(into library: WatchLibrary, offset: Int = 0) {
        if offset == 0 { syncingLibrary = true }
        guard WCSession.isSupported(), WCSession.default.isReachable else {
            syncingLibrary = false
            status = "iPhone is unreachable. Watch library is unchanged."
            return
        }
        WCSession.default.sendMessage(["version": 1, "id": UUID().uuidString,
                                       "command": "library", "offset": offset]) { @Sendable [weak self] response in
            let accepted = response["accepted"] as? Bool ?? false
            let data = response["feeds"] as? Data ?? Data()
            let feeds = (try? JSONDecoder().decode([WatchFeedSnapshot].self, from: data)) ?? []
            let next = response["nextOffset"] as? Int ?? 0
            let hasMore = response["hasMore"] as? Bool ?? false
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard accepted else {
                    self.syncingLibrary = false
                    self.status = "iPhone library transfer failed"
                    return
                }
                library.importPhoneFeeds(feeds)
                if hasMore { self.importLibrary(into: library, offset: next) }
                else {
                    self.syncingLibrary = false
                    self.status = "Imported phone subscriptions. Open a podcast to fetch its episodes."
                }
            }
        } errorHandler: { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncingLibrary = false
                self?.status = "iPhone library transfer stopped. Imported subscriptions remain saved."
            }
        }
    }

    private func send(_ command: String, extra: [String: Any] = [:]) {
        guard !pending else { status = "Wait for the previous iPhone request"; return }
        guard WCSession.isSupported(), WCSession.default.isReachable else {
            phoneAvailable = false
            status = "iPhone is unreachable. No control was sent."
            return
        }
        pending = true
        status = "Contacting iPhone"
        var message = extra
        message["version"] = 1
        message["id"] = UUID().uuidString
        message["command"] = command
        WCSession.default.sendMessage(message) { @Sendable [weak self] response in
            let accepted = response["accepted"] as? Bool ?? false
            let playing = response["playing"] as? Bool ?? false
            let title = response["title"] as? String ?? ""
            let position = response["position"] as? Double ?? 0
            let reason = response["reason"] as? String ?? ""
            let feedURL = response["feedURL"] as? String ?? ""
            let guid = response["guid"] as? String ?? ""
            let audioURL = response["audioURL"] as? String ?? ""
            let podcastTitle = response["podcastTitle"] as? String ?? "Podcast"
            let rate = response["rate"] as? Double ?? 1
            let observedAt = response["observedAt"] as? Double ?? 0
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pending = false
                self.phoneAvailable = true
                self.phonePlaying = playing
                self.phoneEpisodeTitle = title
                self.phonePosition = position
                self.phoneFeedURL = feedURL
                self.phoneGUID = guid
                self.phoneAudioURL = audioURL
                self.phonePodcastTitle = podcastTitle
                self.phoneRate = Float(rate)
                self.phoneObservedAt = Date(timeIntervalSince1970: observedAt)
                self.status = accepted ? (playing ? "iPhone reports playback active" : "iPhone reports playback paused") : "iPhone request failed: \(reason)"
                AccessibilityNotification.Announcement(self.status).post()
            }
        } errorHandler: { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pending = false
                self?.phoneAvailable = false
                self?.status = "iPhone did not confirm the request. Watch playback is unchanged."
                AccessibilityNotification.Announcement("iPhone did not confirm the request. Watch playback is unchanged.").post()
            }
        }
    }
}

private final class WatchControlReplyBox: @unchecked Sendable {
    private let callback: ([String: Any]) -> Void
    init(_ callback: @escaping ([String: Any]) -> Void) { self.callback = callback }
    func send(_ value: [String: Any]) { callback(value) }
}

struct WatchPhoneControlView: View {
    let runtime: WatchRuntime

    var body: some View {
        List {
            Section("iPhone playback") {
                Text(runtime.phone.status)
                if !runtime.phone.phoneEpisodeTitle.isEmpty {
                    Text(runtime.phone.phoneEpisodeTitle)
                    Text("Position \(Int(runtime.phone.phonePosition / 60)) minutes")
                }
                Button("Refresh iPhone state") { runtime.phone.refresh() }
                Button(runtime.phone.phonePlaying ? "Pause on iPhone" : "Play or pause on iPhone") { runtime.phone.toggle() }
                Button("Back on iPhone") { runtime.phone.back() }
                Button("Forward on iPhone") { runtime.phone.forward() }
                Button("Transfer to Apple Watch") {
                    runtime.phone.handoffToWatch(library: runtime.library, watchPlayer: runtime.player)
                }
                .disabled(!runtime.phone.phonePlaying)
            }
            Section("Library") {
                Button("Import subscriptions from iPhone") { runtime.phone.importLibrary(into: runtime.library) }
            }
        }
        .navigationTitle("iPhone Control")
        .task { runtime.phone.refresh() }
    }
}
