import SwiftUI

/// Settings → Playback: speed, skip intervals, audio processing, chapter navigation
/// buttons, auto-advance, and queue grouping. Extracted from the former single
/// Settings form so each category has its own dedicated screen. Native controls
/// (`Toggle`, `AdjustableOptionPicker`) stay VoiceOver- and Dynamic-Type-friendly.
struct PlaybackSettingsView: View {
    @Environment(SettingsStore.self) private var settings

    private static let skipIntervals = [10, 15, 30, 45, 60]

    // Ordered ascending so a VoiceOver flick up means "more" (faster / longer).
    private var speedAdjustableOptions: [AdjustableOptionPicker<Double>.Option] {
        PlaybackLogic.speedMenuValues.map {
            .init(value: $0, title: String(format: "%g×", $0), spoken: PlaybackLogic.spokenRate($0))
        }
    }

    private var skipAdjustableOptions: [AdjustableOptionPicker<Int>.Option] {
        Self.skipIntervals.map { .init(value: $0, title: "\($0)s", spoken: "\($0) seconds") }
    }

    private var volumeBoostOptions: [AdjustableOptionPicker<VolumeBoostLevel>.Option] {
        VolumeBoostLevel.allCases.map {
            .init(value: $0, title: $0.title, spoken: $0.spokenValue)
        }
    }

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                // VoiceOver: flick up/down to change. The visual menu still opens
                // on tap for sighted/low-vision users. Off-grid stored speeds
                // (set via the in-player precise stepper) display as the nearest
                // curated value and only snap to grid when actually adjusted.
                AdjustableOptionPicker(
                    "Playback speed",
                    options: speedAdjustableOptions,
                    selection: Binding(
                        get: { PlaybackLogic.nearestMenuSpeed(settings.globalSpeed) },
                        set: { settings.globalSpeed = $0 }
                    ),
                    hint: "Flick up for faster, down for slower"
                )
                AdjustableOptionPicker(
                    "Skip forward",
                    options: skipAdjustableOptions,
                    selection: $settings.skipForwardSeconds,
                    hint: "Flick up for a longer skip, down for shorter"
                )
                AdjustableOptionPicker(
                    "Skip back",
                    options: skipAdjustableOptions,
                    selection: $settings.skipBackSeconds,
                    hint: "Flick up for a longer skip, down for shorter"
                )
                AdjustableOptionPicker(
                    "Volume boost",
                    options: volumeBoostOptions,
                    selection: $settings.volumeBoost,
                    hint: "Flick up for more boost, down for less or off"
                )
                Toggle("Trim silence", isOn: $settings.skipSilenceEnabled)

                // The footer below explains this toggle; a matching hint would make
                // VoiceOver read the same sentence twice (#515).
                Toggle("Chapter navigation buttons", isOn: $settings.chapterNavButtonsVisible)
            } footer: {
                // No section header: the "Playback" navigation title already names
                // the screen, so a matching header would be a redundant VoiceOver
                // heading stop. The distinct Auto-advance and Queue sections keep
                // their headers.
                Text("Shows Previous and Next chapter buttons beside the chapter name in the player. Turn off to navigate chapters with the VoiceOver rotor on the artwork.")
            }

            Section {
                // Tightest-to-widest reading order: "after episode" nests inside
                // "after group", so episode comes first and focus order matches
                // the boundary nesting.
                Toggle("Continue after episode ends", isOn: $settings.continueAfterEpisode)
                Toggle("Continue after group ends", isOn: $settings.continueAfterGroupEnds)
            } header: {
                Text("Auto-advance")
            } footer: {
                // One footer explains the nesting for both toggles. Per-toggle
                // accessibilityHints would make VoiceOver read the same sentence
                // twice (matches the Inbox/Privacy sections' approach).
                Text("When both are on, playback moves to the next episode automatically. Turn off \"after episode ends\" to stop after each episode, or \"after group ends\" to stop when a podcast's episodes run out.")
            }

            Section {
                Toggle("Wrap Queue to remaining episodes", isOn: $settings.wrapQueue)
            } footer: {
                Text("After the last queued episode finishes, continue from the first remaining unplayed episode. Completed episodes are not added back. Auto-advance settings, sleep timers, and Stop after this episode still apply. Previous and Next in Queue do not wrap.")
            }

            Section {
                Toggle("Open the player when you play an episode", isOn: $settings.openPlayerOnPlay)
            } footer: {
                Text("When on, playing an episode opens the full player screen. When off, it plays in the background — tap the mini player to open it.")
            }

            Section {
                Toggle(
                    "Dismiss the player when playback ends",
                    isOn: $settings.dismissPlayerWhenPlaybackEnds
                )
            } footer: {
                Text("Closes the full player after an episode finishes and playback stops. The player stays open when the next queued episode starts.")
            }

            Section("Queue") {
                Picker("Group queue", selection: $settings.queueGrouping) {
                    ForEach(QueueGrouping.allCases) { mode in
                        Text(mode.optionLabel).tag(mode)
                    }
                }
            }
        }
        .navigationTitle("Playback")
    }
}
