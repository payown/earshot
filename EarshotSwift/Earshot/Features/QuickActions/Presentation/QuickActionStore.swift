import Foundation
import Observation
import SwiftData

/// Holds the user's configured Quick Action order AND per-action visibility for
/// all three content sets (episode, podcast, queue), persisted in
/// ``QuickActionConfig`` via ``QuickActionRepository``. Mutating order or
/// visibility updates every row's VoiceOver rotor live — no relaunch. Serves
/// defaults until ``configure(context:)`` runs.
///
/// The full ordered arrays (`episodeActions`, …) keep every action, including
/// hidden ones, so the settings screen can list and restore them. The
/// `visible…Actions` arrays are the rotor/default-tap surface: content rows use
/// those so hidden actions disappear from the real rotor (#524).
@MainActor
@Observable
final class QuickActionStore {
    private(set) var episodeActions: [EpisodeAction] = defaultEpisodeActions
    private(set) var podcastActions: [PodcastAction] = defaultPodcastActions
    private(set) var queueActions: [QueueItemAction] = defaultQueueItemActions

    private(set) var hiddenEpisodeKeys: Set<String> = []
    private(set) var hiddenPodcastKeys: Set<String> = []
    private(set) var hiddenQueueKeys: Set<String> = []

    @ObservationIgnored private var context: ModelContext?

    /// Wires persistence and loads the saved order + visibility. Call once at
    /// startup with the shared container's `mainContext` (not from a view body).
    func configure(context: ModelContext) {
        self.context = context
        let repo = QuickActionRepository(context: context)
        episodeActions = repo.episodeOrder()
        podcastActions = repo.podcastOrder()
        queueActions = repo.queueOrder()
        hiddenEpisodeKeys = repo.episodeHidden()
        hiddenPodcastKeys = repo.podcastHidden()
        hiddenQueueKeys = repo.queueHidden()
    }

    // MARK: Rotor surfaces (enabled actions only, in order)

    var visibleEpisodeActions: [EpisodeAction] {
        episodeActions.filter { !hiddenEpisodeKeys.contains($0.rawValue) }
    }
    var visiblePodcastActions: [PodcastAction] {
        podcastActions.filter { !hiddenPodcastKeys.contains($0.rawValue) }
    }
    var visibleQueueActions: [QueueItemAction] {
        queueActions.filter { !hiddenQueueKeys.contains($0.rawValue) }
    }

    // MARK: Visibility queries

    func isEpisodeActionHidden(_ action: EpisodeAction) -> Bool { hiddenEpisodeKeys.contains(action.rawValue) }
    func isPodcastActionHidden(_ action: PodcastAction) -> Bool { hiddenPodcastKeys.contains(action.rawValue) }
    func isQueueActionHidden(_ action: QueueItemAction) -> Bool { hiddenQueueKeys.contains(action.rawValue) }

    // MARK: Reorder

    func moveEpisodeActions(from: IndexSet, to: Int) {
        episodeActions.move(fromOffsets: from, toOffset: to)
        repo?.setEpisode(order: episodeActions, hidden: hiddenEpisodeKeys)
    }

    func movePodcastActions(from: IndexSet, to: Int) {
        podcastActions.move(fromOffsets: from, toOffset: to)
        repo?.setPodcast(order: podcastActions, hidden: hiddenPodcastKeys)
    }

    func moveQueueActions(from: IndexSet, to: Int) {
        queueActions.move(fromOffsets: from, toOffset: to)
        repo?.setQueue(order: queueActions, hidden: hiddenQueueKeys)
    }

    // MARK: Hide / restore
    //
    // Each returns `false` (and changes nothing) when the request is refused —
    // the only refusal is hiding the last remaining visible action in a set, so
    // there is always at least one enabled action / default double-tap.

    @discardableResult
    func setEpisodeActionHidden(_ action: EpisodeAction, hidden: Bool) -> Bool {
        guard applyHidden(
            hidden, key: action.rawValue,
            ordered: episodeActions.map(\.rawValue), into: &hiddenEpisodeKeys
        ) else { return false }
        repo?.setEpisode(order: episodeActions, hidden: hiddenEpisodeKeys)
        return true
    }

    @discardableResult
    func setPodcastActionHidden(_ action: PodcastAction, hidden: Bool) -> Bool {
        guard applyHidden(
            hidden, key: action.rawValue,
            ordered: podcastActions.map(\.rawValue), into: &hiddenPodcastKeys
        ) else { return false }
        repo?.setPodcast(order: podcastActions, hidden: hiddenPodcastKeys)
        return true
    }

    @discardableResult
    func setQueueActionHidden(_ action: QueueItemAction, hidden: Bool) -> Bool {
        guard applyHidden(
            hidden, key: action.rawValue,
            ordered: queueActions.map(\.rawValue), into: &hiddenQueueKeys
        ) else { return false }
        repo?.setQueue(order: queueActions, hidden: hiddenQueueKeys)
        return true
    }

    /// Applies a hide/show to `hiddenSet` in memory, enforcing the "keep at least
    /// one visible" guard. Returns whether the set changed.
    private func applyHidden(
        _ hidden: Bool, key: String, ordered: [String], into hiddenSet: inout Set<String>
    ) -> Bool {
        if hidden {
            guard QuickActionVisibilityLogic.canHide(key, ordered: ordered, hidden: hiddenSet) else { return false }
            hiddenSet.insert(key)
        } else {
            guard hiddenSet.contains(key) else { return false }
            hiddenSet.remove(key)
        }
        return true
    }

    private var repo: QuickActionRepository? {
        context.map(QuickActionRepository.init)
    }
}
