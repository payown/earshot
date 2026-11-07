import SwiftUI

struct WatchNowPlayingView: View {
    let runtime: WatchRuntime
    var body: some View {
        List {
            if runtime.phone.phoneSessionIsLive && runtime.phone.hasPhoneEpisode && !runtime.player.isPlaying {
                WatchPhoneSessionSection(runtime: runtime)
            } else if let episode = runtime.player.episode {
                Section("Playing on Apple Watch") {
                    Text(episode.title).font(.headline)
                    Text(episode.podcastTitle)
                    Text(runtime.player.status)
                    if runtime.player.isBuffering { Text("Buffering") }
                }
                Section("Playback") {
                    Button(runtime.player.isPlaying ? "Pause" : "Play") { Task { await runtime.player.toggle() } }
                    Button("Back \(runtime.library.skipBackward) seconds") { Task { await runtime.player.skipBackward() } }
                    Button("Forward \(runtime.library.skipForward) seconds") { Task { await runtime.player.skipForward() } }
                    Button("Restart episode") { Task { await runtime.player.seek(to: 0) } }
                    WatchSeekControl(player: runtime.player)
                    Text("Elapsed \(Int(runtime.player.positionSeconds / 60)) minutes. Remaining \(Int(max(0, runtime.player.durationSeconds - runtime.player.positionSeconds) / 60)) minutes")
                }
                Section("Speed") {
                    ForEach([0.75, 1, 1.25, 1.5, 2], id: \.self) { speed in
                        Button("\(speed.formatted()) times") { runtime.player.setRate(Float(speed)) }
                            .accessibilityAddTraits(runtime.player.rate == Float(speed) ? .isSelected : [])
                    }
                }
                if !runtime.player.chapters.isEmpty {
                    Section("Chapters") {
                        if let index = runtime.player.currentChapterIndex {
                            Text("Current chapter: \(runtime.player.chapters[index].title)")
                        }
                        Button("Previous chapter") { Task { await runtime.player.previousChapter() } }
                        Button("Next chapter") { Task { await runtime.player.nextChapter() } }
                        ForEach(runtime.player.chapters) { chapter in
                            Button("\(chapter.title), \(Int(chapter.startTime / 60)) minutes") {
                                Task { await runtime.player.seek(to: chapter.startTime) }
                            }
                            .accessibilityAddTraits(runtime.player.currentChapterIndex
                                .map { runtime.player.chapters[$0].startTime == chapter.startTime } == true
                                ? .isSelected : [])
                        }
                    }
                }
                Section("Sleep timer") {
                    Text(runtime.player.sleepDescription)
                    Button("Off") { runtime.player.setSleepTimer(minutes: nil) }
                    Button("15 minutes") { runtime.player.setSleepTimer(minutes: 15) }
                    Button("30 minutes") { runtime.player.setSleepTimer(minutes: 30) }
                }
                Section("Playback device") {
                    Text(runtime.player.isPlaying ? "Audio is playing on Apple Watch" : "Playback is paused on Apple Watch")
                    Text("Audio route: \(runtime.player.routeDescription)")
                    Button("Transfer to iPhone") {
                        runtime.phone.handoffToPhone(episode: episode,
                                                    position: runtime.player.positionSeconds,
                                                    rate: runtime.player.rate,
                                                    watchPlayer: runtime.player)
                    }
                    .disabled(!runtime.player.isPlaying)
                    Text(runtime.phone.status)
                }
            } else if runtime.phone.hasPhoneEpisode {
                WatchPhoneSessionSection(runtime: runtime)
            } else { Text("Nothing playing. Choose an episode from Library or Inbox.") }
        }
        .navigationTitle("Now Playing")
    }
}

struct WatchSeekControl: View {
    let player: WatchPlayer
    var body: some View {
        Slider(value: Binding(
            get: { min(player.positionSeconds, max(1, player.durationSeconds)) },
            set: { seconds in Task { await player.seek(to: seconds) } }
        ), in: 0...max(1, player.durationSeconds), step: player.durationSeconds < 30 ? 1 : 30) {
            Text("Playback position")
        }
            .disabled(player.durationSeconds <= 0)
            .accessibilityLabel("Playback position")
            .accessibilityValue("\(Int(player.positionSeconds / 60)) minutes, \(Int(player.positionSeconds) % 60) seconds")
            .accessibilityHint(player.durationSeconds < 30
                               ? "Swipe up or down to seek by one second"
                               : "Swipe up or down to seek by 30 seconds")
    }
}
