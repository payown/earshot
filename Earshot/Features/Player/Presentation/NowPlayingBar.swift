import SwiftUI
import SwiftData

/// Compact transport bar pinned above the tab bar. Shows what's loaded and
/// exposes skip-back, play/pause, skip-forward, and bookmark. Purely
/// presentational — all behavior delegates to ``PlayerService``.
struct NowPlayingBar: View {
    @Environment(PlayerService.self) private var player
    @Environment(\.modelContext) private var context

    var body: some View {
        if let title = player.currentTitle {
            // Four 44pt transport buttons plus the title don't fit one row at the
            // largest Dynamic Type sizes, where the glyphs grow and the trailing
            // button would clip below its tap target. ViewThatFits keeps the
            // single-row layout when it fits and drops to title-over-controls when
            // it doesn't, so every button keeps a full 44pt target.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    nowPlayingInfo(title: title)
                    Spacer(minLength: 8)
                    controls
                }
                VStack(alignment: .leading, spacing: 8) {
                    nowPlayingInfo(title: title)
                    HStack(spacing: 12) {
                        Spacer(minLength: 0)
                        controls
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            // Make the semantic container own the same full-width rectangle the
            // user sees above the tab bar. Without an explicit width, SwiftUI can
            // expose only the inset's fitting-size container to VoiceOver: its
            // children remain reachable by swiping but may not be found when the
            // user explores their visible positions by touch (#840).
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(.regularMaterial)
            // Keep every transport button individually navigable while giving
            // the rendered bar—not the conditional safe-area wrapper—the named
            // accessibility-container frame (#490, #840).
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Now Playing")
            // Play-state ("Playing" / "Paused") is announced once at the RootView
            // TabView level, not here: this bar is inset into all five tabs (#366),
            // so a per-bar .onChange would announce up to five times per toggle.
        }
    }

    /// The title/show area, which doubles as the button that opens the expanded
    /// player controls (sleep timer + chapters).
    private func nowPlayingInfo(title: String) -> some View {
        Button {
            // Present from RootView's single stable sheet host. This bar is
            // recreated when its tab/safe-area inset refreshes; local @State
            // presentation can therefore disappear immediately during a
            // CloudKit or query-driven rebuild, especially on iOS-on-Mac.
            player.pendingFullPlayerPresentation = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: sleepTimerActive ? "moon.zzz.fill" : "waveform")
                    .font(.title3)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                        .lineLimit(2)
                        .foregroundStyle(.primary)
                    if let artist = player.currentArtist {
                        Text(artist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Combine the glyph + title + show name into one VoiceOver button. Keep
        // the button trait explicitly (combine can drop it) and only attach a
        // value when the sleep timer is on (an empty value reads as a pause).
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the full player")
        .modifier(OptionalAccessibilityValue(value: sleepTimerActive ? "Sleep timer on" : nil))
    }

    private var sleepTimerActive: Bool { player.sleepTimer.isActive }

    private var controls: some View {
        HStack(spacing: 12) {
            // Show "Extend +5" when a countdown sleep timer is running. Hidden in
            // end-of-episode mode (extending makes no sense there) and when no
            // timer is active, so it doesn't occupy permanent space in the bar.
            if sleepTimerActive && !player.sleepTimer.endOfEpisode {
                TransportButton(
                    systemImage: "plus.circle",
                    label: "Extend sleep timer by 5 minutes",
                    action: extendSleepTimer
                )
            }

            TransportButton(
                systemImage: "gobackward",
                label: "Skip back \(secondsPhrase(player.skipBackSeconds))",
                action: player.skipBack
            )

            // Dynamic VoiceOver name reflecting the action the button performs
            // ("Play" when paused, "Pause" when playing). No accessibilityValue —
            // the label carries the meaning, and the play-state transition is
            // announced once at the RootView level.
            TransportButton(
                systemImage: player.isPlaying ? "pause.fill" : "play.fill",
                label: player.isPlaying ? "Pause" : "Play",
                action: player.togglePlayPause
            )

            TransportButton(
                systemImage: "goforward",
                label: "Skip forward \(secondsPhrase(player.skipForwardSeconds))",
                action: player.skipForward
            )

            TransportButton(
                systemImage: "bookmark",
                label: "Add bookmark",
                action: addBookmark
            )
        }
    }

    private func extendSleepTimer() {
        player.sleepTimer.extend()
        Announcer.announce("Sleep timer extended by 5 minutes")
    }

    /// Pluralizes a seconds count so VoiceOver never reads "1 seconds".
    private func secondsPhrase(_ seconds: Int) -> String {
        "\(seconds) second\(seconds == 1 ? "" : "s")"
    }

    /// Saves a bookmark at the current playback position on the loaded episode.
    private func addBookmark() {
        guard let episode = player.nowPlayingEpisode else {
            Announcer.announce("No episode playing")
            return
        }
        let position = Int(player.currentPositionSeconds)
        BookmarkRepository(context: context).add(to: episode, positionSeconds: position)
        Announcer.announce("Bookmark added at \(BookmarkLogic.spoken(position))")
    }
}

/// Applies `.accessibilityValue` only when a value is present. An empty-string
/// value registers a node VoiceOver can announce as a pause, so we skip it.
private struct OptionalAccessibilityValue: ViewModifier {
    let value: String?

    func body(content: Content) -> some View {
        if let value {
            content.accessibilityValue(value)
        } else {
            content
        }
    }
}

/// A 44pt, dynamic-type-friendly transport button with an explicit label and a
/// decorative (hidden) glyph.
private struct TransportButton: View {
    let systemImage: String
    let label: String
    var value: String? = nil
    let action: () -> Void

    var body: some View {
        let button = Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityHidden(true)
        }
        .accessibilityLabel(label)

        // Only attach a value when one exists — applying `.accessibilityValue("")`
        // registers an empty value node that VoiceOver can announce as a pause.
        if let value {
            button.accessibilityValue(value)
        } else {
            button
        }
    }
}
