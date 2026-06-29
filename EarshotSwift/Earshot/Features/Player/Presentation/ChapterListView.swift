import SwiftUI

/// Shared, reusable chapter list presented as a modal sheet (#509). Opened from
/// the current-chapter display on the Now Playing screen (the #508 seam) and from
/// the player controls sheet, so there is one chapter UI, not two divergent ones.
///
/// Model: every chapter is "included" (plays) by default. Deselecting a chapter
/// marks it skipped, driving the existing in-memory skip engine
/// (`PlayerService.toggleChapterSkipped`, #373). Skip memory is per-session and
/// resets on restart — unchanged from the engine.
///
/// Each row is exactly ONE VoiceOver stop (a 20-chapter list stays ~20 flicks):
///  - the primary action (VoiceOver double-tap / sighted tap) seeks and plays
///    from that chapter;
///  - a rotor action ("Skip this chapter" / "Include this chapter") toggles the
///    included/skipped state. The visible sighted include/skip control is
///    `accessibilityHidden`, so it adds no second stop.
struct ChapterListView: View {
    @Environment(PlayerService.self) private var player
    @Environment(\.dismiss) private var dismiss

    @State private var chapters: [Chapter] = []
    @State private var loadingChapters = true
    // Local mirror of the engine's in-memory skipped-chapter set, keyed by chapter
    // index, so toggling re-renders rows immediately (the engine map isn't an
    // observed property). Seeded from the engine when chapters load.
    @State private var skipState: [Int: Bool] = [:]
    @AccessibilityFocusState private var introFocused: Bool

    var body: some View {
        NavigationStack {
            Group {
                if loadingChapters {
                    loadingView
                } else if chapters.isEmpty {
                    emptyView
                } else {
                    chapterList
                }
            }
            .navigationTitle("Chapters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await loadChapters() }
        }
    }

    // MARK: States

    private var loadingView: some View {
        VStack(spacing: Spacing.md) {
            ProgressView()
            Text("Loading chapters…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading chapters")
    }

    private var emptyView: some View {
        ContentUnavailableView(
            "No chapters",
            systemImage: "list.bullet",
            description: Text("This episode doesn't have chapters.")
        )
    }

    private var chapterList: some View {
        List {
            Section {
                ForEach(Array(chapters.enumerated()), id: \.element.id) { offset, chapter in
                    ChapterListRow(
                        chapter: chapter,
                        number: offset + 1,
                        isCurrent: activeChapterIndex == chapter.index,
                        isSkipped: skipState[chapter.index] ?? player.isChapterSkipped(chapter),
                        onJump: { jump(to: chapter) },
                        onToggleSkip: { toggleSkip(chapter) }
                    )
                }
            } header: {
                // "Selected by default" stated in words, per the accessibility
                // criteria. A header element VoiceOver can land on first.
                Text("Every chapter plays by default. Deselect a chapter to skip it during playback.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textCase(nil)
                    .accessibilityFocused($introFocused)
            }
        }
    }

    // MARK: Actions

    /// Primary row action: seek to the chapter and start playback from it.
    /// Reuses the public seek path (the same `player.seek(to:)` the controls
    /// sheet used) and resumes so "jump" actually plays, then announces the
    /// landing chapter for VoiceOver.
    private func jump(to chapter: Chapter) {
        player.seek(to: chapter.startTime)
        player.resume()
        Announcer.announce("Playing \(chapter.title)")
    }

    /// Flips the included/skipped state in the engine and mirrors it locally so
    /// the row re-renders immediately (the engine map isn't observed). The engine
    /// announces the result ("Will skip chapter: X" / "Will play chapter: X"), so
    /// we don't announce again here.
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
            downloadPath: episode.downloadPath,
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
        // Let the present transition settle before requesting VoiceOver focus;
        // a request mid-animation is dropped.
        try? await Task.sleep(for: .milliseconds(500))
        introFocused = true
    }
}

/// One chapter row. Collapsed into a single accessibility element: tapping seeks
/// (primary), and a rotor action toggles include/skip. The sighted include/skip
/// control is `accessibilityHidden` so it never becomes a second VoiceOver stop.
private struct ChapterListRow: View {
    let chapter: Chapter
    let number: Int
    let isCurrent: Bool
    let isSkipped: Bool
    let onJump: () -> Void
    let onToggleSkip: () -> Void

    private var state: ChapterRowState {
        ChapterRowState(isCurrent: isCurrent, isSkipped: isSkipped)
    }

    var body: some View {
        Button(action: onJump) {
            HStack(spacing: Spacing.md) {
                Image(systemName: state.markerSystemImage)
                    .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(chapter.title)
                        .font(.body)
                        .foregroundStyle(isSkipped ? .secondary : .primary)
                        .strikethrough(isSkipped)
                        .lineLimit(2)
                    HStack(spacing: Spacing.sm) {
                        Text(BookmarkLogic.clock(Int(chapter.startTime)))
                            .monospacedDigit()
                        if let status = state.statusWord {
                            Text(status)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: Spacing.sm)

                // Sighted-only include/skip toggle. `accessibilityHidden` so it
                // adds NO second VoiceOver stop; VoiceOver uses the row's rotor
                // action instead. 44pt target for touch.
                Button(action: onToggleSkip) {
                    Image(systemName: state.indicatorSystemImage)
                        .font(.title3)
                        .foregroundStyle(isSkipped ? Color.secondary : Color.accentColor)
                        .frame(minWidth: Spacing.minTouchTarget, minHeight: Spacing.minTouchTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHidden(true)
            }
            .frame(minHeight: Spacing.minTouchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // One VoiceOver stop for the whole row. The outer Button is already a
        // single accessibility element and keeps its own tap as the primary
        // (double-tap) action = jump — the proven EpisodeRow pattern (#479). The
        // sighted include/skip control is `.accessibilityHidden`, so it is not a
        // second stop. We deliberately do NOT add
        // `.accessibilityElement(children: .ignore)`: wrapping the Button in a
        // synthesized element can drop the Button's own activation (the
        // documented "tap widget inside an outer a11y element" trap), leaving the
        // double-tap with no primary action. Overriding the label on the Button
        // is sufficient and keeps activation intact.
        .accessibilityLabel(state.accessibilityLabel(
            number: number,
            title: chapter.title,
            spokenTime: BookmarkLogic.spoken(Int(chapter.startTime))
        ))
        .accessibilityHint("Jumps to this chapter")
        // `.isSelected` is the standard list "current item" trait — VoiceOver
        // says "Selected". Carries the current-chapter state without a value node.
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
        // Include/skip is a rotor action on the SAME element, so it costs no
        // extra flick. The engine announces the result; we do not re-announce.
        .accessibilityAction(named: Text(state.toggleActionName), onToggleSkip)
    }
}
