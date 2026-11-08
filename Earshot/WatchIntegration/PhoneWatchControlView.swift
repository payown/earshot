import SwiftUI

struct PhoneWatchControlView: View {
    private let control = PhoneWatchConnectivity.shared

    static func playbackCommand(isPlaying: Bool) -> String { isPlaying ? "pause" : "toggle" }

    var body: some View {
        List {
            Section("Apple Watch playback") {
                Text(control.watchStatus)
                if !control.watchEpisodeTitle.isEmpty {
                    Text(control.watchEpisodeTitle)
                    Text("Position \(Int(control.watchPosition / 60)) minutes")
                }
                Button("Refresh Apple Watch state") { perform("state") }
                Button(control.watchPlaying ? "Pause on Apple Watch" : "Play or pause on Apple Watch") {
                    perform(Self.playbackCommand(isPlaying: control.watchPlaying))
                }
                Button("Back on Apple Watch") { perform("back") }
                Button("Forward on Apple Watch") { perform("forward") }
            }
        }
        .navigationTitle("Apple Watch Playback")
        .task { control.sendWatchControl("state") }
    }

    private func perform(_ command: String) {
        control.sendWatchControl(command)
    }
}
