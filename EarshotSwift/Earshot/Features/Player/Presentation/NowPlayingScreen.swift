import SwiftUI
import AVKit

/// Full-screen Now Playing view, presented from the mini player. Adds the in-app
/// progress scrubber that the compact bar can't carry, plus artwork, title, the
/// transport controls, and entry points to show notes and the player-controls
/// sheet (sleep timer + chapters). Purely presentational — all behavior delegates
/// to ``PlayerService``.
///
/// Scope is deliberately the scaffold + scrubber (issue #367). Speed control,
/// episode actions, and the bookmarks list are tracked as follow-up issues and
/// slot into this screen later.
struct NowPlayingScreen: View {
    @Environment(PlayerService.self) private var player
    @Environment(\.dismiss) private var dismiss

    @State private var showingControls = false
    @State private var showingNotes = false
    @State private var showingSpeedPicker = false

    // On present, VoiceOver should land on the episode title (a heading), not the
    // Close button or the decorative artwork. We request focus after a short
    // settle so the sheet transition doesn't drop the request mid-animation.
    @AccessibilityFocusState private var titleFocused: Bool
    @AccessibilityFocusState private var speedBadgeFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.xl) {
                    artworkBlock
                        .padding(.top, Spacing.lg)

                    titleBlock
                    ScrubberView(player: player)
                    transportRow
                    speedRow
                    sleepTimerRow
                    airPlayRow

                    if hasShowNotes {
                        showNotesButton
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Spacing.lg)
                .padding(.bottom, Spacing.xl)
            }
            .navigationTitle("Now Playing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                        .accessibilityLabel("Close player")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingControls = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .accessibilityLabel("Player controls, sleep timer and chapters")
                }
            }
            .sheet(isPresented: $showingControls) { PlayerControlsSheet() }
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
        }
        .task {
            // Let the present transition settle before requesting VoiceOver focus;
            // a request mid-animation is dropped.
            try? await Task.sleep(for: .milliseconds(500))
            titleFocused = true
        }
    }

    // MARK: Artwork (with hold-to-fast-forward, #373)

    /// The episode artwork doubles as a press-and-hold fast-forward "scan" pad:
    /// holding raises playback to 4× while held and restores the prior rate on
    /// release (Flutter parity). For VoiceOver users the same behavior is a custom
    /// rotor action, but only when Direct Touch is enabled — without it the
    /// sustained press conflicts with VoiceOver's own gestures. The sighted
    /// press-and-hold is always available.
    @ViewBuilder
    private var artworkBlock: some View {
        let base = PodcastArtwork(urlString: artworkURLString, size: 280, cornerRadius: 16)
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
            // Offer the scan as a rotor action only where Direct Touch applies.
            .accessibilityActions {
                if player.fastForwardRotorAvailable {
                    if player.isFastForwarding {
                        Button("Stop Fast Forward") { player.endFastForward() }
                    } else {
                        Button("Start Fast Forward") { player.beginFastForward() }
                    }
                }
            }

        // Only attach a value node while actually scanning. An empty-string value
        // registers a node VoiceOver reads as a pause (the same rule applied in
        // PlayerControlsSheet), so the idle artwork carries no value.
        if player.isFastForwarding {
            base.accessibilityValue("Fast forwarding at 4 times speed")
        } else {
            base
        }
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
                .accessibilityFocused($titleFocused)
            if let artist = player.currentArtist {
                Text(artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Transport

    private var transportRow: some View {
        HStack(spacing: Spacing.xl) {
            transportButton(
                systemImage: "gobackward",
                label: "Skip back \(secondsPhrase(player.skipBackSeconds))",
                font: .title,
                action: player.skipBack
            )

            // Stable VoiceOver name ("Play or pause") with the live state carried by
            // the value, matching the mini bar. Play-state is announced once at the
            // RootView level, so this screen adds no own onChange announcement.
            Button(action: player.togglePlayPause) {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(.largeTitle, design: .default))
                    .imageScale(.large)
                    .accessibilityHidden(true)
            }
            .frame(minWidth: Spacing.minTouchTarget, minHeight: Spacing.minTouchTarget)
            .accessibilityLabel("Play or pause")
            .accessibilityValue(player.isPlaying ? "Playing" : "Paused")

            transportButton(
                systemImage: "goforward",
                label: "Skip forward \(secondsPhrase(player.skipForwardSeconds))",
                font: .title,
                action: player.skipForward
            )
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.sm)
    }

    private func transportButton(
        systemImage: String,
        label: String,
        font: Font,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(font)
                .frame(minWidth: Spacing.minTouchTarget, minHeight: Spacing.minTouchTarget)
                .contentShape(Rectangle())
                .accessibilityHidden(true)
        }
        .accessibilityLabel(label)
    }

    // MARK: Speed control row

    /// A compact single-row speed badge. Tapping opens the full speed picker
    /// sheet where the user can choose a quick value or use the stepper.
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
                    .background(.thinMaterial, in: Capsule())
            }
            .accessibilityLabel("Playback speed")
            .accessibilityValue(speedAccessibilityValue)
            .accessibilityHint("Opens speed picker")
            .accessibilityFocused($speedBadgeFocused)
            Spacer()
        }
    }

    private var speedLabel: String {
        let rate = player.effectiveRate
        let formatted = rate.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", rate)
            : String(format: "%g", rate)
        let overrideIndicator = player.hasPodcastSpeedOverride ? "*" : ""
        return "\(formatted)x\(overrideIndicator)"
    }

    private var speedAccessibilityValue: String {
        let label = PlaybackLogic.spokenRate(player.effectiveRate)
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
            HStack(spacing: Spacing.md) {
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

                Spacer()

                if !timer.endOfEpisode {
                    Button {
                        timer.extend()
                        Announcer.announce("Sleep timer extended by 5 minutes")
                    } label: {
                        Text("+5 min")
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, Spacing.md)
                            .padding(.vertical, Spacing.xs)
                            .background(.thinMaterial, in: Capsule())
                    }
                    .accessibilityLabel("Extend sleep timer by 5 minutes")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.xs)
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

    // MARK: AirPlay route picker

    /// A centered AirPlay route picker. Tapping presents the system output-device
    /// sheet (AirPlay, Bluetooth, etc.). The accessible label and hint are set on
    /// the underlying `AVRoutePickerView` inside `RoutePickerView`.
    private var airPlayRow: some View {
        HStack {
            Spacer()
            RoutePickerView()
                .frame(minWidth: Spacing.minTouchTarget, minHeight: Spacing.minTouchTarget)
            Spacer()
        }
    }

    // MARK: Show notes

    private var showNotesButton: some View {
        Button {
            showingNotes = true
        } label: {
            HStack {
                Text("Show notes")
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, Spacing.sm)
        .accessibilityHint("Opens the episode show notes")
    }

    // MARK: Derived

    private var artworkURLString: String? {
        player.nowPlayingEpisode?.artworkURL ?? player.nowPlayingEpisode?.podcast?.artworkURL
    }

    private var hasShowNotes: Bool {
        !(player.nowPlayingEpisode?.episodeDescription?.isEmpty ?? true)
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

    @State private var isEditing = false
    @State private var dragSeconds: Double = 0
    // A latch for VoiceOver adjust steps. `seek(to:)` updates the player's
    // observed position synchronously, but during playback the once-a-second
    // time observer can transiently overwrite it with the player's clock before
    // AVPlayer's async seek lands. Holding the just-seeked target here keeps the
    // spoken value and the next adjust step deterministic until the live position
    // converges (cleared in `.onChange`).
    @State private var adjustTarget: Double?

    /// VoiceOver adjust step. Matches the 30s used by the Flutter scrubber.
    private let stepSeconds: Double = 30

    private var duration: Double { player.durationSeconds }
    private var hasDuration: Bool { player.hasKnownDuration }

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
            Slider(
                value: Binding(
                    get: { displaySeconds },
                    set: { dragSeconds = $0 }
                ),
                in: 0...(hasDuration ? duration : 1),
                onEditingChanged: { editing in
                    if editing {
                        // Seed from the live position so the thumb doesn't jump on
                        // first touch, then freeze on the drag value. Drop any
                        // pending adjust latch so it can't shadow the drag.
                        dragSeconds = player.currentPositionSeconds
                        adjustTarget = nil
                        isEditing = true
                    } else {
                        player.seek(to: dragSeconds)
                        isEditing = false
                    }
                }
            )
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

            HStack {
                Text(BookmarkLogic.clock(Int(displaySeconds)))
                Spacer()
                Text(hasDuration ? BookmarkLogic.clock(Int(duration)) : "--:--")
            }
            .font(.footnote)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            // The slider element already speaks the elapsed time; keep these
            // visual labels out of the VoiceOver tree so they aren't stray stops.
            .accessibilityHidden(true)
        }
    }

    /// The VoiceOver stand-in for the visual slider: a single element that speaks
    /// the framed label and the current position. The adjustable action is layered
    /// on by the caller only when a duration is known.
    private var scrubberAccessibilityElement: some View {
        Color.clear
            .accessibilityElement()
            .accessibilityLabel(scrubberLabel)
            .accessibilityValue(BookmarkLogic.spoken(Int(displaySeconds)))
    }

    /// Stable spoken framing for the value. Remaining and total are spoken in the
    /// same word format as the value so VoiceOver never flips between "M:SS" and
    /// word form on the same control (the #328 guarantee).
    private var scrubberLabel: String {
        guard hasDuration else { return "Playback position" }
        let remaining = max(0, duration - displaySeconds)
        return "Playback position, \(BookmarkLogic.spoken(Int(remaining))) remaining "
            + "of \(BookmarkLogic.spoken(Int(duration)))"
    }
}
