import SwiftUI

/// One episode row. The whole row is a single accessibility element: its
/// primary (double-tap) action is the first configured action, and every
/// configured action is exposed as a VoiceOver custom action (the Actions
/// rotor) in the user's order. Reordering in Settings changes this live — no
/// relaunch, because the rotor order is just the order we hand SwiftUI here.
struct EpisodeRow: View {
    let episode: Episode
    let actions: [EpisodeActionItem]

    var body: some View {
        let primary = actions.first

        Button {
            primary?.run()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(episode.title)
                    .font(.body)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 8) {
                    if episode.isPlayed {
                        Label("Played", systemImage: "checkmark.circle.fill")
                            .labelStyle(.titleAndIcon)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let date = episode.pubDate {
                        Text(date, style: .date)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(primary.map { "Double tap to \($0.label.lowercased())" } ?? "")
        .accessibilityActions {
            ForEach(actions) { action in
                Button(action.label) { action.run() }
            }
        }
    }

    private var accessibilityLabel: String {
        var parts = [episode.title]
        if episode.isPlayed { parts.append("Played") }
        return parts.joined(separator: ", ")
    }
}
