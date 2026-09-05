import SwiftUI

/// Expanded player controls: sleep timer and chapter navigation for the loaded
/// episode. Opened by tapping the Now Playing bar.
struct PlayerControlsSheet: View {
    @Environment(PlayerService.self) private var player
    @Environment(\.dismiss) private var dismiss

    // Opens the shared chapter list (#509). The controls sheet and the Now
    // Playing chapter line present the SAME ``ChapterListView`` so there is one
    // chapter UI, not two divergent ones.
    @State private var showingChapters = false

    private var sleepTimer: SleepTimerController { player.sleepTimer }

    var body: some View {
        NavigationStack {
            List {
                if let title = player.currentTitle {
                    Section {
                        Text(title)
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)
                    }
                }

                sleepTimerSection
                volumeBoostSection
                chaptersSection
            }
            .navigationTitle("Player options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showingChapters) {
                ChapterListView()
            }
        }
    }

    // MARK: Volume boost

    private var volumeBoostOptions: [AdjustableOptionPicker<VolumeBoostLevel?>.Option] {
        var options: [AdjustableOptionPicker<VolumeBoostLevel?>.Option] = [
            .init(value: nil, title: "Use Global", spoken: "use global, \(globalBoostSpokenValue)")
        ]
        options.append(contentsOf: VolumeBoostLevel.allCases.map {
            .init(value: $0, title: $0.title, spoken: $0.spokenValue)
        })
        return options
    }

    private var globalBoostSpokenValue: String {
        // When the override is nil, the effective level is the global level.
        player.effectiveVolumeBoost.spokenValue
    }

    private var volumeBoostBinding: Binding<VolumeBoostLevel?> {
        Binding(
            get: { player.currentVolumeBoostOverride },
            set: { player.setCurrentVolumeBoostOverride($0) }
        )
    }

    @ViewBuilder
    private var volumeBoostSection: some View {
        if player.nowPlayingEpisode != nil {
            Section {
                AdjustableOptionPicker(
                    "Boost for this episode",
                    options: volumeBoostOptions,
                    selection: volumeBoostBinding,
                    hint: "Flick up for more boost, down for less or use global"
                )
            } header: {
                Text("Volume boost")
            } footer: {
                Text("Use Global follows the volume boost selected in Playback Settings. Boost is limited to reduce clipping.")
            }
        }
    }

    // MARK: Sleep timer

    @ViewBuilder
    private var sleepTimerSection: some View {
        Section("Sleep timer") {
            // VoiceOver: flick up for a longer timer, down for shorter, all the
            // way down to Off (which cancels). The visual menu still opens on tap
            // for sighted/low-vision users. Setting the value here is what speaks
            // the change (the picker re-reads its value), so no extra announce.
            AdjustableOptionPicker(
                "Sleep timer",
                options: sleepTimerOptions,
                selection: sleepTimerBinding,
                hint: "Flick up for a longer timer, down for shorter or off"
            )
            if sleepTimer.isActive {
                // Visual shows the live countdown; the spoken value is coarse and
                // stable so a parked VoiceOver cursor isn't re-spoken every second.
                LabeledContent("Time left", value: sleepTimerValue)
                    .accessibilityElement()
                    .accessibilityLabel("Sleep timer remaining")
                    .accessibilityValue(sleepTimer.endOfEpisode
                        ? "End of episode"
                        : SleepTimerLogic.spokenRemaining(sleepTimer.remainingSeconds))
                if !sleepTimer.endOfEpisode {
                    Button("Extend by 5 minutes") {
                        sleepTimer.extend()
                        Announcer.announce("Extended. \(sleepTimer.announcement)")
                    }
                }
                Button("Cancel sleep timer", role: .destructive) {
                    sleepTimer.cancel()
                    Announcer.announce("Sleep timer off")
                }
            }
        }
    }

    /// Sleep-timer presets as adjustable options, ordered shortest-to-longest
    /// after Off, with end-of-episode (open-ended) last. Binding writes go
    /// straight to the controller: a real preset starts it, Off cancels.
    private var sleepTimerOptions: [AdjustableOptionPicker<SleepTimerPreset?>.Option] {
        var options: [AdjustableOptionPicker<SleepTimerPreset?>.Option] = [
            .init(value: nil, title: "Off", spoken: "off")
        ]
        let ordered: [SleepTimerPreset] = [
            .fiveMinutes, .tenMinutes, .fifteenMinutes,
            .thirtyMinutes, .fortyFiveMinutes, .sixtyMinutes, .endOfEpisode,
        ]
        for preset in ordered {
            options.append(.init(value: preset, title: preset.label, spoken: preset.label))
        }
        return options
    }

    private var sleepTimerBinding: Binding<SleepTimerPreset?> {
        Binding(
            get: { sleepTimer.isActive ? sleepTimer.preset : nil },
            set: { newValue in
                if let preset = newValue {
                    sleepTimer.set(preset)
                } else {
                    sleepTimer.cancel()
                }
            }
        )
    }

    private var sleepTimerValue: String {
        if sleepTimer.endOfEpisode { return "End of episode" }
        if let remaining = sleepTimer.remainingSeconds {
            return SleepTimerLogic.clock(remaining)
        }
        return ""
    }

    // MARK: Chapters

    /// Entry point to the shared chapter list (#509). The full list — jump,
    /// include/skip toggles, current-chapter marker — lives in
    /// ``ChapterListView``, reachable from here and from the Now Playing chapter
    /// line. `chapterCount` is an observed engine property (the engine loads
    /// chapters on episode load), so this stays in sync without re-loading here.
    @ViewBuilder
    private var chaptersSection: some View {
        Section("Chapters") {
            if player.chapterCount > 0 {
                Button {
                    showingChapters = true
                } label: {
                    LabeledContent("Chapters", value: "\(player.chapterCount)")
                        .frame(minHeight: Spacing.minTouchTarget)
                        .contentShape(Rectangle())
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Chapters")
                .accessibilityValue("\(player.chapterCount)")
                .accessibilityHint("Opens the chapter list to jump or skip chapters")
            } else {
                Text("No chapters for this episode.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
