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
                    label: "Skip back \(player.skipBackSeconds) seconds",
                    action: player.skipBack
                )

                TransportButton(
                    systemImage: player.isPlaying ? "pause.fill" : "play.fill",
                    label: player.isPlaying ? "Pause" : "Play",
                    action: player.togglePlayPause
                )

                TransportButton(
                    systemImage: "goforward",
                    label: "Skip forward \(player.skipForwardSeconds) seconds",
                    action: player.skipForward
                )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.regularMaterial)
        }
    }
}

/// A 44pt, dynamic-type-friendly transport button with an explicit label and a
/// decorative (hidden) glyph.
private struct TransportButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityHidden(true)
        }
        .accessibilityLabel(label)
    }
}
