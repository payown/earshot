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
    private(set) var queueSyncStatus = "Queue is saved on this watch. Paired synchronization has not been checked."
    private var queueRefreshing = false
    private var queueRefreshRequested = false
    private var announceQueueRefresh = false
    private var queueGeneration = UUID()
    private var queueWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var pending = false
    private var syncingLibrary = false
    private var seenRemoteCommands: [String: [String: Any]] = [:]
    private weak var watchPlayer: WatchPlayer?
    private var lastPublished: PairedPlaybackState?
    private var lastPhoneState: PairedPlaybackState?
    var hasPhoneEpisode: Bool { lastPhoneState?.hasEpisode == true }
    var phoneSessionIsLive: Bool {
        WCSession.isSupported() && WCSession.default.activationState == .activated &&
        WCSession.default.isReachable && phoneAvailable && lastPhoneState?.isCurrent() == true
    }

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        if let state = PairedPlaybackState.decode(session.receivedApplicationContext[PairedPlaybackState.contextKey]) {
            acceptPhoneState(state)
        }
    }

    func observePlayer(_ player: WatchPlayer) {
        watchPlayer = player
        observeWatchPlayer()
    }

    private func observeWatchPlayer() {
        guard let player = watchPlayer else { return }
        withObservationTracking {
            _ = player.episode
            _ = player.isPlaying
            _ = player.positionSeconds
            _ = player.rate
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeWatchPlayer()
                self?.publishWatchState()
            }
        }
    }

    private func currentWatchState() -> PairedPlaybackState {
        guard let player = watchPlayer, let episode = player.episode else {
            return PairedPlaybackState(owner: .watch)
        }
        return PairedPlaybackState(owner: .watch, feedURL: episode.feedURL, guid: episode.guid,
                                   title: episode.title, podcastTitle: episode.podcastTitle,
                                   audioURL: episode.audioURL, position: player.positionSeconds,
                                   rate: Double(player.rate), playing: player.isPlaying)
    }

    private func publishWatchState(force: Bool = false) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isCompanionAppInstalled else { return }
        let state = currentWatchState()
        guard force || state.needsPublication(after: lastPublished), let data = state.encoded() else { return }
        do {
            try session.updateApplicationContext([PairedPlaybackState.contextKey: data])
            lastPublished = state
        } catch {
            AppLog.player.info("Phone playback context deferred: \(error.localizedDescription, privacy: .public)")
        }
        if session.isReachable {
            session.sendMessage(["version": PairedPlaybackState.schemaVersion,
                                 "kind": "playbackState", PairedPlaybackState.contextKey: data],
                                replyHandler: nil, errorHandler: nil)
        }
    }

    func publishLifecycleState() { publishWatchState(force: true) }

    private func acceptPhoneState(_ state: PairedPlaybackState) {
        guard state.owner == .phone, state.supersedes(lastPhoneState) else { return }
        lastPhoneState = state
        phonePlaying = state.playing
        phoneEpisodeTitle = state.title
        phonePosition = state.position
        phoneFeedURL = state.feedURL
        phoneGUID = state.guid
        phoneAudioURL = state.audioURL
        phonePodcastTitle = state.podcastTitle
        phoneRate = Float(state.rate)
        phoneObservedAt = Date(timeIntervalSince1970: state.observedAt)
        status = state.hasEpisode
            ? (phoneAvailable && state.isCurrent()
                ? (state.playing ? "iPhone is playing" : "iPhone is paused")
                : "Last reported iPhone playback. Refresh before controlling it.")
            : "No current iPhone episode. Watch playback works independently."
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let available = activationState == .activated && session.isReachable
        Task { @MainActor [weak self] in
            self?.phoneAvailable = available
            if available {
                self?.refreshQuickActions()
                self?.refresh()
                self?.refreshQueue()
                self?.publishWatchState(force: true)
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
                self?.refreshQueue()
                self?.publishWatchState(force: true)
            }
            if !available { self?.status = "iPhone unavailable. Watch playback works independently." }
            if !available { self?.queueSyncStatus = "iPhone unavailable. Local Queue remains available." }
        }
    }

    nonisolated func sessionCompanionAppInstalledDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in self?.publishWatchState(force: true) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let state = PairedPlaybackState.decode(applicationContext[PairedPlaybackState.contextKey]) else { return }
        Task { @MainActor [weak self] in self?.acceptPhoneState(state) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        if message["kind"] as? String == "queueChanged", message["version"] as? Int == PairedQueuePage.version {
            Task { @MainActor [weak self] in self?.refreshQueue() }
            return
        }
        guard message["kind"] as? String == "playbackState",
              let state = PairedPlaybackState.decode(message[PairedPlaybackState.contextKey]) else { return }
        Task { @MainActor [weak self] in self?.acceptPhoneState(state) }
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

    func publishQueueChanged() {
        guard WCSession.isSupported(), WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(["version": PairedQueuePage.version, "kind": "queueChanged"],
                                      replyHandler: nil, errorHandler: nil)
    }

    func refreshQueue(announce: Bool = false) {
        announceQueueRefresh = announceQueueRefresh || announce
        guard WCSession.isSupported(), WCSession.default.isReachable else {
            queueGeneration = UUID()
            finishQueueRefresh("iPhone unavailable. Local Queue remains available.")
            return
        }
        guard WatchRuntimeRegistry.runtime?.cloud != nil else {
            finishQueueRefresh("Queue synchronization is unavailable. Local Queue remains available.")
            return
        }
        if queueRefreshing { queueRefreshRequested = true; return }
        queueRefreshing = true
        queueGeneration = UUID()
        let generation = queueGeneration
        requestQueuePage(offset: 0, total: nil, collected: [], generation: generation)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, self.queueGeneration == generation, self.queueRefreshing else { return }
            self.finishQueueRefresh("iPhone Queue request timed out. Local Queue remains available.")
        }
    }

    private func finishQueueRefresh(_ status: String, success: Bool = false) {
        queueSyncStatus = status
        if announceQueueRefresh { AccessibilityNotification.Announcement(status).post() }
        announceQueueRefresh = false
        queueRefreshing = false
        queueGeneration = UUID()
        let waiters = Array(queueWaiters.values)
        queueWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: success) }
        if queueRefreshRequested {
            queueRefreshRequested = false
            refreshQueue()
        }
    }

    func refreshQueueForHandoff() async -> Bool {
        guard WCSession.isSupported(), WCSession.default.isReachable else { return false }
        let waiterID = UUID()
        return await withCheckedContinuation { continuation in
            queueWaiters[waiterID] = continuation
            refreshQueue()
        }
    }

    private func requestQueuePage(offset: Int, total: Int?, collected: [PairedQueueContribution], generation: UUID) {
        WCSession.default.sendMessage(["version": PairedQueuePage.version, "id": UUID().uuidString,
                                       "command": "queueSnapshot", "offset": offset]) {
            @Sendable [weak self] response in
            let page = (response["data"] as? Data).flatMap { try? JSONDecoder().decode(PairedQueuePage.self, from: $0) }
            let accepted = response["accepted"] as? Bool == true
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.queueGeneration == generation else { return }
                guard accepted, let page, page.isValid, page.offset == offset,
                      page.total >= offset + page.rows.count,
                      total == nil || page.total == total,
                      page.nextOffset == nil || !page.rows.isEmpty else {
                    self.finishQueueRefresh("iPhone Queue could not be verified. Local Queue is unchanged.")
                    return
                }
                let rows = collected + page.rows
                if let next = page.nextOffset {
                    self.requestQueuePage(offset: next, total: page.total, collected: rows, generation: generation)
                } else {
                    do {
                        guard let cloud = WatchRuntimeRegistry.runtime?.cloud else {
                            self.finishQueueRefresh("Queue projection unavailable. Local Queue remains available.")
                            return
                        }
                        try cloud.acceptQueueContributions(rows)
                        self.finishQueueRefresh("Queue updated from iPhone", success: true)
                    } catch {
                        self.finishQueueRefresh("Queue synchronization failed. Local Queue is unchanged.")
                    }
                }
            }
        } errorHandler: { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                guard self?.queueGeneration == generation else { return }
                self?.finishQueueRefresh("iPhone Queue is unavailable. Local Queue remains available.")
            }
        }
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
        let requestedFeed = message["feedURL"] as? String
        let requestedGUID = message["guid"] as? String
        let queueOffset = message["offset"] as? Int
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
            if command == "queueSnapshot" {
                guard let cloud = runtime.cloud,
                      let offset = queueOffset, offset >= 0, offset <= 10_000 else {
                    reply.send(["accepted": false, "reason": "Watch queue projection unavailable"])
                    return
                }
                do {
                    let page = PairedQueuePage(rows: try cloud.queueContributions(), offset: offset)
                    reply.send(["accepted": true, "data": try JSONEncoder().encode(page)])
                } catch {
                    reply.send(["accepted": false, "reason": "Watch queue could not be read"])
                }
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
            case "pauseIfEpisode":
                if let feed = requestedFeed, let guid = requestedGUID,
                   let episode = player.episode, episode.guid == guid,
                   FeedURLIdentity.matches(episode.feedURL, feed) {
                    player.pause(announce: false)
                } else {
                    accepted = false
                    reason = "Watch playback changed before handoff"
                }
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
            if let episode = player.episode {
                result["title"] = episode.title
                result["feedURL"] = episode.feedURL
                result["guid"] = episode.guid
                result["audioURL"] = episode.audioURL
                result["podcastTitle"] = episode.podcastTitle
            }
            if !accepted { result["reason"] = reason }
            if command != "state" {
                self.seenRemoteCommands[id] = result
                if self.seenRemoteCommands.count > 128 { self.seenRemoteCommands.removeAll() }
                self.publishWatchState(force: true)
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

    func refresh(announce: Bool = false) { send("state", announce: announce) }
    func toggle() { send("toggle") }
    func pause() { send("pause") }
    func back() { send("back") }
    func forward() { send("forward") }

    func handoffToWatch(library: WatchLibrary, watchPlayer: WatchPlayer) {
        guard !pending, WCSession.isSupported(), WCSession.default.isReachable else {
            status = "iPhone is unreachable. No transfer was started."
            AccessibilityNotification.Announcement(status).post()
            return
        }
        pending = true
        status = "Synchronizing Queue before transfer"
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard await self.refreshQueueForHandoff(), WCSession.default.isReachable else {
                self.pending = false
                self.status = "Queue could not be synchronized. iPhone playback continues."
                AccessibilityNotification.Announcement(self.status).post()
                return
            }
            self.requestHandoffState(library: library, watchPlayer: watchPlayer)
        }
    }

    private func requestHandoffState(library: WatchLibrary, watchPlayer: WatchPlayer) {
        status = "Checking current iPhone playback"
        WCSession.default.sendMessage(["version": 1, "id": UUID().uuidString, "command": "state"]) {
            @Sendable [weak self] response in
            let valid = response["owner"] as? String == "phone" && response["accepted"] as? Bool == true
            let state = PairedPlaybackState(owner: .phone,
                                            feedURL: response["feedURL"] as? String ?? "",
                                            guid: response["guid"] as? String ?? "",
                                            title: response["title"] as? String ?? "",
                                            podcastTitle: response["podcastTitle"] as? String ?? "Podcast",
                                            audioURL: response["audioURL"] as? String ?? "",
                                            position: response["position"] as? Double ?? 0,
                                            rate: response["rate"] as? Double ?? 1,
                                            playing: response["playing"] as? Bool ?? false,
                                            observedAt: response["observedAt"] as? Double ?? 0)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.acceptPhoneState(state)
                guard valid, state.hasEpisode, state.playing, state.isCurrent(),
                      let episode = library.playablePhoneEpisode(feedURL: state.feedURL, guid: state.guid,
                                                                  title: state.title,
                                                                  podcastTitle: state.podcastTitle,
                                                                  audioURL: state.audioURL) else {
                    self.pending = false
                    self.status = "iPhone playback changed or this episode is unavailable on watch. No transfer occurred."
                    AccessibilityNotification.Announcement(self.status).post()
                    return
                }
                self.startHandoffToWatch(episode: episode, state: state, watchPlayer: watchPlayer)
            }
        } errorHandler: { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pending = false
                self?.status = "iPhone did not confirm its playback state. No transfer occurred."
                AccessibilityNotification.Announcement("iPhone did not confirm its playback state. No transfer occurred.").post()
            }
        }
    }

    private func startHandoffToWatch(episode: WatchEpisode, state: PairedPlaybackState,
                                     watchPlayer: WatchPlayer) {
        let expectedFeed = state.feedURL
        let expectedGUID = state.guid
        Task { @MainActor [weak self] in
            guard let self else { return }
            watchPlayer.setRate(Float(state.rate), announce: false, persist: false)
            await watchPlayer.play(episode, at: state.position, announce: false)
            guard watchPlayer.isPlaying else {
                self.pending = false
                self.status = "Apple Watch could not start audio. iPhone continues."
                AccessibilityNotification.Announcement(self.status).post()
                return
            }
            guard WCSession.default.isReachable else {
                watchPlayer.pause(announce: false)
                self.pending = false
                self.status = "iPhone disconnected before transfer completed."
                AccessibilityNotification.Announcement(self.status).post()
                return
            }
            self.status = "Stopping playback on iPhone"
            WCSession.default.sendMessage(["version": 1, "id": UUID().uuidString,
                                           "command": "pauseIfEpisode",
                                           "feedURL": expectedFeed, "guid": expectedGUID]) { @Sendable [weak self] response in
                let paused = PairedPlaybackHandoffDecision.sourcePaused(response, owner: .phone,
                                                                         feedURL: expectedFeed,
                                                                         guid: expectedGUID)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.pending = false
                    if paused {
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

    private func send(_ command: String, extra: [String: Any] = [:], announce: Bool = true) {
        guard !pending else { status = "Wait for the previous iPhone request"; return }
        guard WCSession.isSupported(), WCSession.default.isReachable else {
            phoneAvailable = false
            status = "iPhone is unreachable. No control was sent."
            if announce { AccessibilityNotification.Announcement(status).post() }
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
            let reason = response["reason"] as? String ?? ""
            let state = PairedPlaybackState(owner: .phone,
                                            feedURL: response["feedURL"] as? String ?? "",
                                            guid: response["guid"] as? String ?? "",
                                            title: response["title"] as? String ?? "",
                                            podcastTitle: response["podcastTitle"] as? String ?? "Podcast",
                                            audioURL: response["audioURL"] as? String ?? "",
                                            position: response["position"] as? Double ?? 0,
                                            rate: response["rate"] as? Double ?? 1,
                                            playing: response["playing"] as? Bool ?? false,
                                            observedAt: response["observedAt"] as? Double ?? 0)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pending = false
                self.phoneAvailable = true
                self.acceptPhoneState(state)
                if !accepted { self.status = "iPhone request failed: \(reason)" }
                if announce { AccessibilityNotification.Announcement(self.status).post() }
            }
        } errorHandler: { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pending = false
                self?.phoneAvailable = false
                self?.status = "iPhone did not confirm the request. Watch playback is unchanged."
                if announce {
                    AccessibilityNotification.Announcement("iPhone did not confirm the request. Watch playback is unchanged.").post()
                }
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
            WatchPhoneSessionSection(runtime: runtime)
            Section("Library") {
                Button("Import subscriptions from iPhone") { runtime.phone.importLibrary(into: runtime.library) }
            }
        }
        .navigationTitle("iPhone Control")
        .task { runtime.phone.refresh() }
    }
}

struct WatchPhoneSessionSection: View {
    let runtime: WatchRuntime

    var body: some View {
        Section("iPhone playback") {
            Text(runtime.phone.status)
            if runtime.phone.hasPhoneEpisode {
                Text(runtime.phone.phoneEpisodeTitle).font(.headline).accessibilityAddTraits(.isHeader)
                Text(runtime.phone.phonePodcastTitle)
                Text(runtime.phone.phoneSessionIsLive
                     ? (runtime.phone.phonePlaying ? "Playing on iPhone" : "Paused on iPhone")
                     : "Last known iPhone session")
                Text("Position \(Int(runtime.phone.phonePosition / 60)) minutes, \(Int(runtime.phone.phonePosition) % 60) seconds")
                    .accessibilityLabel("iPhone playback position")
                    .accessibilityValue("\(Int(runtime.phone.phonePosition / 60)) minutes, \(Int(runtime.phone.phonePosition) % 60) seconds")
            }
            Button("Refresh iPhone state") { runtime.phone.refresh(announce: true) }
            Button(runtime.phone.phonePlaying ? "Pause on iPhone" : "Play on iPhone") { runtime.phone.toggle() }
                .disabled(!runtime.phone.phoneSessionIsLive || !runtime.phone.hasPhoneEpisode)
            Button("Skip back on iPhone") { runtime.phone.back() }
                .disabled(!runtime.phone.phoneSessionIsLive || !runtime.phone.hasPhoneEpisode)
            Button("Skip forward on iPhone") { runtime.phone.forward() }
                .disabled(!runtime.phone.phoneSessionIsLive || !runtime.phone.hasPhoneEpisode)
            Button("Transfer to Apple Watch") {
                runtime.phone.handoffToWatch(library: runtime.library, watchPlayer: runtime.player)
            }
            .disabled(!runtime.phone.phoneSessionIsLive || !runtime.phone.phonePlaying)
            .accessibilityHint("Starts the same episode on this watch, then asks iPhone to stop")
        }
    }
}
