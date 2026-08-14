import SwiftUI

/// An episode row rendered in selection mode (episode multi-select, #758). It's
/// the episode analog of the podcast selectable row: it reuses the shared
/// ``SelectableRow`` scaffold — a leading checkmark plus the caller's visuals as
/// one VoiceOver element that toggles selection on activation — and feeds it the
/// exact same visuals a normal ``EpisodeRow`` shows via ``EpisodeRowContent``.
///
/// The spoken name is built from the shared ``EpisodeRowLabel`` so it matches the
/// normal row's label verbatim; ``SelectableRow`` appends the selection story via
/// the `.isSelected` trait (never `.isToggle`, and never the word "Selected" in
/// the label), satisfying the #758 accessibility contract with a single selection
/// component shared with podcast multi-select.
struct EpisodeSelectableRow: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(PlayerService.self) private var player
    let episode: Episode
    /// Mirrors ``EpisodeRow/includesPodcastName``: true in mixed-show lists
    /// (Inbox) so the spoken label names the show, false in single-show lists
    /// (a podcast's episode list).
    var includesPodcastName = false
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        if episode.isDeleted {
            EmptyView()
        } else {
            SelectableRow(
                isSelected: isSelected,
                accessibilityLabel: accessibilityLabel,
                onToggle: onToggle
            ) {
                EpisodeRowContent(episode: episode, includesPodcastName: includesPodcastName)
            }
        }
    }

    private var isNowPlaying: Bool {
        player.nowPlayingEpisodeID == episode.persistentModelID
    }

    /// The identical spoken name the normal ``EpisodeRow`` builds, so a row reads
    /// the same whether or not selection mode is on — only the checkmark and the
    /// `.isSelected` trait change.
    private var accessibilityLabel: String {
        guard !episode.isDeleted else { return "" }
        return EpisodeRowLabel.label(
            episodeTitle: episode.title,
            podcastName: includesPodcastName ? episode.podcast?.title : nil,
            seasonNumber: settings.showEpisodeNumbers ? episode.seasonNumber : nil,
            episodeNumber: settings.showEpisodeNumbers ? episode.episodeNumber : nil,
            isPlayed: episode.isPlayed,
            pubDate: episode.pubDate,
            downloadState: episode.downloadStatus,
            isNowPlaying: isNowPlaying
        )
    }
}

/// Pure, testable copy for the episode-only batch actions the multi-select bar
/// offers alongside the folder actions (#758): "Add to queue" and "Mark as
/// played". The folder actions reuse the noun-agnostic ``MultiSelectActionLabel``;
/// these two are episode-specific, so they live here rather than muddying that
/// shared folder label. Each carries the live selection count and is the
/// accessibility source of truth for that button's count.
enum EpisodeBatchLabel {
    /// "1 episode" / "3 episodes" — simple English pluralization, matching
    /// ``MultiSelectActionLabel/itemPhrase(_:singular:)``.
    static func episodePhrase(_ count: Int) -> String {
        "\(count) episode\(count == 1 ? "" : "s")"
    }

    /// "Add 3 episodes to queue" (or "Add to queue" when nothing is selected —
    /// the button is disabled there, but its name still reads cleanly).
    static func addToQueue(count: Int) -> String {
        count == 0 ? "Add to queue" : "Add \(episodePhrase(count)) to queue"
    }

    /// "Mark 3 episodes as played".
    static func markPlayed(count: Int) -> String {
        count == 0 ? "Mark as played" : "Mark \(episodePhrase(count)) as played"
    }
}
