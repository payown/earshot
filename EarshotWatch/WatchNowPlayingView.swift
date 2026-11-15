import SwiftUI

enum WatchPlaybackDeviceStatus {
    static func spokenText(watchPlaying: Bool, phonePlaying: Bool, phoneIsLive: Bool = true,
                           selectedDevice: WatchPlaybackDevice = .watch) -> String {
        if selectedDevice == .phone {
            guard phoneIsLive else { return "Last reported iPhone playback. Current state unavailable." }
            return phonePlaying ? "Audio is playing on iPhone" : "Audio is paused on iPhone"
        }
        return watchPlaying ? "Audio is playing on Apple Watch" : "Audio is paused on Apple Watch"
    }
}

struct WatchNowPlayingView: View {
    let runtime: WatchRuntime
    @State private var selectedDevice: WatchPlaybackDevice
    @State private var manuallySelectedDevice = false

    init(runtime: WatchRuntime, initialDevice: WatchPlaybackDevice? = nil) {
        self.runtime = runtime
        let initial = initialDevice ?? runtime.defaultPlaybackScreen
        _selectedDevice = State(initialValue: initial)
    }

    var body: some View {
        List {
            Section("Playback device") {
                Button("Apple Watch controls") {
                    selectedDevice = .watch
                    manuallySelectedDevice = true
                }
                    .accessibilityAddTraits(selectedDevice == .watch ? .isSelected : [])
                Button("iPhone controls") {
                    selectedDevice = .phone
                    manuallySelectedDevice = true
                }
                    .accessibilityAddTraits(selectedDevice == .phone ? .isSelected : [])
                if selectedDevice == .watch, runtime.player.episode != nil {
                    Text(WatchPlaybackDeviceStatus.spokenText(watchPlaying: runtime.player.isPlaying,
                                                               phonePlaying: runtime.phone.phonePlaying))
                } else if selectedDevice == .phone {
                    if runtime.phone.hasPhoneEpisode {
                        Text(WatchPlaybackDeviceStatus.spokenText(watchPlaying: runtime.player.isPlaying,
                                                                   phonePlaying: runtime.phone.phonePlaying,
                                                                   phoneIsLive: runtime.phone.phoneSessionIsLive,
                                                                   selectedDevice: .phone))
                    } else { Text("No iPhone episode available") }
                }
            }
            if selectedDevice == .phone {
                WatchPhoneSessionSection(runtime: runtime)
            } else if let episode = runtime.player.episode {
                Section("Apple Watch playback") {
                    Text(episode.title).font(.headline)
                    Text(episode.podcastTitle)
                    Text(runtime.player.status)
                    if runtime.player.isBuffering { Text("Buffering") }
                }
                Section("Apple Watch controls") {
                    Button(runtime.player.isPlaying ? "Pause on Apple Watch" : "Play on Apple Watch") {
                        Task { await runtime.toggleWatch() }
                    }
                    .disabled(runtime.watchResumeNeedsTransfer)
                    .accessibilityHint(runtime.watchResumeNeedsTransfer
                        ? "Use Transfer to Apple Watch while iPhone is playing"
                        : "Controls playback on Apple Watch")
                    Button("Back \(runtime.library.skipBackward) seconds on Apple Watch") { Task { await runtime.player.skipBackward() } }
                    Button("Forward \(runtime.library.skipForward) seconds on Apple Watch") { Task { await runtime.player.skipForward() } }
                    Button("Restart episode on Apple Watch") { Task { await runtime.player.seek(to: 0) } }
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
                Section("Audio destination") {
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
            } else {
                Text("Nothing playing. Choose an episode from Library or Inbox.")
            }
        }
        .watchMagicTap(runtime, phoneControlScreen: selectedDevice == .phone &&
                       runtime.phone.phoneSessionIsLive && runtime.phone.phonePlaying,
                       watchControlScreen: selectedDevice == .watch)
        .navigationTitle("Now Playing")
        .onChange(of: runtime.playbackDevice) { _, newDevice in
            // An acknowledged handoff changes the active device; a routine
            // phone state refresh does not change the user's browsing choice.
            selectedDevice = newDevice
            manuallySelectedDevice = false
        }
        .onChange(of: runtime.phone.savedContinuation?.checkpointAt) { _, _ in
            if !manuallySelectedDevice { selectedDevice = runtime.defaultPlaybackScreen }
        }
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
