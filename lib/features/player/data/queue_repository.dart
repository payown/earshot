import '../../subscriptions/domain/episode.dart';

abstract interface class QueueRepository {
  Future<void> addToQueue(int episodeId);

  Future<void> removeFromQueue(int episodeId);

  Future<void> moveToTop(int episodeId);

  Future<void> reorder(int episodeId, int newPosition);

  Stream<List<Episode>> watchQueue();

  Future<void> clearQueue();
}
