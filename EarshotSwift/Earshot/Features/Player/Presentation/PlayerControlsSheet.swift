import SwiftUI

/// Expanded player controls: sleep timer and chapter navigation for the loaded
/// episode. Opened by tapping the Now Playing bar.
struct PlayerControlsSheet: View {
    @Environment(PlayerService.self) private var player
    @Environment(\.dismiss) private var dismiss

    @State private var chapters: [Chapter] = []
    @State private var loadingChapters = true

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
            if sleepTimer.isActive {
                // Visual shows the live countdown; the spoken value is coarse and
                // stable so a parked VoiceOver cursor isn't re-spoken every second.
                LabeledContent("Active", value: sleepTimerValue)
                    .accessibilityElement()
                    .accessibilityLabel("Sleep timer active")
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
            } else {
                ForEach(SleepTimerPreset.allCases) { preset in
                    Button(preset.label) {
                        sleepTimer.set(preset)
                        Announcer.announce(sleepTimer.announcement)
                    }
                }
            }
        }
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
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(chapter.title), \(BookmarkLogic.spoken(Int(chapter.startTime)))")
        .accessibilityHint("Jumps to this chapter")
        // `.isSelected` is the standard list "current item" trait — VoiceOver says
        // "Selected". No empty-string value (that registers a node VO reads as a
        // pause); the trait alone carries the current-chapter state.
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
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
        loadingChapters = false
    }
}
