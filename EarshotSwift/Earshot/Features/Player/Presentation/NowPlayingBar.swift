import SwiftUI

struct NowPlayingBar: View {
    @Environment(PlayerService.self) private var player

    var body: some View {
        if let title = player.currentTitle {
            HStack(spacing: 12) {
                Image(systemName: "waveform")
                    .accessibilityHidden(true)
                Text(title)
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer()
                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                }
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Now playing: \(title)")
        }
    }
}
