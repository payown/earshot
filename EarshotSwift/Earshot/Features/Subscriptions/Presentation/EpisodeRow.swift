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
        // Castro-style "X min left" / total length, computed purely from stored
        // progress (#493). Cheap arithmetic, safe to evaluate per realization.
        let timeText = EpisodeTimeLogic.visibleText(
            positionSeconds: episode.positionSeconds,
            durationSeconds: episode.durationSeconds,
            isPlayed: episode.isPlayed
        )

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
                    // Time-left / total length. A played episode keeps just its
                    // Played treatment (timeText is nil); an unknown-duration
                    // episode shows no time artifact (#493).
                    if let timeText {
                        Text(timeText)
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
        // A Button is already a single accessibility element with the button
        // trait, so no `.accessibilityElement(children: .combine)` is needed here.
        // Combining made VoiceOver re-walk and merge the whole label subtree on
        // every row realization, only for the explicit `.accessibilityLabel`
        // below to discard the merged result — wasted work on every focus move.
        // Dropping it keeps the identical label/hint/actions while removing that
        // per-row cost. (#479)
        .accessibilityLabel(accessibilityLabel)
        // VoiceOver value carries the spoken time-left/length (#493) followed by
        // a brief, length-capped summary (#495), in that order. The label stays
        // title-first so quick flicking still leads with the title; the value is
        // where a user who dwells hears the useful detail without it bloating the
        // label. The summary is served from a per-episode cache so the HTML strip
        // never runs in this body on a focus move (#495).
        //
        // Applied only when there's something to say: a played episode with no
        // description yields an empty value, and `.accessibilityValue("")` makes
        // VoiceOver speak a stray pause (dead air), so we omit it in that case.
        .accessibilityValueIfPresent(accessibilityValue)
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
        if let date = episode.pubDate {
            parts.append(date.formatted(date: .abbreviated, time: .omitted))
        }
        return parts.joined(separator: ", ")
    }

    /// The row's VoiceOver value: spoken time-left/length (#493) then a brief
    /// cached summary (#495), comma-joined. Empty when the episode is played with
    /// no description, so VoiceOver announces no stray value.
    private var accessibilityValue: String {
        var parts: [String] = []
        if let time = EpisodeTimeLogic.spokenText(
            positionSeconds: episode.positionSeconds,
            durationSeconds: episode.durationSeconds,
            isPlayed: episode.isPlayed
        ) {
            parts.append(time)
        }
        if let summary = EpisodeSummaryCache.shared.summary(for: episode) {
            parts.append(summary)
        }
        return parts.joined(separator: ", ")
    }
}

private extension View {
    /// Applies `.accessibilityValue` only when there's something to say. An empty
    /// value string makes VoiceOver speak a stray pause (dead air), so callers
    /// with no value to communicate must omit the modifier entirely rather than
    /// set "".
    @ViewBuilder
    func accessibilityValueIfPresent(_ value: String) -> some View {
        if value.isEmpty {
            self
        } else {
            accessibilityValue(value)
        }
    }
}
