import '../../subscriptions/domain/episode.dart';

abstract interface class QueueRepository {
  Future<void> addToQueue(int episodeId);

  // Internal removal used by auto-advance. Does NOT revert episode status.
  Future<void> removeFromQueue(int episodeId);

  // User-initiated removal. Reverts episode status to newEpisode so it
  // reappears in the inbox.
  Future<void> cancelFromQueue(int episodeId);

  Future<void> moveToTop(int episodeId);

  Future<void> reorder(int episodeId, int newPosition);

  Stream<List<Episode>> watchQueue();

  Future<void> clearQueue();
}
