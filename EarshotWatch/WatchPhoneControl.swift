import Foundation
import Observation
import SwiftUI
import WatchConnectivity
import Accessibility

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
    private(set) var status = "iPhone unavailable. Watch playback works independently."
    private var pending = false
    private var syncingLibrary = false

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let available = activationState == .activated && session.isReachable
        Task { @MainActor [weak self] in self?.phoneAvailable = available }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let available = session.isReachable
        Task { @MainActor [weak self] in
            self?.phoneAvailable = available
            if !available { self?.status = "iPhone unavailable. Watch playback works independently." }
        }
    }

    func refresh() { send("state") }
    func toggle() { send("toggle") }
    func pause() { send("pause") }
    func back() { send("back") }
    func forward() { send("forward") }

    func handoffToWatch(library: WatchLibrary, watchPlayer: WatchPlayer) {
        guard !pending, phonePlaying, !phoneFeedURL.isEmpty, !phoneGUID.isEmpty,
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
                watchPlayer.pause()
                self.status = "iPhone disconnected before transfer completed."
                AccessibilityNotification.Announcement(self.status).post()
                return
            }
            self.pending = true
            self.status = "Stopping playback on iPhone"
            WCSession.default.sendMessage(["version": 1, "id": UUID().uuidString,
                                           "command": "pause"]) { [weak self] response in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.pending = false
                    if response["accepted"] as? Bool == true, response["playing"] as? Bool == false {
                        self.phonePlaying = false
                        self.status = "Playback transferred to Apple Watch"
                    } else {
                        watchPlayer.pause()
                        self.status = "iPhone did not confirm pause. Watch playback stopped."
                    }
                    AccessibilityNotification.Announcement(self.status).post()
                }
            } errorHandler: { [weak self] _ in
                Task { @MainActor [weak self] in
                    watchPlayer.pause()
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
        let identity: [String: Any] = ["feedURL": episode.feedURL, "guid": episode.guid]
        var prepare = identity
        prepare["version"] = 1
        prepare["id"] = UUID().uuidString
        prepare["command"] = "prepareHandoff"
        WCSession.default.sendMessage(prepare) { [weak self] response in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard response["accepted"] as? Bool == true else {
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
                var commit = identity
                commit["version"] = 1
                commit["id"] = UUID().uuidString
                commit["command"] = "play"
                commit["position"] = position
                commit["rate"] = Double(rate)
                self.status = "Starting playback on iPhone"
                WCSession.default.sendMessage(commit) { [weak self] response in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.pending = false
                        if response["accepted"] as? Bool == true,
                           response["playing"] as? Bool == true,
                           response["feedURL"] as? String == identity["feedURL"] as? String,
                           response["guid"] as? String == identity["guid"] as? String {
                            watchPlayer.pause()
                            self.phoneAvailable = true
                            self.phonePlaying = true
                            self.phoneEpisodeTitle = response["title"] as? String ?? ""
                            self.status = "Playback transferred to iPhone"
                        } else {
                            self.status = "iPhone did not confirm playback. Apple Watch continues."
                        }
                        AccessibilityNotification.Announcement(self.status).post()
                    }
                } errorHandler: { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.pending = false
                        self?.status = "iPhone did not confirm playback. Apple Watch continues."
                        AccessibilityNotification.Announcement("iPhone did not confirm playback. Apple Watch continues.").post()
                    }
                }
            }
        } errorHandler: { [weak self] _ in
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
                                       "command": "library", "offset": offset]) { [weak self] response in
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
        } errorHandler: { [weak self] _ in
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
        WCSession.default.sendMessage(message) { [weak self] response in
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
                self.status = accepted ? (playing ? "iPhone reports playback active" : "iPhone reports playback paused") : "iPhone request failed: \(reason)"
                AccessibilityNotification.Announcement(self.status).post()
            }
        } errorHandler: { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pending = false
                self?.phoneAvailable = false
                self?.status = "iPhone did not confirm the request. Watch playback is unchanged."
                AccessibilityNotification.Announcement("iPhone did not confirm the request. Watch playback is unchanged.").post()
            }
        }
    }
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
