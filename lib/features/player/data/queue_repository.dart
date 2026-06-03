import '../../subscriptions/domain/episode.dart';

abstract interface class QueueRepository {
  Future<void> addToQueue(int episodeId);

  // Inserts after the currently playing item (position 1). If the episode is
  // already in the queue, moves it there instead.
  Future<void> addAfterCurrent(int episodeId);

  // Internal removal used by auto-advance. Does NOT revert episode status.
  Future<void> removeFromQueue(int episodeId);

  // User-initiated removal. Reverts episode status to newEpisode so it
  // reappears in the inbox.
  Future<void> cancelFromQueue(int episodeId);

  Future<void> moveToTop(int episodeId);

  Future<void> moveToBottom(int episodeId);

  Future<void> moveUp(int episodeId);

  Future<void> moveDown(int episodeId);

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

  Stream<List<Episode>> watchQueue();

  Future<void> clearQueue();
}
