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
            .background(.regularMaterial)
            // The value change alone isn't reliably re-spoken on a custom button,
            // so announce play-state transitions explicitly (Announcer no-ops when
            // VoiceOver is off). This is the single source for the announcement.
            .onChange(of: player.isPlaying) { _, isPlaying in
                Announcer.announce(isPlaying ? "Playing" : "Paused")
            }
        }
    }

    private func nowPlayingInfo(title: String) -> some View {
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
        }
        // Combine the waveform + title + show name into one VoiceOver label so the
        // controls that follow read as distinct, actionable elements.
        .accessibilityElement(children: .combine)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            TransportButton(
                systemImage: "gobackward",
                label: "Skip back \(secondsPhrase(player.skipBackSeconds))",
                action: player.skipBack
            )

            // Stable VoiceOver name ("Play or pause") with the live state carried
            // by the value, rather than flipping the label. A stable name keeps the
            // control predictable for screen-reader and Voice Control users; the
            // value (and the announcement above) convey state.
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

            TransportButton(
                systemImage: "bookmark",
                label: "Add bookmark",
                action: addBookmark
            )
        }
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
