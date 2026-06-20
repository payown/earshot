import SwiftUI

/// Compact transport bar pinned above the tab bar. Shows what's loaded and
/// exposes skip-back, play/pause, and skip-forward. Purely presentational — all
/// behavior delegates to ``PlayerService``.
struct NowPlayingBar: View {
    @Environment(PlayerService.self) private var player

    var body: some View {
        if let title = player.currentTitle {
            HStack(spacing: 12) {
                Image(systemName: "waveform")
                    .font(.title3)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                        .lineLimit(2)
                    if let artist = player.currentArtist {
                        Text(artist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                // Combine the title + show name into one VoiceOver label so the
                // controls that follow read as distinct, actionable elements.
                .accessibilityElement(children: .combine)

                Spacer(minLength: 8)

                TransportButton(
                    systemImage: "gobackward",
                    label: "Skip back \(secondsPhrase(player.skipBackSeconds))",
                    action: player.skipBack
                )

                // Stable VoiceOver name ("Play or pause") with the live state
                // carried by the value, rather than flipping the label. A stable
                // name keeps the control predictable for screen-reader and Voice
                // Control users; the value (and the announcement below) convey state.
                TransportButton(
                    systemImage: player.isPlaying ? "pause.fill" : "play.fill",
                    label: "Play or pause",
                    value: player.isPlaying ? "Playing" : "Paused",
                    action: player.togglePlayPause
                )

                TransportButton(
                    systemImage: "goforward",
                    label: "Skip forward \(secondsPhrase(player.skipForwardSeconds))",
                    action: player.skipForward
                )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.regularMaterial)
            // The value change alone isn't reliably re-spoken on a custom button,
            // so announce play-state transitions explicitly (Announcer no-ops when
            // VoiceOver is off). This is the single source for the announcement.
            .onChange(of: player.isPlaying) { _, isPlaying in
                Announcer.announce(isPlaying ? "Playing" : "Paused")
            }
        }
    }

    /// Pluralizes a seconds count so VoiceOver never reads "1 seconds".
    private func secondsPhrase(_ seconds: Int) -> String {
        "\(seconds) second\(seconds == 1 ? "" : "s")"
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
