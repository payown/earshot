import Foundation
import Observation
import SwiftUI
import WatchConnectivity

@MainActor
@Observable
final class WatchPhoneControl: NSObject, WCSessionDelegate {
    private(set) var phoneAvailable = false
    private(set) var phonePlaying = false
    private(set) var phoneEpisodeTitle = ""
    private(set) var phonePosition: Double = 0
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

    func requestPhonePlayback(_ episode: WatchEpisode, position: Double, rate: Float) {
        send("play", extra: [
            "feedURL": episode.feedURL,
            "guid": episode.guid,
            "position": position,
            "rate": Double(rate)
        ])
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
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pending = false
                self.phoneAvailable = true
                self.phonePlaying = playing
                self.phoneEpisodeTitle = title
                self.phonePosition = position
                self.status = accepted ? (playing ? "iPhone reports playback active" : "iPhone reports playback paused") : "iPhone request failed: \(reason)"
            }
        } errorHandler: { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pending = false
                self?.phoneAvailable = false
                self?.status = "iPhone did not confirm the request. Watch playback is unchanged."
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
            }
            Section("Library") {
                Button("Import subscriptions from iPhone") { runtime.phone.importLibrary(into: runtime.library) }
            }
        }
        .navigationTitle("iPhone Control")
        .task { runtime.phone.refresh() }
    }
}
