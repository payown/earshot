import SwiftUI

struct PhoneWatchControlView: View {
    private let control = PhoneWatchConnectivity.shared

    var body: some View {
        List {
            Section("Apple Watch playback") {
                Text(control.watchStatus)
                if control.hasWatchEpisode {
                    Text(control.watchEpisodeTitle).font(.headline).accessibilityAddTraits(.isHeader)
                    Text(control.watchPodcastTitle)
                    Text(control.watchSessionIsLive
                         ? (control.watchPlaying ? "Playing on Apple Watch" : "Paused on Apple Watch")
                         : "Last known Apple Watch session")
                    Text("Position \(Int(control.watchPosition / 60)) minutes, \(Int(control.watchPosition) % 60) seconds")
                        .accessibilityLabel("Apple Watch playback position")
                        .accessibilityValue("\(Int(control.watchPosition / 60)) minutes, \(Int(control.watchPosition) % 60) seconds")
                }
                Button("Refresh Apple Watch state") { perform("state") }
                Button(control.watchPlaying ? "Pause on Apple Watch" : "Play on Apple Watch") {
                    perform("toggle")
                }
                .disabled(!control.watchSessionIsLive || !control.hasWatchEpisode)
                Button("Skip back on Apple Watch") { perform("back") }
                    .disabled(!control.watchSessionIsLive || !control.hasWatchEpisode)
                Button("Skip forward on Apple Watch") { perform("forward") }
                    .disabled(!control.watchSessionIsLive || !control.hasWatchEpisode)
                Button("Transfer to iPhone") { control.handoffFromWatch() }
                    .disabled(!control.watchSessionIsLive || !control.watchPlaying)
                    .accessibilityHint("Starts the same episode on iPhone, then asks Apple Watch to stop")
            }
            Section("Queue synchronization") {
                Text(control.watchQueueSyncStatus)
                    .accessibilityLabel("Watch Queue synchronization")
                    .accessibilityValue(control.watchQueueSyncStatus)
                Button("Refresh Watch Queue") { control.refreshQueue(announce: true) }
            }
        }
        .navigationTitle("Apple Watch Playback")
        .task {
            control.sendWatchControl("state", announce: false)
            control.refreshQueue()
        }
    }

    private func perform(_ command: String) {
        control.sendWatchControl(command)
    }
}
