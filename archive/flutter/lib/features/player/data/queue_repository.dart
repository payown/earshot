import '../../subscriptions/domain/episode.dart';

abstract interface class QueueRepository {
  Future<void> addToQueue(int episodeId);

  // Inserts at the front of the queue if the episode isn't already queued; if it
  // is, leaves it where it sits (its order is preserved). Used by "Play now" so
  // a brand-new episode plays and then flows into the existing queue, while a
  // tap on an already-queued episode plays it in place.
  Future<void> addToFrontIfAbsent(int episodeId);

  // Inserts after the currently playing item (position 1). If the episode is
  // already in the queue, moves it there instead.
  Future<void> addAfterCurrent(int episodeId);

  // Internal removal that does NOT change episode status. Callers must set
  // status themselves first, or the episode is stranded at inQueue and shows
  // in neither the queue nor the inbox. Completion-driven removal should use
  // markPlayedAndRemove instead.
  Future<void> removeFromQueue(int episodeId);

  // Removal after genuine playback completion: removes the queue row and
  // marks the episode played atomically, so it can never be stranded in the
  // inQueue-but-not-in-queue ghost state. Intentionally does NOT reset
  // positionSeconds — PositionTracker owns position-zeroing (guarded by its
  // near-end check), so a spurious/racing completion can never destroy a
  // listener's saved place here.
  Future<void> markPlayedAndRemove(int episodeId);

  // User-initiated removal. Reverts episode status to newEpisode so it
  // reappears in the inbox.
  Future<void> cancelFromQueue(int episodeId);

  Future<void> moveToTop(int episodeId);

  Future<void> moveToBottom(int episodeId);

  Future<void> moveUp(int episodeId);

  Future<void> moveDown(int episodeId);

  // Group-aware variants of moveUp/moveDown for the "Group by podcast" Queue
  // view. Swap with the adjacent episode within the same podcast's group
  // (by global position order), not the adjacent episode in the global flat
  // queue. No-op if the episode is already first/last within its group.
  Future<void> moveUpInGroup(int episodeId, int podcastId);

  Future<void> moveDownInGroup(int episodeId, int podcastId);

  Future<void> reorder(int episodeId, int newPosition);

  // Reorders a subset of queue items in-place. Each episode in
  // [episodeIdsInOrder] is assigned to the slot (position) that its
  // counterpart currently occupies, preserving every other episode's position.
  Future<void> sortGroup(List<int> episodeIdsInOrder);

  // Moves the given episodes to the front of the queue (positions 0..N-1) in
  // the specified order, then appends all remaining episodes in their original
  // relative order. Used by "Play group" so auto-advance stays within the
  // group before continuing with other queue items.
  Future<void> bringGroupToFront(List<int> episodeIdsInOrder);

  // Mirror image of bringGroupToFront: moves the given episodes to the end of
  // the queue in the specified order, preserving the relative order of all
  // other episodes ahead of them.
  Future<void> bringGroupToBack(List<int> episodeIdsInOrder);

  // Group-level reorder for the "Group by podcast" Queue view. Swaps the
  // entire group's queue positions with those of the group immediately
  // above/below it in groupedQueueProvider's display order (group order is
  // determined by each group's first episode's position in the flat queue).
  // No-op if the group is already first/last.
  Future<void> moveGroupUp(int podcastId);

  Future<void> moveGroupDown(int podcastId);

  Stream<List<Episode>> watchQueue();

  Future<void> clearQueue();
}
