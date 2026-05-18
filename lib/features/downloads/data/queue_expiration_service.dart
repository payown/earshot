import 'package:drift/drift.dart';
import 'package:logging/logging.dart';

import '../../../data/db/app_database.dart';

final _log = Logger('QueueExpirationService');

class QueueExpirationService {
  const QueueExpirationService({required AppDatabase database})
    : _db = database;

  final AppDatabase _db;

  static const _recentlyExpiredRetentionDays = 7;

  Future<void> runExpiration() async {
    await _expireStaleQueueItems();
    await _cleanupOldRecentlyExpired();
  }

  Future<void> restoreFromExpired(int episodeId) async {
    await _db.transaction(() async {
      await (_db.delete(
        _db.recentlyExpired,
      )..where((r) => r.episodeId.equals(episodeId))).go();

      final maxPosition = await _maxQueuePosition();
      await _db
          .into(_db.queueItems)
          .insertOnConflictUpdate(
            QueueItemsCompanion.insert(
              episodeId: episodeId,
              position: maxPosition + 1,
            ),
          );
    });
    _log.info('Restored episode $episodeId from recently expired');
  }

  Stream<List<RecentlyExpiredRow>> watchRecentlyExpired() {
    return (_db.select(
      _db.recentlyExpired,
    )..orderBy([(r) => OrderingTerm.desc(r.expiredAt)])).watch();
  }

  Future<void> _expireStaleQueueItems() async {
    final podcasts = await _db.select(_db.podcasts).get();
    final now = DateTime.now().toUtc();

    for (final podcast in podcasts) {
      final limit = podcast.queueAgeLimitDays;
      if (limit == null) continue;

      final cutoff = now.subtract(Duration(days: limit));

      final staleItems =
          await (_db.select(_db.queueItems).join([
                  innerJoin(
                    _db.episodes,
                    _db.episodes.id.equalsExp(_db.queueItems.episodeId),
                  ),
                ])
                ..where(_db.queueItems.addedAt.isSmallerThanValue(cutoff))
                ..where(_db.episodes.podcastId.equals(podcast.id)))
              .get();

      for (final row in staleItems) {
        final queueItem = row.readTable(_db.queueItems);
        await _db.transaction(() async {
          await (_db.delete(
            _db.queueItems,
          )..where((q) => q.id.equals(queueItem.id))).go();
          await _db
              .into(_db.recentlyExpired)
              .insertOnConflictUpdate(
                RecentlyExpiredCompanion.insert(
                  episodeId: queueItem.episodeId,
                ),
              );
        });
        _log.info('Expired queue item for episode ${queueItem.episodeId}');
      }
    }
  }

  Future<void> _cleanupOldRecentlyExpired() async {
    final cutoff = DateTime.now().toUtc().subtract(
      const Duration(days: _recentlyExpiredRetentionDays),
    );

    await (_db.delete(
      _db.recentlyExpired,
    )..where((r) => r.expiredAt.isSmallerThanValue(cutoff))).go();
  }

  Future<int> _maxQueuePosition() async {
    final result =
        await (_db.select(_db.queueItems)
              ..orderBy([(q) => OrderingTerm.desc(q.position)])
              ..limit(1))
            .getSingleOrNull();
    return result?.position ?? -1;
  }
}
