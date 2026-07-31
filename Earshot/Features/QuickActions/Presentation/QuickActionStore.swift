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
    private(set) var podcastActions: [PodcastAction] = defaultPodcastActions
    private(set) var queueActions: [QueueItemAction] = defaultQueueItemActions

    @ObservationIgnored private var context: ModelContext?

    /// Wires persistence and loads the saved order. Call once at startup with the
    /// shared container's `mainContext` (not from a view body).
    func configure(context: ModelContext) {
        self.context = context
        let repo = QuickActionRepository(context: context)
        episodeActions = repo.episodeOrder()
        podcastActions = repo.podcastOrder()
        queueActions = repo.queueOrder()
    }

    func moveEpisodeActions(from: IndexSet, to: Int) {
        episodeActions.move(fromOffsets: from, toOffset: to)
        repo?.setEpisodeOrder(episodeActions)
    }

    func movePodcastActions(from: IndexSet, to: Int) {
        podcastActions.move(fromOffsets: from, toOffset: to)
        repo?.setPodcastOrder(podcastActions)
    }

    func moveQueueActions(from: IndexSet, to: Int) {
        queueActions.move(fromOffsets: from, toOffset: to)
        repo?.setQueueOrder(queueActions)
    }

    private var repo: QuickActionRepository? {
        context.map(QuickActionRepository.init)
    }
}
