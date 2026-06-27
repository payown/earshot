import SwiftUI

/// Expanded player controls: sleep timer and chapter navigation for the loaded
/// episode. Opened by tapping the Now Playing bar.
struct PlayerControlsSheet: View {
    @Environment(PlayerService.self) private var player
    @Environment(\.dismiss) private var dismiss

    @State private var chapters: [Chapter] = []
    @State private var loadingChapters = true
    // Local mirror of the engine's in-memory skipped-chapter set, keyed by chapter
    // index, so toggling re-renders rows immediately (the engine map isn't an
    // observed property). Seeded from the engine when chapters load.
    @State private var skipState: [Int: Bool] = [:]

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
                chaptersSection
            }
            .navigationTitle("Player")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await loadChapters() }
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

    @ViewBuilder
    private var chaptersSection: some View {
        Section("Chapters") {
            if loadingChapters {
                HStack(spacing: Spacing.sm) {
                    ProgressView()
                    Text("Loading chapters…").foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Loading chapters")
            } else if chapters.isEmpty {
                Text("No chapters for this episode.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(chapters) { chapter in
                    chapterRow(chapter)
                }
            }
        }
    }

    private func chapterRow(_ chapter: Chapter) -> some View {
        let isCurrent = activeChapterIndex == chapter.index
        let isSkipped = skipState[chapter.index] ?? player.isChapterSkipped(chapter)
        return Button {
            player.seek(to: chapter.startTime)
            Announcer.announce("Playing \(chapter.title)")
        } label: {
            HStack(spacing: Spacing.md) {
                Image(systemName: isCurrent ? "play.circle.fill" : "circle")
                    .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(chapter.title)
                        .font(.body)
                        .foregroundStyle(.primary)
                    Text(SleepTimerLogic.clock(chapter.startTime))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer(minLength: Spacing.sm)
                // Visible "skip" indicator so the state isn't color-only: a filled
                // forward-slash icon when this chapter will be auto-skipped.
                if isSkipped {
                    Image(systemName: "forward.end.alt.fill")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: Spacing.minTouchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                toggleSkip(chapter)
            } label: {
                Label(isSkipped ? "Don't skip" : "Skip", systemImage: isSkipped ? "play.circle" : "forward.end.alt")
            }
            .tint(isSkipped ? .gray : .orange)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(chapterAccessibilityLabel(chapter, isSkipped: isSkipped))
        .accessibilityHint("Jumps to this chapter")
        // The skip toggle is offered to VoiceOver as a custom action (rotor),
        // mirroring the swipe action for sighted users.
        .accessibilityAction(named: isSkipped ? "Don't skip this chapter" : "Skip this chapter") {
            toggleSkip(chapter)
        }
        // `.isSelected` is the standard list "current item" trait — VoiceOver says
        // "Selected". No empty-string value (that registers a node VO reads as a
        // pause); the trait alone carries the current-chapter state.
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
    }

    /// VoiceOver name for a chapter row, folding in the skipped state as words so
    /// it isn't conveyed by the trailing icon alone.
    private func chapterAccessibilityLabel(_ chapter: Chapter, isSkipped: Bool) -> String {
        let base = "\(chapter.title), \(BookmarkLogic.spoken(Int(chapter.startTime)))"
        return isSkipped ? "\(base), set to skip" : base
    }

    /// Flips the skipped state in the engine and mirrors it locally so the row
    /// re-renders immediately (the engine map isn't observed).
    private func toggleSkip(_ chapter: Chapter) {
        let nowSkipped = player.toggleChapterSkipped(chapter)
        skipState[chapter.index] = nowSkipped
    }

    private var activeChapterIndex: Int? {
        chapters.activeChapterIndex(at: player.currentPositionSeconds)
    }

    private func loadChapters() async {
        guard let episode = player.nowPlayingEpisode else {
            chapters = []
            loadingChapters = false
            return
        }
        loadingChapters = true
        let found = await ChapterService().chapters(
            chapterURL: episode.chapterURL,
            audioURL: episode.audioURL,
            descriptionHTML: episode.episodeDescription
        )
        chapters = found
        // Hand the list to the engine so auto-skip can evaluate the active
        // chapter on each tick, and seed the local skip mirror from any state
        // already set this session.
        player.setChapters(found)
        skipState = Dictionary(
            uniqueKeysWithValues: found.map { ($0.index, player.isChapterSkipped($0)) }
        )
        loadingChapters = false
    }
}
