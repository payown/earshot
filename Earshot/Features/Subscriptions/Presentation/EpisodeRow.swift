import SwiftUI

/// A stable, non-configurable action appended by a particular episode surface.
/// Unlike ``QuickActionItem`` it carries no UUID or runnable closure, so it is
/// safe to create in a recycled row. The folder detail uses this for its final
/// destructive "Remove from folder" action.
struct EpisodeRowSupplementalAction: Identifiable, Equatable {
    let id: String
    let label: String
    let isDestructive: Bool
}

/// One episode row. The whole row is a single accessibility element: its
/// primary (double-tap) action is the first configured action, and every
/// configured action is exposed as a VoiceOver custom action (the Actions
/// rotor) in the user's order. Reordering in Settings changes this live — no
/// relaunch, because the rotor order is just the order we hand SwiftUI here.
///
/// Selection mode is NOT handled here anymore: episode multi-select (#758)
/// swaps this row out for the shared ``SelectableRow`` scaffold (via
/// ``EpisodeSelectableRow``), which reuses this row's visuals through
/// ``EpisodeRowContent`` but owns the checkbox, `.isSelected` trait, and toggle.
/// That keeps a single selection component across podcast and episode
/// multi-select instead of two divergent checkbox implementations.
struct EpisodeRow: View {
    @Environment(\.modelContext) private var context
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
    // Context menus are a sighted convenience. SwiftUI also promotes their
    // buttons into VoiceOver's Actions rotor, duplicating the explicit custom
    // actions below, so remove the menu while VoiceOver is running (#761).
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    let episode: Episode
    private let actions: [EpisodeAction]
    private let supplementalActions: [EpisodeRowSupplementalAction]
    private let performAction: (EpisodeAction) -> Void
    private let performSupplementalAction: (EpisodeRowSupplementalAction) -> Void
    /// Whether the row names its podcast, visually and in the VoiceOver label.
    /// True in mixed-show lists (Inbox, Downloads) where the user can't otherwise
    /// tell which show an episode belongs to (#535); false (default) in
    /// single-show lists (a podcast's episode list, the search preview) where
    /// repeating the show on every row is noise.
    var includesPodcastName = false

    /// Defers runnable Quick Action construction until activation. This keeps
    /// large lazy lists cheap to recycle while preserving the configured
    /// double-tap action, VoiceOver rotor, and sighted context menu.
    init(
        episode: Episode,
        deferredActions: [EpisodeAction],
        supplementalActions: [EpisodeRowSupplementalAction] = [],
        includesPodcastName: Bool = false,
        performAction: @escaping (EpisodeAction) -> Void,
        performSupplementalAction: @escaping (EpisodeRowSupplementalAction) -> Void = { _ in }
    ) {
        self.episode = episode
        self.actions = deferredActions
        self.supplementalActions = supplementalActions
        self.performAction = performAction
        self.performSupplementalAction = performSupplementalAction
        self.includesPodcastName = includesPodcastName
    }

    @ViewBuilder
    var body: some View {
        // A remote unfollow cascades through this episode while SwiftUI is
        // dismissing its podcast destination. VoiceOver can ask an outgoing row
        // for one final label during that transition. Deleted SwiftData models
        // trap when any persisted property is faulted, so remove the entire row
        // before constructing its label, visuals, or rotor actions.
        if episode.isDeleted {
            EmptyView()
        } else {
            let episodeID = episode.persistentModelID
            let presentations = EpisodeAction.presentations(actions, for: episode)
            let primary = presentations.first
            let base = rowButton(primaryLabel: primary?.label) {
                guard let primary,
                      PersistentModelLifetime.episodeExists(episodeID, in: context) else { return }
                performAction(primary.action)
            }
            .episodeActionsRotor(
                presentations,
                supplementalActions: supplementalActions,
                perform: { action in
                    guard PersistentModelLifetime.episodeExists(episodeID, in: context) else { return }
                    performAction(action)
                },
                performSupplemental: { action in
                    guard PersistentModelLifetime.episodeExists(episodeID, in: context) else { return }
                    performSupplementalAction(action)
                }
            )
            if voiceOverEnabled {
                base
            } else {
                base.episodeActionsContextMenu(
                    presentations,
                    supplementalActions: supplementalActions,
                    perform: { action in
                        guard PersistentModelLifetime.episodeExists(episodeID, in: context) else { return }
                        performAction(action)
                    },
                    performSupplemental: { action in
                        guard PersistentModelLifetime.episodeExists(episodeID, in: context) else { return }
                        performSupplementalAction(action)
                    }
                )
            }
        }
    }

    private func rowButton(
        primaryLabel: String?,
        runPrimary: @escaping () -> Void
    ) -> some View {
        Button {
            runPrimary()
        } label: {
            EpisodeRowContent(episode: episode, includesPodcastName: includesPodcastName)
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
        .accessibilityHint(primaryLabel.map { "Double tap to \($0.lowercased())" } ?? "")
    }

    private var isNowPlaying: Bool {
        player.nowPlayingEpisodeID == episode.persistentModelID
    }

    private var accessibilityLabel: String {
        guard !episode.isDeleted else { return "" }
        return EpisodeRowLabel.label(
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
            isNowPlaying: isNowPlaying,
            details: settings.episodeSpokenDetails
        )
    }

    /// The row's VoiceOver value: spoken time-left/length (#493) then a brief
    /// cached summary (#495), comma-joined. Empty when the episode is played with
    /// no description, so VoiceOver announces no stray value.
    private var accessibilityValue: String {
        guard voiceOverEnabled, !episode.isDeleted else { return "" }
        return EpisodeRowSpeech.value(for: episode, details: settings.episodeSpokenDetails)
    }
}

/// The visual body of an episode row — title, optional podcast name, and the
/// badge line (now-playing, season/episode number, played, time-left, date,
/// download state). No accessibility label, hint, or rotor of its own: it's a
/// pure presentation view shared by ``EpisodeRow`` (which wraps it in a Button
/// that owns the row's single accessibility element and Quick Actions rotor) and
/// ``EpisodeSelectableRow`` (which wraps it in the shared ``SelectableRow`` that
/// owns the checkbox and `.isSelected` trait). Every visible badge here is
/// `.accessibilityHidden(true)` because both wrappers speak the row's state
/// through one explicit label built from ``EpisodeRowLabel`` — this keeps the
/// visuals identical across normal and selection modes without duplicating the
/// spoken state.
struct EpisodeRowContent: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(PlayerService.self) private var player
    let episode: Episode
    var includesPodcastName = false

    var body: some View {
        if episode.isDeleted {
            EmptyView()
        } else {
            // In-progress rows show both "X min left" and the total duration
            // (#552); untouched rows keep the existing compact total length.
            // Cheap arithmetic, safe to evaluate per realization.
            let timeText = EpisodeTimeLogic.visibleText(
                positionSeconds: episode.positionSeconds,
                durationSeconds: episode.durationSeconds,
                isPlayed: episode.isPlayed
            )
            VStack(alignment: .leading, spacing: 4) {
            Text(episode.title)
                .font(.body)
                .multilineTextAlignment(.leading)
            // Podcast name in mixed-show lists, matching the Queue row's
            // caption treatment (#535). The wrapper's explicit accessibilityLabel
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
                // spoken state rides in the wrapper's single accessibilityLabel.
                if isNowPlaying {
                    Label("Now Playing", systemImage: "waveform")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }
                // Season/episode badge ("S2 · E14"), when the user has opted in
                // (off by default, #452) and the feed provides numbers. The row
                // is one accessibility element with an explicit label on the
                // wrapper, so this visible Text is not spoken separately.
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
                // Time-left plus total length / untouched total length. A played episode keeps just its
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
                // spoken state rides in the wrapper's single `accessibilityLabel`.
                DownloadStateBadge(status: episode.downloadStatus)
            }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// True when this row's episode is the one loaded in the player. Compared by
    /// persistent identity against the observed ``PlayerService/nowPlayingEpisodeID``
    /// so the row re-renders as the loaded episode changes (Item 2).
    private var isNowPlaying: Bool {
        player.nowPlayingEpisodeID == episode.persistentModelID
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
