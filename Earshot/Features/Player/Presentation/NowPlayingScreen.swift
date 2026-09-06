import SwiftUI
import AVKit
import SwiftData

/// Root-provided route from the modal player back into Library folder detail.
/// A missing handler means the host has no compatible navigation state, in
/// which case Now Playing omits the control instead of presenting a dead button.
struct PlaybackFolderNavigationAction: Sendable {
    private let handler: (@MainActor @Sendable (PersistentIdentifier) -> Void)?

    init(_ handler: (@MainActor @Sendable (PersistentIdentifier) -> Void)? = nil) {
        self.handler = handler
    }

    var isAvailable: Bool { handler != nil }

    @MainActor
    func callAsFunction(_ folderID: PersistentIdentifier) {
        handler?(folderID)
    }
}

private struct PlaybackFolderNavigationKey: EnvironmentKey {
    static let defaultValue = PlaybackFolderNavigationAction()
}

extension EnvironmentValues {
    var playbackFolderNavigation: PlaybackFolderNavigationAction {
        get { self[PlaybackFolderNavigationKey.self] }
        set { self[PlaybackFolderNavigationKey.self] = newValue }
    }
}

/// Full-screen Now Playing view, presented from the mini player. Adds the in-app
/// progress scrubber that the compact bar can't carry, plus artwork, title, the
/// transport controls, and entry points to show notes and the player-controls
/// sheet (sleep timer + chapters). Purely presentational — all behavior delegates
/// to ``PlayerService``.
///
/// Scope began as the scaffold + scrubber (issue #367); speed control, episode
/// actions (#371), and the bookmarks list (#372) have since slotted in via the
/// toolbar overflow menu and the artwork rotor.
struct NowPlayingScreen: View {
    @Environment(PlayerService.self) private var player
    @Environment(DownloadManager.self) private var downloads
    @Environment(SettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.playbackFolderNavigation) private var openPlaybackFolder
    @Query(sort: [SortDescriptor(\PodcastFolder.sortOrder), SortDescriptor(\PodcastFolder.name)])
    private var folders: [PodcastFolder]

    @State private var scrubPreview: Double?
    @State private var showingControls = false
    @State private var pendingOptionAction: (() -> Void)?
    @State private var restoresOptionsFocus = false
    @AccessibilityFocusState private var moreOptionsFocused: Bool
    @State private var showingNotes = false
    // The transcript reader sheet (#451), shown only when the current episode's
    // feed advertised a transcript URL.
    @State private var showingTranscript = false
    @State private var showingSpeedPicker = false
    @State private var showingBookmarks = false
    // The full chapter list (#509), opened by activating the current-chapter
    // display below the title. The same list is reachable from the controls sheet.
    @State private var showingChapters = false

    // Export audio file (#371): the prepared local-file URL to share, and a flag
    // covering the download-then-share wait so the action can show progress and
    // disable itself while in flight.
    @State private var exportURL: ExportFile?
    @State private var isExporting = false

    @AccessibilityFocusState private var speedBadgeFocused: Bool

    /// Latches the speed a VoiceOver flick just set, so the badge's spoken value
    /// updates immediately on the same step. The badge's value otherwise derives
    /// from the external @Observable `player.effectiveRate`, which isn't refreshed
    /// in lockstep with VoiceOver's post-adjust re-read (unlike the in-action
    /// @Binding writes that make the other adjustable pickers update instantly).
    /// Cleared once `effectiveRate` converges. Mirrors the scrubber's adjustTarget.
    @State private var speedAdjustLatch: Double?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                playerHeader
                ScrollView {
                    VStack(spacing: Spacing.xl) {
                        artworkBlock
                            .padding(.top, Spacing.lg)
                        titleBlock
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, Spacing.lg)
                    .padding(.bottom, Spacing.xl)
                }
                .frame(maxHeight: .infinity)
                .accessibilityIdentifier("player.episodeContent")
                playbackDock
                ScrollView {
                    VStack(spacing: Spacing.xl) {
                        if let failure = player.playbackFailureMessage {
                            Label(failure, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.secondary)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(failure)
                        }
                        chapterRow
                        speedRow
                        sleepTimerRow
                        if hasTranscript { transcriptButton }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, Spacing.lg)
                    .padding(.vertical, Spacing.lg)
                }
                .frame(maxHeight: .infinity)
                .accessibilityIdentifier("player.details")
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showingControls, onDismiss: {
                let action = pendingOptionAction
                pendingOptionAction = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    if let action { action() }
                    else { moreOptionsFocused = true }
                }
            }) {
                PlayerControlsSheet { episodeOptions }
            }
            .sheet(isPresented: $showingSpeedPicker, onDismiss: {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    speedBadgeFocused = true
                }
            }) {
                SpeedPickerSheet()
            }
            .sheet(isPresented: $showingNotes) {
                if let episode = player.nowPlayingEpisode {
                    ShowNotesView(episode: episode)
                }
            }
            .sheet(isPresented: $showingTranscript) {
                TranscriptView(episode: player.nowPlayingEpisode)
            }
            .sheet(item: $exportURL, onDismiss: restoreOptionsFocus) { file in
                ShareSheet(items: [file.url])
            }
            .sheet(isPresented: $showingBookmarks, onDismiss: restoreOptionsFocus) {
                if let episode = player.nowPlayingEpisode {
                    BookmarksListView(episode: episode)
                }
            }
            .sheet(isPresented: $showingChapters) {
                ChapterListView()
            }
        }
        // Deleting the loaded episode clears the player's observed identity
        // before SwiftData performs the cascade. Close this modal at that same
        // boundary instead of leaving a stale, empty Now Playing destination on
        // screen after a remote unfollow.
        .onChange(of: player.nowPlayingEpisodeID) { _, episodeID in
            if episodeID == nil { dismiss() }
        }
    }

    // Two equally flexible scroll regions share the space around the playback
    // area. Episode content cannot change its position. Visual and semantic
    // order match without an overlay or sort priority. System initial
    // focus is left alone: no delayed request can steal focus after a first touch.
    private var playerHeader: some View {
        HStack(spacing: Spacing.sm) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Close player")
            Spacer(minLength: 0)
            Text("Now Playing")
                .font(.headline)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            Button { showingControls = true } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("More options")
            .accessibilityHint("Episode actions and playback settings")
            .accessibilityFocused($moreOptionsFocused)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Spacing.lg)
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
    }

    private var playbackDock: some View {
        VStack(spacing: Spacing.xs) {
            // Clocks can grow upward without moving the slider or transport.
            ViewThatFits(in: .horizontal) {
                HStack {
                    playbackElapsed
                    Spacer()
                    playbackDuration
                }
                VStack(spacing: 0) {
                    playbackElapsed
                    playbackDuration
                }
            }
            .font(.footnote)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .accessibilityHidden(true) // The slider speaks both complete times.
            ScrubberView(player: player, preview: $scrubPreview)
            transportRow
            HStack(spacing: Spacing.lg) {
                RoutePickerView()
                    .frame(width: 64, height: 56)
                    .frame(maxWidth: .infinity)
                showNotesButton
                    .frame(maxWidth: .infinity)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, Spacing.lg)
        .padding(.bottom, Spacing.sm)
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
    }

    private var playbackElapsed: some View {
        Text(BookmarkLogic.clock(Int(scrubPreview ?? player.currentPositionSeconds)))
            .fixedSize()
    }
    private var playbackDuration: some View {
        Text(player.hasKnownDuration ? BookmarkLogic.clock(Int(player.durationSeconds)) : "--:--")
            .fixedSize()
    }

    // MARK: Artwork (with hold-to-fast-forward, #373)

    /// The episode artwork doubles as a press-and-hold fast-forward "scan" pad:
    /// holding raises playback to 4× while held and restores the prior rate on
    /// release (Flutter parity). For VoiceOver users the same behavior is always
    /// available as a custom rotor action (#610) -- a separate trigger path from
    /// the raw press-and-hold gesture below, so it carries none of that gesture's
    /// VoiceOver-touch-conflict risk. The sighted press-and-hold is itself always
    /// available too.
    @ViewBuilder
    private var artworkBlock: some View {
        // Compact visible artwork retains its accessibility stop and actions.
        // The transport occupies a separate, reserved region below this scroll view.
        let side: CGFloat = 140
        let base = PodcastArtwork(urlString: artworkURLString, size: side, cornerRadius: 16)
            // A zero-distance long press fires `pressing:` on touch-down and again
            // on release, giving us begin/end without a separate drag gesture.
            .onLongPressGesture(minimumDuration: 0.3, pressing: { isPressing in
                if isPressing {
                    player.beginFastForward()
                } else {
                    player.endFastForward()
                }
            }, perform: {})
            // Collapse PodcastArtwork's internal elements into one definite node so
            // the label, value, and rotor action below reliably attach to it.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Episode artwork")
            .accessibilityHint("Use Actions for playback and episode options")
            // Offer the scan rotor action (#610), plus the three episode actions
            // (#371) so VoiceOver users reach Mark as played, Export audio file,
            // and Stop after this episode from the artwork rotor — the same set
            // the visible overflow menu shows. Routed through the shared helper so
            // the rotor announces the designed order despite the OS's reversed
            // emission (#572, #577).
            .rotorActions(artworkRotorActions)

        // Only attach a value node while actually scanning. An empty-string value
        // registers a node VoiceOver reads as a pause (the same rule applied in
        // PlayerControlsSheet), so the idle artwork carries no value.
        if player.isFastForwarding {
            base.accessibilityValue("Fast forwarding at 4 times speed")
        } else {
            base
        }
    }

    /// The artwork's rotor actions in DESIGNED announce order: fast-forward
    /// scan first, then the three episode actions (#371), Bookmarks, and
    /// prev/next chapter (#508) last. Built as an array so `rotorActions(_:)`
    /// can compensate the OS's reversed emission (#577).
    private var artworkRotorActions: [QuickActionItem] {
        var actions: [QuickActionItem] = []
        if player.fastForwardRotorAvailable {
            if player.isFastForwarding {
                actions.append(QuickActionItem(label: "Stop Fast Forward", isDestructive: false) {
                    player.endFastForward()
                })
            } else {
                actions.append(QuickActionItem(label: "Start Fast Forward", isDestructive: false) {
                    player.beginFastForward()
                })
            }
        }
        actions.append(QuickActionItem(label: "Previous in Queue", isDestructive: false) {
            player.previousInQueue()
        })
        actions.append(QuickActionItem(label: "Next in Queue", isDestructive: false) {
            player.nextInQueue()
        })
        actions.append(QuickActionItem(label: "Mark as played and next in Queue", isDestructive: false) {
            player.markCurrentPlayedAndNextInQueue()
        })
        actions.append(QuickActionItem(label: "Mark as played", isDestructive: false) {
            player.markCurrentPlayedAndAdvance()
        })
        actions.append(QuickActionItem(label: exportActionLabel, isDestructive: false) {
            startExport()
        })
        actions.append(QuickActionItem(label: stopAfterActionLabel, isDestructive: false) {
            player.toggleStopAfterEpisode()
        })
        if let episode = player.nowPlayingEpisode {
            actions.append(QuickActionItem(label: "Refresh episode audio", isDestructive: false) {
                Task { await player.refreshEpisodeAudio(episode, using: downloads) }
            })
        }
        if player.nowPlayingEpisode != nil {
            actions.append(QuickActionItem(label: "Bookmarks", isDestructive: false) {
                showingBookmarks = true
            })
        }
        // Mirror the visible prev/next chapter controls into the artwork rotor
        // so VoiceOver users reach them the same way they reach the episode
        // actions (#508). Only when the episode has chapters.
        if player.chapterCount > 0 {
            actions.append(QuickActionItem(label: "Previous chapter", isDestructive: false) {
                player.previousChapter()
            })
            actions.append(QuickActionItem(label: "Next chapter", isDestructive: false) {
                player.nextChapter()
            })
        }
        return actions
    }

    // MARK: Title

    private var titleBlock: some View {
        VStack(spacing: Spacing.xs) {
            Text(player.currentTitle ?? "")
                .font(.title3)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .accessibilityAddTraits(.isHeader)
                // Fold the downloaded / streaming state into the title heading so
                // VoiceOver announces "Title, Downloaded" on the one element the
                // player lands on — no extra stop (#513). Falls back to the plain
                // title when nothing is loaded.
                .accessibilityLabel(titleAccessibilityLabel)
            if let artist = player.currentArtist {
                Text(artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            if let folder = playbackOriginFolder, openPlaybackFolder.isAvailable {
                Button {
                    open(folder: folder)
                } label: {
                    Text(
                        PlaybackOriginLabel.playingFrom(
                            folderPath: FolderLogic.pathString(folder)
                        )
                    )
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: Spacing.minTouchTarget
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                // The visible phrase is already the complete concise name. Do
                // not add a second accessibility label/value that VoiceOver can
                // append to it (the Downloads picker regression).
                .accessibilityHint("Opens this folder")
            }
            // Visible downloaded / streaming indicator for the current episode
            // (#513), the same icon + text treatment the rows use. Hidden from
            // VoiceOver inside the badge; the spoken state rides on the title above.
            if let status = player.nowPlayingEpisode?.downloadStatus {
                DownloadStateBadge(status: status)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var playbackOriginFolder: PodcastFolder? {
        guard let folderID = player.playbackOrigin?.folderID else { return nil }
        return folders.first { $0.persistentModelID == folderID }
    }

    private func open(folder: PodcastFolder) {
        let folderID = folder.persistentModelID
        dismiss()
        // Let the modal dismissal finish before switching tabs and pushing the
        // destination, avoiding competing transitions and dropped VoiceOver
        // screen-change focus.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            openPlaybackFolder(folderID)
        }
    }

    /// The title heading's spoken label: the episode title with the downloaded /
    /// streaming state appended, so the player's landing element carries the same
    /// state the rows do (#513). Plain title when nothing is loaded.
    private var titleAccessibilityLabel: String {
        let title = player.currentTitle ?? ""
        guard let status = player.nowPlayingEpisode?.downloadStatus else { return title }
        return "\(title), \(EpisodeRowLabel.spokenDownloadState(status))"
    }

    // MARK: Current chapter (#508, #509, #515)

    /// The chapter row: the current-chapter name as a button that opens the full
    /// chapter list (#509), flanked by Previous- and Next-chapter buttons (#515).
    /// Shown only while the episode has chapters AND playback is within one
    /// (`currentChapterTitle` is nil before the first chapter, which also implies
    /// `chapterCount > 0`).
    ///
    /// Reads left-to-right: [Previous chapter] — [Chapter name] — [Next chapter].
    /// The flanking buttons are hidden when the user turns off
    /// ``SettingsStore/chapterNavButtonsVisible`` (#515); the chapter-name button
    /// always stays, and the artwork VoiceOver rotor keeps its own Previous/Next
    /// chapter actions regardless of this setting, so hiding the buttons never
    /// removes chapter navigation.
    ///
    /// Accessibility: three distinct stops in visual order — "Previous chapter"
    /// button, the chapter-name button ("Chapter, <title>", hint "Opens the
    /// chapter list"), "Next chapter" button. The HStack is intentionally NOT
    /// collapsed into one element so each button keeps its own action.
    @ViewBuilder
    private var chapterRow: some View {
        if player.chapterCount > 0 {
            let title = player.currentChapterTitle ?? "Chapters"
            HStack(spacing: Spacing.md) {
                if showChapterNavButtons {
                    transportButton(
                        systemImage: "backward.end.fill",
                        label: "Previous chapter",
                        font: .title3,
                        action: player.previousChapter
                    )
                }

                chapterNameButton(title: title)

                if showChapterNavButtons {
                    transportButton(
                        systemImage: "forward.end.fill",
                        label: "Next chapter",
                        font: .title3,
                        action: player.nextChapter
                    )
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// Whether the visible Previous/Next chapter buttons flank the chapter name.
    /// Default on; users who prefer the artwork rotor turn it off in Settings
    /// (#515). Gated on `chapterCount > 0` for safety, though the enclosing
    /// `currentChapterTitle` check already implies it.
    private var showChapterNavButtons: Bool {
        ChapterNavLogic.shouldShowNavButtons(
            chapterCount: player.chapterCount,
            settingEnabled: settings.chapterNavButtonsVisible
        )
    }

    /// The current-chapter name as a button opening ``ChapterListView`` (#509).
    /// Collapsed into one node labeled "Chapter" whose value is the title, so
    /// VoiceOver reads "Chapter, <title>, button" rather than a stray icon stop.
    private func chapterNameButton(title: String) -> some View {
        Button {
            showingChapters = true
        } label: {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "list.bullet")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, minHeight: Spacing.minTouchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Chapter")
        .accessibilityValue(title)
        .accessibilityHint("Opens the chapter list")
    }

    // MARK: Transport

    private var transportRow: some View {
        HStack(spacing: Spacing.md) {
            transportButton(
                systemImage: "gobackward",
                label: "Skip back \(secondsPhrase(player.skipBackSeconds))",
                font: .title,
                target: 64,
                action: player.skipBack
            )
            // Pair "Previous chapter" with Skip back as a VoiceOver custom action
            // (#560), the same rotor-action pattern the artwork uses. Additive:
            // the button keeps its default Skip back activation. Announces a clear
            // "no chapters" response when the episode has none, never a silent no-op.
            .accessibilityAction(named: "Previous chapter") {
                player.previousChapterOrAnnounceNoChapters()
            }
            .accessibilityAction(named: "Previous in Queue") {
                player.previousInQueue()
            }
            .accessibilityHint("Use Actions for more navigation options")

            // Dynamic VoiceOver name reflecting the action the button performs
            // ("Play" when paused, "Pause" when playing), matching the mini bar.
            // Play-state is announced once at the RootView level, so this screen
            // adds no own onChange announcement.
            Button(action: player.togglePlayPause) {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(.largeTitle, design: .default))
                    .imageScale(.large)
                    .frame(minWidth: 80, minHeight: 80)
                    .contentShape(Rectangle())
                    .accessibilityHidden(true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            .accessibilityIdentifier("player.playPause")

            transportButton(
                systemImage: "goforward",
                label: "Skip forward \(secondsPhrase(player.skipForwardSeconds))",
                font: .title,
                target: 64,
                action: player.skipForward
            )
            // Pair "Next chapter" with Skip forward as a VoiceOver custom action
            // (#560); mirrors the Skip back / Previous chapter pairing above.
            .accessibilityAction(named: "Next chapter") {
                player.nextChapterOrAnnounceNoChapters()
            }
            .accessibilityAction(named: "Next in Queue") {
                player.nextInQueue()
            }
            .accessibilityAction(named: "Mark as played and next in Queue") {
                player.markCurrentPlayedAndNextInQueue()
            }
            .accessibilityHint("Use Actions for more navigation options")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.sm)
    }

    private func transportButton(
        systemImage: String,
        label: String,
        font: Font,
        target: CGFloat = 44,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(font)
                .frame(minWidth: target, minHeight: target)
                .contentShape(Rectangle())
                .accessibilityHidden(true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier("player.\(systemImage)")
    }

    // MARK: Speed control row

    /// A compact single-row speed badge. For VoiceOver it's a pure adjustable
    /// control: flick up/down changes the speed in place, and the full picker
    /// sheet (scope, precise stepper, reset) is reachable via the "Open speed
    /// options" custom action in the Actions rotor. For sighted users, tapping
    /// the capsule opens the sheet.
    private var speedRow: some View {
        HStack {
            Spacer()
            Button {
                showingSpeedPicker = true
            } label: {
                Text(speedLabel)
                    .font(.subheadline.monospacedDigit())
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.xs)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                    .background(.thinMaterial, in: Capsule())
            }
            // Replace the button's accessibility node with a PURE adjustable
            // element (no button trait). Combining `.isButton` with the adjustable
            // trait makes VoiceOver announce "button, adjustable" and suppresses
            // the value re-read after a flick. A clean adjustable element (the
            // same idiom as the scrubber) announces "Playback speed, adjustable"
            // and re-reads the new speed on every flick. The visual capsule still
            // opens the sheet on tap for sighted users; VoiceOver users open the
            // full picker via the "Open speed options" custom action.
            .accessibilityRepresentation {
                Color.clear
                    .accessibilityElement()
                    .accessibilityLabel("Playback speed")
                    .accessibilityValue(speedAccessibilityValue)
                    // No hint: VoiceOver already appends "swipe up or down to
                    // adjust" for an adjustable element (the scrubber omits it for
                    // the same reason).
                    .accessibilityAdjustableAction { direction in
                        adjustBadgeSpeed(direction)
                    }
                    .accessibilityAction(named: "Open speed options") {
                        showingSpeedPicker = true
                    }
                    .accessibilityFocused($speedBadgeFocused)
            }
            Spacer()
        }
        .onChange(of: player.effectiveRate) { _, newValue in
            // Drop the latch once the player catches up, so external speed changes
            // (the sheet, a per-podcast override) drive the spoken value again.
            if let latch = speedAdjustLatch, abs(newValue - latch) < 0.001 {
                speedAdjustLatch = nil
            }
        }
    }

    /// Quick in-player speed adjust from the badge: VoiceOver flick up/down steps
    /// through the curated menu speeds (``PlaybackLogic/speedMenuValues``),
    /// saved as a per-podcast override whenever a real podcast is loaded — otherwise
    /// (a transient stream preview, #517) it falls back to the global speed (#606,
    /// Flutter parity). Mirrors ``AdjustableOptionPicker`` stepping: clamped at both
    /// ends, no write (and so no value change) at a boundary.
    private func adjustBadgeSpeed(_ direction: AccessibilityAdjustmentDirection) {
        let speeds = PlaybackLogic.speedMenuValues
        // Step from the latched value when a previous flick hasn't converged yet,
        // so rapid flicks move one step each instead of restepping a stale rate.
        let base = speedAdjustLatch ?? player.effectiveRate
        let current = PlaybackLogic.nearestMenuSpeed(base)
        let currentIndex = speeds.firstIndex(of: current) ?? 0
        let delta: Int
        switch direction {
        case .increment: delta = 1
        case .decrement: delta = -1
        @unknown default: return
        }
        let next = OptionStepLogic.steppedIndex(count: speeds.count, current: currentIndex, delta: delta)
        guard next != currentIndex else { return }
        let speed = speeds[next]
        // Latch first so the spoken accessibilityValue reflects the new speed on
        // this same step, before the external player change propagates back.
        speedAdjustLatch = speed
        // announce: false — the badge is adjustable, so VoiceOver re-reads its
        // accessibilityValue (the new speed) automatically; an announce here
        // would speak it twice.
        if player.canOverridePerPodcast {
            player.setPodcastSpeedOverride(speed, announce: false)
        } else {
            player.setGlobalSpeed(speed, announce: false)
        }
    }

    /// The rate to display/speak: the just-flicked latched value until the player
    /// catches up, otherwise the live effective rate.
    private var displayRate: Double { speedAdjustLatch ?? player.effectiveRate }

    private var speedLabel: String {
        let rate = displayRate
        let formatted = rate.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", rate)
            : String(format: "%g", rate)
        let overrideIndicator = player.hasPodcastSpeedOverride ? "*" : ""
        return "\(formatted)x\(overrideIndicator)"
    }

    private var speedAccessibilityValue: String {
        let label = PlaybackLogic.spokenRate(displayRate)
        return player.hasPodcastSpeedOverride ? "\(label), podcast override active" : label
    }

    // MARK: Sleep timer row

    /// An inline sleep timer status row: visible only when a timer is active.
    /// Shows the live countdown (or "End of episode") and an "Extend +5 min"
    /// button for countdown mode. Tapping the controls button in the toolbar
    /// also reaches the full sleep timer section in PlayerControlsSheet.
    @ViewBuilder
    private var sleepTimerRow: some View {
        let timer = player.sleepTimer
        if timer.isActive {
            ViewThatFits(in: .horizontal) {
                sleepTimerContents(horizontal: true)
                sleepTimerContents(horizontal: false)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.xs)
        }
    }

    private func sleepTimerContents(horizontal: Bool) -> some View {
        let timer = player.sleepTimer
        let layout = horizontal ? AnyLayout(HStackLayout(spacing: Spacing.md)) : AnyLayout(VStackLayout(spacing: Spacing.md))
        return layout {
                Image(systemName: "moon.zzz.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                Text(sleepTimerStatusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .accessibilityLabel("Sleep timer")
                    .accessibilityValue(timer.endOfEpisode
                        ? "End of episode"
                        : SleepTimerLogic.spokenRemaining(timer.remainingSeconds))

                if horizontal { Spacer() }

                if !timer.endOfEpisode {
                    Button {
                        timer.extend()
                        Announcer.announce("Sleep timer extended by 5 minutes")
                    } label: {
                        Text("+5 min")
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, Spacing.md)
                            .padding(.vertical, Spacing.xs)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                            .background(.thinMaterial, in: Capsule())
                    }
                    .accessibilityLabel("Extend sleep timer by 5 minutes")
                }
        }
    }

    private var sleepTimerStatusText: String {
        let timer = player.sleepTimer
        if timer.endOfEpisode { return "End of episode" }
        if let remaining = timer.remainingSeconds {
            return SleepTimerLogic.clock(remaining)
        }
        return ""
    }

    // MARK: Show notes

    private var showNotesButton: some View {
        Button {
            showingNotes = true
        } label: {
            Text("Show notes")
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 56)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!hasShowNotes)
        .accessibilityHint(hasShowNotes ? "Opens the episode show notes" : "This episode has no show notes")
    }

    // MARK: Transcript (#451)

    /// Opens the transcript reader from the scrolling details. Shown only when
    /// the current episode advertised a transcript URL, so it
    /// never offers a dead action.
    private var transcriptButton: some View {
        Button {
            showingTranscript = true
        } label: {
            HStack {
                Text("Transcript")
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            // Guarantee a 44pt-plus tap target at default Dynamic Type; the
            // vertical padding alone leaves the row short of the minimum.
            .frame(minHeight: Spacing.minTouchTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, Spacing.sm)
        .accessibilityHint("Opens the episode transcript")
    }

    // MARK: Unified options

    @ViewBuilder
    private var episodeOptions: some View {
        Button("Previous in Queue", action: player.previousInQueue)
        Button("Next in Queue", action: player.nextInQueue)
        Button("Mark as played and next in Queue", action: player.markCurrentPlayedAndNextInQueue)
            Button {
                player.markCurrentPlayedAndAdvance()
            } label: {
                Label("Mark as played", systemImage: "checkmark.circle")
            }

            Button {
                closeOptionsThen { startExport() }
            } label: {
                Label(exportActionLabel, systemImage: "square.and.arrow.up")
            }
            .disabled(isExporting)

            Button {
                closeOptionsThen { showingBookmarks = true }
            } label: {
                Label("Bookmarks", systemImage: "bookmark")
            }

            Button {
                guard let episode = player.nowPlayingEpisode else { return }
                Task { await player.refreshEpisodeAudio(episode, using: downloads) }
            } label: {
                Label("Refresh episode audio", systemImage: "arrow.clockwise")
            }
    }

    private func closeOptionsThen(_ action: @escaping () -> Void) {
        restoresOptionsFocus = true
        pendingOptionAction = action
        showingControls = false
    }

    private func restoreOptionsFocus() {
        guard restoresOptionsFocus else { return }
        restoresOptionsFocus = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            moreOptionsFocused = true
        }
    }

    /// Export label reflects the download-then-share wait so the user knows the
    /// file has to download first when it isn't already local.
    private var exportActionLabel: String {
        if isExporting { return "Preparing audio file…" }
        return player.currentEpisodeIsDownloaded
            ? "Export audio file"
            : "Download and export audio file"
    }

    /// Stop-after label flips so the rotor action announces what activating it
    /// will do (set vs cancel), since rotor buttons can't show a checkmark.
    private var stopAfterActionLabel: String {
        player.stopAfterCurrentEpisode
            ? "Cancel stop after this episode"
            : "Stop after this episode"
    }

    /// Kicks off the export: downloads if needed, then presents the share sheet
    /// with the LOCAL file. Guards against double-runs while one is in flight.
    private func startExport() {
        guard !isExporting, player.nowPlayingEpisode != nil else { return }
        isExporting = true
        if !player.currentEpisodeIsDownloaded {
            Announcer.announce("Preparing audio file for export")
        }
        Task {
            let url = await player.exportCurrentEpisodeAudio(using: downloads)
            isExporting = false
            if let url {
                exportURL = ExportFile(url: url)
            } else {
                restoreOptionsFocus()
                Announcer.announce("Could not export audio file")
            }
        }
    }

    // MARK: Derived

    private var artworkURLString: String? {
        player.nowPlayingEpisode?.artworkURL ?? player.nowPlayingEpisode?.podcast?.artworkURL
    }

    private var hasShowNotes: Bool {
        !(player.nowPlayingEpisode?.episodeDescription?.isEmpty ?? true)
    }

    /// Whether the current episode advertised a transcript URL. Gates the transcript
    /// entry point so it only appears when there's something to load (#451).
    private var hasTranscript: Bool {
        !(player.nowPlayingEpisode?.transcriptURL?.isEmpty ?? true)
    }

    /// Pluralizes a seconds count so VoiceOver never reads "1 seconds".
    private func secondsPhrase(_ seconds: Int) -> String {
        "\(seconds) second\(seconds == 1 ? "" : "s")"
    }
}

/// The in-app progress scrubber: a visual `Slider` for sighted drag, with its
/// accessibility fully hand-authored via `.accessibilityRepresentation` so
/// VoiceOver hears a spoken time position and adjusts in 30-second steps rather
/// than the meaningless "x percent" a raw slider announces.
///
/// While the user drags, the thumb follows a local `dragSeconds` instead of the
/// live position, so the once-a-second time observer can't snap it backward. The
/// actual seek lands once on drag-end (never per frame), keeping the synchronous
/// `context.save()` off the drag path (the #362 main-run-loop lesson).
private struct ScrubberView: View {
    let player: PlayerService
    @Binding var preview: Double?

    @State private var isEditing = false
    @State private var dragSeconds: Double = 0
    // A latch for VoiceOver adjust steps. `seek(to:)` updates the player's
    // observed position synchronously, but during playback the once-a-second
    // time observer can transiently overwrite it with the player's clock before
    // AVPlayer's async seek lands. Holding the just-seeked target here keeps the
    // spoken value and the next adjust step deterministic until the live position
    // converges (cleared in `.onChange`).
    @State private var adjustTarget: Double?

    private var duration: Double { player.durationSeconds }
    private var hasDuration: Bool { player.hasKnownDuration }

    /// VoiceOver adjust step, scaled to episode duration (#610). Matches the flat
    /// 30s used by the Flutter scrubber for anything at or under 30 minutes;
    /// longer episodes take fewer, larger steps so a multi-hour episode doesn't
    /// need 100+ flicks to cross.
    private var stepSeconds: Double { PlaybackLogic.scrubberStepSeconds(duration: duration) }

    /// The position to render: the drag value mid-gesture, otherwise a pending
    /// VoiceOver-adjust target if one hasn't converged yet, otherwise the live
    /// position. Clamped into range once duration is known.
    private var displaySeconds: Double {
        let value = isEditing ? dragSeconds : (adjustTarget ?? player.currentPositionSeconds)
        guard hasDuration else { return max(0, value) }
        return min(max(0, value), duration)
    }

    var body: some View {
        VStack(spacing: Spacing.xs) {
            PlayerPositionSlider(
                value: Binding(
                    get: { displaySeconds },
                    set: { dragSeconds = $0; preview = $0 }
                ),
                maximum: hasDuration ? duration : 1,
                onEditingChanged: { editing in
                    if editing {
                        // Seed from the live position so the thumb doesn't jump on
                        // first touch, then freeze on the drag value. Drop any
                        // pending adjust latch so it can't shadow the drag.
                        dragSeconds = player.currentPositionSeconds
                        adjustTarget = nil
                        preview = dragSeconds
                        isEditing = true
                    } else {
                        player.seek(to: dragSeconds)
                        isEditing = false
                        preview = nil
                    }
                }
            )
            .frame(height: 56)
            .disabled(!hasDuration)
            // Clear the VoiceOver-adjust latch once the live position converges on
            // the target, so subsequent ticks drive the display normally again.
            .onChange(of: player.currentPositionSeconds) { _, newValue in
                if let target = adjustTarget, abs(newValue - target) < 1.5 {
                    adjustTarget = nil
                }
            }
            .accessibilityRepresentation {
                if hasDuration {
                    scrubberAccessibilityElement
                        // The adjustable action alone makes VoiceOver treat this as
                        // an adjustable control (swipe up/down) — there is no
                        // `.isAdjustable` trait to add. Only attached once a
                        // duration is known, so the control is never a no-op
                        // adjustable element.
                        .accessibilityAdjustableAction { direction in
                            let base = displaySeconds
                            let target: Double
                            switch direction {
                            case .increment:
                                target = min(base + stepSeconds, duration)
                            case .decrement:
                                target = max(base - stepSeconds, 0)
                            @unknown default:
                                return
                            }
                            // Latch first so the spoken value reflects the new
                            // position immediately, then seek.
                            adjustTarget = target
                            player.seek(to: target)
                        }
                } else {
                    scrubberAccessibilityElement
                }
            }

        }
    }

    /// The VoiceOver stand-in for the visual slider: a single element that speaks
    /// the framed label and the current position. The adjustable action is layered
    /// on by the caller only when a duration is known.
    private var scrubberAccessibilityElement: some View {
        Color.clear
            .frame(height: 56)
            .accessibilityElement()
            .accessibilityIdentifier("player.position")
            // The label is static so VoiceOver isn't re-reading it every second as
            // the 1Hz position tick rebuilds this view. The live time rides in the
            // value, which an adjustable control is expected to update. Previously
            // the label carried the dynamic "X remaining of Y", so the label itself
            // changed every second. (#480)
            .accessibilityLabel("Playback position")
            .accessibilityValue(scrubberValue)
    }

    /// Live spoken position: elapsed framed by total, both in the same word format
    /// so VoiceOver never flips between "M:SS" and word form on the same control
    /// (the #328 guarantee). Mirrors the visible elapsed / total labels.
    private var scrubberValue: String {
        let elapsed = BookmarkLogic.spoken(Int(displaySeconds))
        guard hasDuration else { return elapsed }
        return "\(elapsed) of \(BookmarkLogic.spoken(Int(duration)))"
    }
}

/// Native slider rendering with a full-height interaction region. UISlider's
/// default narrow tracking region does not match an enlarged SwiftUI wrapper.
private struct PlayerPositionSlider: UIViewRepresentable {
    @Binding var value: Double
    let maximum: Double
    let onEditingChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> FullAreaSlider {
        let slider = FullAreaSlider()
        slider.isAccessibilityElement = false // SwiftUI supplies the time-based adjustable element.
        slider.onBegin = { [weak coordinator = context.coordinator] in coordinator?.began($0) }
        slider.addTarget(context.coordinator, action: #selector(Coordinator.changed), for: .valueChanged)
        slider.onEnd = { [weak coordinator = context.coordinator] in coordinator?.ended($0) }
        return slider
    }
    func updateUIView(_ slider: FullAreaSlider, context: Context) {
        context.coordinator.parent = self
        slider.isEnabled = context.environment.isEnabled
        slider.maximumValue = Float(maximum)
        slider.minimumValue = 0
        slider.tintColor = UIColor(Color.accentColor)
        if !slider.isTracking { slider.value = Float(value) }
    }
    @MainActor
    final class Coordinator {
        var parent: PlayerPositionSlider
        init(_ parent: PlayerPositionSlider) { self.parent = parent }
        @objc func began(_ sender: FullAreaSlider) { parent.onEditingChanged(true) }
        @objc func changed(_ sender: FullAreaSlider) { parent.value = Double(sender.value) }
        @objc func ended(_ sender: FullAreaSlider) {
            parent.value = Double(sender.value)
            parent.onEditingChanged(false)
        }
    }
    final class FullAreaSlider: UIControl {
        private let visual = UISlider()
        var minimumValue: Float { get { visual.minimumValue } set { visual.minimumValue = newValue } }
        var maximumValue: Float { get { visual.maximumValue } set { visual.maximumValue = newValue } }
        var value: Float { get { visual.value } set { visual.value = newValue } }
        var onBegin: ((FullAreaSlider) -> Void)?
        var onEnd: ((FullAreaSlider) -> Void)?
        override init(frame: CGRect) {
            super.init(frame: frame)
            visual.isUserInteractionEnabled = false
            visual.isAccessibilityElement = false
            addSubview(visual)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: 56) }
        override func layoutSubviews() {
            super.layoutSubviews()
            visual.frame = bounds
        }
        override var isEnabled: Bool { didSet { visual.isEnabled = isEnabled } }

        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            isEnabled && bounds.contains(point)
        }
        private func move(to touch: UITouch) {
            let track = visual.trackRect(forBounds: visual.bounds)
            let fraction = min(1, max(0, (touch.location(in: self).x - track.minX) / max(1, track.width)))
            value = minimumValue + Float(fraction) * (maximumValue - minimumValue)
            sendActions(for: .valueChanged)
        }
        override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
            guard isEnabled else { return false }
            onBegin?(self)
            move(to: touch)
            return true
        }
        override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
            move(to: touch)
            return true
        }
        override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
            if let touch { move(to: touch) }
            onEnd?(self)
        }
        override func cancelTracking(with event: UIEvent?) {
            onEnd?(self)
        }
    }
}
