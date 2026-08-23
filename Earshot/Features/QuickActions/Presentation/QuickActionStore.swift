import Foundation
import Observation
import SwiftData

/// Holds the user's configured Quick Action order for all three content sets
/// (episode, podcast, queue), persisted in ``QuickActionConfig`` via
/// ``QuickActionRepository``. Mutating an order updates every row's VoiceOver
/// rotor live — no relaunch. Serves defaults until ``configure(context:)`` runs.
@MainActor
@Observable
final class QuickActionStore {
    private(set) var episodeActions: [EpisodeAction] = defaultEpisodeActions
    private(set) var availableEpisodeActions: [EpisodeAction] = []
    private(set) var podcastActions: [PodcastAction] = defaultPodcastActions
    private(set) var availablePodcastActions: [PodcastAction] = []
    private(set) var queueActions: [QueueItemAction] = defaultQueueItemActions
    private(set) var availableQueueActions: [QueueItemAction] = []

    @ObservationIgnored private var context: ModelContext?

    /// Wires persistence and loads the saved order. Call once at startup with the
    /// shared container's `mainContext` (not from a view body).
    func configure(context: ModelContext) {
        self.context = context
        let repo = QuickActionRepository(context: context)
        let episode = repo.episodeConfiguration()
        episodeActions = episode.enabled
        availableEpisodeActions = episode.available
        let podcast = repo.podcastConfiguration()
        podcastActions = podcast.enabled
        availablePodcastActions = podcast.available
        let queue = repo.queueConfiguration()
        queueActions = queue.enabled
        availableQueueActions = queue.available
    }

    func releasePersistence() { context = nil }

    func moveEpisodeActions(from: IndexSet, to: Int) {
        episodeActions.move(fromOffsets: from, toOffset: to)
        persistEpisodeActions()
    }

    func moveAvailableEpisodeActions(from: IndexSet, to: Int) {
        availableEpisodeActions.move(fromOffsets: from, toOffset: to)
        persistEpisodeActions()
    }

    @discardableResult
    func removeEpisodeAction(_ action: EpisodeAction) -> Bool {
        guard episodeActions.count > 1,
              let index = episodeActions.firstIndex(of: action) else { return false }
        availableEpisodeActions.append(episodeActions.remove(at: index))
        persistEpisodeActions()
        return true
    }

    func addEpisodeAction(_ action: EpisodeAction) {
        guard let index = availableEpisodeActions.firstIndex(of: action) else { return }
        episodeActions.append(availableEpisodeActions.remove(at: index))
        persistEpisodeActions()
    }

    func movePodcastActions(from: IndexSet, to: Int) {
        podcastActions.move(fromOffsets: from, toOffset: to)
        persistPodcastActions()
    }

    func moveAvailablePodcastActions(from: IndexSet, to: Int) {
        availablePodcastActions.move(fromOffsets: from, toOffset: to)
        persistPodcastActions()
    }

    @discardableResult
    func removePodcastAction(_ action: PodcastAction) -> Bool {
        guard podcastActions.count > 1,
              let index = podcastActions.firstIndex(of: action) else { return false }
        availablePodcastActions.append(podcastActions.remove(at: index))
        persistPodcastActions()
        return true
    }

    func addPodcastAction(_ action: PodcastAction) {
        guard let index = availablePodcastActions.firstIndex(of: action) else { return }
        podcastActions.append(availablePodcastActions.remove(at: index))
        persistPodcastActions()
    }

    func moveQueueActions(from: IndexSet, to: Int) {
        queueActions.move(fromOffsets: from, toOffset: to)
        persistQueueActions()
    }

    func moveAvailableQueueActions(from: IndexSet, to: Int) {
        availableQueueActions.move(fromOffsets: from, toOffset: to)
        persistQueueActions()
    }

    @discardableResult
    func removeQueueAction(_ action: QueueItemAction) -> Bool {
        guard queueActions.count > 1,
              let index = queueActions.firstIndex(of: action) else { return false }
        availableQueueActions.append(queueActions.remove(at: index))
        persistQueueActions()
        return true
    }

    func addQueueAction(_ action: QueueItemAction) {
        guard let index = availableQueueActions.firstIndex(of: action) else { return }
        queueActions.append(availableQueueActions.remove(at: index))
        persistQueueActions()
    }

    private func persistEpisodeActions() {
        repo?.setEpisodeConfiguration(QuickActionConfiguration(
            enabled: episodeActions,
            available: availableEpisodeActions
        ))
    }

    private func persistPodcastActions() {
        repo?.setPodcastConfiguration(QuickActionConfiguration(
            enabled: podcastActions,
            available: availablePodcastActions
        ))
    }

    private func persistQueueActions() {
        repo?.setQueueConfiguration(QuickActionConfiguration(
            enabled: queueActions,
            available: availableQueueActions
        ))
    }

    private var repo: QuickActionRepository? {
        context.map(QuickActionRepository.init)
    }
}
