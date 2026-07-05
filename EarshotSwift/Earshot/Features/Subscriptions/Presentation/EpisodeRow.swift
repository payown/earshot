import SwiftUI

/// One episode row. The whole row is a single accessibility element: its
/// primary (double-tap) action is the first configured action, and every
/// configured action is exposed as a VoiceOver custom action (the Actions
/// rotor) in the user's order. Reordering in Settings changes this live — no
/// relaunch, because the rotor order is just the order we hand SwiftUI here.
struct EpisodeRow: View {
    // Requires SettingsStore in the environment (injected at the app root in
    // EarshotApp). All current call sites render under that root; any future
    // #Preview or detached host must supply `.environment(SettingsStore())` or
    // this row traps at runtime (#452 gate note).
    @Environment(SettingsStore.self) private var settings
    // The now-playing identity is observed, so the row re-renders when the loaded
    // episode changes and this row's badge/label update (Item 2). Same runtime
    // requirement as SettingsStore above: every call site renders under the app
    // root that injects PlayerService.
    @Environment(PlayerService.self) private var player
    let episode: Episode
    let actions: [EpisodeActionItem]
    /// Whether the row names its podcast, visually and in the VoiceOver label.
    /// True in mixed-show lists (Inbox, Downloads) where the user can't otherwise
    /// tell which show an episode belongs to (#535); false (default) in
    /// single-show lists (a podcast's episode list, the search preview) where
    /// repeating the show on every row is noise.
    var includesPodcastName = false
    /// Non-nil switches the row into checkbox mode for bulk selection (Inbox
    /// multi-select, #595): the row's tap toggles selection instead of running
    /// the primary Quick Action, and the rotor is suppressed since there is
    /// nothing left to run per-row while selecting.
    var selection: SelectionState?

    /// Checkbox state and toggle handler for a row in selection mode.
    struct SelectionState {
        let isSelected: Bool
        let toggle: () -> Void
    }

    var body: some View {
        let primary = actions.first
        // Castro-style "X min left" / total length, computed purely from stored
        // progress (#493). Cheap arithmetic, safe to evaluate per realization.
        let timeText = EpisodeTimeLogic.visibleText(
            positionSeconds: episode.positionSeconds,
            durationSeconds: episode.durationSeconds,
            isPlayed: episode.isPlayed
        )

        let row = Button {
            if let selection {
                selection.toggle()
            } else {
                primary?.run()
            }
        } label: {
            HStack(spacing: 8) {
                content(timeText: timeText)
                if let selection {
                    Spacer(minLength: 8)
                    // Checkmark is a second, non-color signal alongside the
                    // `.isToggle`/`.isSelected` traits below; hidden from
                    // VoiceOver since the row's single accessibility element
                    // already speaks selection state.
                    Image(systemName: selection.isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selection.isSelected ? Color.accentColor : .secondary)
                        .accessibilityHidden(true)
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

        // Selection mode replaces the hint/rotor with checkbox semantics: no
        // manual announcement is made anywhere in this row, since `.isToggle`
        // makes VoiceOver speak the selected/unselected transition itself on
        // activation (same rule as `FolderPodcastPickerView`'s membership
        // checkboxes) — a second spoken string here would talk over it.
        if let selection {
            row
                .accessibilityHint(selection.isSelected ? "Removes from selection" : "Adds to selection")
                .accessibilityAddTraits(selection.isSelected ? [.isToggle, .isSelected] : [.isToggle])
        } else {
            row
                .accessibilityHint(primary.map { "Double tap to \($0.label.lowercased())" } ?? "")
                // Rotor order goes through the shared helper, which compensates
                // for the OS emitting `.accessibilityActions` children in
                // reverse (#572). The default double-tap and hint above keep
                // the UN-reversed `actions.first`.
                .quickActionsRotor(actions)
        }
    }

    /// The row's visual content (title, podcast name, badges), shared by
    /// normal and selection-mode rendering.
    @ViewBuilder
    private func content(timeText: String?) -> some View {
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
                // Now-playing indicator (Item 2): icon + text, accent-tinted,
                // never colour alone. Leads the badge row so it reads first
                // visually, matching the "Now Playing" prefix VoiceOver speaks.
                // Hidden from VoiceOver here — the row is one element and the
                // spoken state rides in this row's single accessibilityLabel.
                if isNowPlaying {
                    Label("Now Playing", systemImage: "waveform")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }
                // Season/episode badge ("S2 · E14"), when the user has opted in
                // (off by default, #452) and the feed provides numbers. The row
                // is one accessibility element with an explicit label below, so
                // this visible Text is not spoken separately — the spoken form is
                // folded into `accessibilityLabel`.
                if settings.showEpisodeNumbers,
                   let numberBadge = EpisodeRowLabel.numberBadge(
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
                // Downloaded / streaming indicator (#513): icon + short text so
                // the user can tell before choosing Play whether audio is local
                // or will stream. Hidden from VoiceOver inside the badge — the
                // spoken state rides in this row's single `accessibilityLabel`.
                DownloadStateBadge(status: episode.downloadStatus)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// True when this row's episode is the one loaded in the player. Compared by
    /// persistent identity against the observed ``PlayerService/nowPlayingEpisodeID``
    /// so the row re-renders as the loaded episode changes (Item 2).
    private var isNowPlaying: Bool {
        player.nowPlayingEpisodeID == episode.persistentModelID
    }

    private var accessibilityLabel: String {
        EpisodeRowLabel.label(
            episodeTitle: episode.title,
            podcastName: includesPodcastName ? episode.podcast?.title : nil,
            // Numbering is spoken only when the user has opted in (#452); pass nil
            // when off so `label` omits it entirely.
            seasonNumber: settings.showEpisodeNumbers ? episode.seasonNumber : nil,
            episodeNumber: settings.showEpisodeNumbers ? episode.episodeNumber : nil,
            isPlayed: episode.isPlayed,
            pubDate: episode.pubDate,
            // Fold the downloaded / streaming state into the same single row label
            // so VoiceOver announces it as part of this one element, not a new
            // stop (#513).
            downloadState: episode.downloadStatus,
            // "Now Playing" leads the spoken label (Item 2).
            isNowPlaying: isNowPlaying
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
