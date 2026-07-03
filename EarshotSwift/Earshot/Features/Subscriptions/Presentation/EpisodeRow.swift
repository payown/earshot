import SwiftUI

/// One episode row. The whole row is a single accessibility element: its
/// primary (double-tap) action is the first configured action, and every
/// configured action is exposed as a VoiceOver custom action (the Actions
/// rotor) in the user's order. Reordering in Settings changes this live — no
/// relaunch, because the rotor order is just the order we hand SwiftUI here.
struct EpisodeRow: View {
    let episode: Episode
    let actions: [EpisodeActionItem]
    /// Whether the row names its podcast, visually and in the VoiceOver label.
    /// True in mixed-show lists (Inbox, Downloads) where the user can't otherwise
    /// tell which show an episode belongs to (#535); false (default) in
    /// single-show lists (a podcast's episode list, the search preview) where
    /// repeating the show on every row is noise.
    var includesPodcastName = false

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
                // Podcast name in mixed-show lists, matching the Queue row's
                // caption treatment (#535). The explicit accessibilityLabel below
                // already carries it for VoiceOver.
                if includesPodcastName, let podcast = episode.podcast?.title,
                   !podcast.isEmpty {
                    Text(podcast)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                HStack(spacing: 8) {
                    // Season/episode badge ("S2 · E14"), when the feed provides
                    // numbers. The row is one accessibility element with an explicit
                    // label below, so this visible Text is not spoken separately —
                    // the spoken form is folded into `accessibilityLabel` (#452).
                    if let numberBadge = EpisodeRowLabel.numberBadge(
                        season: episode.seasonNumber, episode: episode.episodeNumber
                    ) {
                        Text(numberBadge)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
        EpisodeRowLabel.label(
            episodeTitle: episode.title,
            podcastName: includesPodcastName ? episode.podcast?.title : nil,
            seasonNumber: episode.seasonNumber,
            episodeNumber: episode.episodeNumber,
            isPlayed: episode.isPlayed,
            pubDate: episode.pubDate
        )
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
