import 'package:drift/drift.dart';
import 'package:logging/logging.dart';

import '../../../data/db/app_database.dart';
import '../../../data/db/enums.dart';
import '../../subscriptions/domain/episode.dart';
import 'queue_repository.dart';

final _log = Logger('QueueRepository');

class QueueRepositoryImpl implements QueueRepository {
  const QueueRepositoryImpl({required AppDatabase database}) : _db = database;

  final AppDatabase _db;

  @override
  Future<void> addToQueue(int episodeId) async {
    final maxPosition = await _maxPosition();
    await _db
        .into(_db.queueItems)
        .insert(
          QueueItemsCompanion.insert(
            episodeId: episodeId,
            position: maxPosition + 1,
          ),
          mode: InsertMode.insertOrIgnore,
        );
    await (_db.update(_db.episodes)..where((e) => e.id.equals(episodeId)))
        .write(const EpisodesCompanion(status: Value(EpisodeStatus.inQueue)));
    _log.fine('Added episode $episodeId to queue');
  }

  @override
  Future<void> removeFromQueue(int episodeId) async {
    await (_db.delete(
      _db.queueItems,
    )..where((q) => q.episodeId.equals(episodeId))).go();
    await _compactPositions();
  }

  @override
  Future<void> cancelFromQueue(int episodeId) async {
    await (_db.delete(
      _db.queueItems,
    )..where((q) => q.episodeId.equals(episodeId))).go();
    await _compactPositions();
    await (_db.update(_db.episodes)..where(
          (e) =>
              e.id.equals(episodeId) &
              e.status.equals(EpisodeStatus.inQueue.name),
        ))
        .write(
          const EpisodesCompanion(status: Value(EpisodeStatus.newEpisode)),
        );
    _log.fine('Cancelled episode $episodeId from queue, returned to inbox');
  }

  @override
  Future<void> moveToTop(int episodeId) async {
    await (_db.update(_db.queueItems)
          ..where((q) => q.episodeId.equals(episodeId)))
        .write(const QueueItemsCompanion(position: Value(0)));
    await _compactPositions();
  }

  @override
  Future<void> reorder(int episodeId, int newPosition) async {
    await (_db.update(_db.queueItems)
          ..where((q) => q.episodeId.equals(episodeId)))
        .write(QueueItemsCompanion(position: Value(newPosition)));
    await _compactPositions();
  }

  @override
  Stream<List<Episode>> watchQueue() {
    final query = _db.select(_db.queueItems).join([
      innerJoin(
        _db.episodes,
        _db.episodes.id.equalsExp(_db.queueItems.episodeId),
      ),
    ])..orderBy([OrderingTerm.asc(_db.queueItems.position)]);

    return query.watch().map(
      (rows) => rows
          .map((row) => _episodeFromRow(row.readTable(_db.episodes)))
          .toList(),
    );
  }

  @override
  Future<void> clearQueue() async {
    await _db.delete(_db.queueItems).go();
    await (_db.update(
      _db.episodes,
    )..where((e) => e.status.equals(EpisodeStatus.inQueue.name))).write(
      const EpisodesCompanion(status: Value(EpisodeStatus.newEpisode)),
    );
  }

  Future<int> _maxPosition() async {
    final result =
        await (_db.select(_db.queueItems)
              ..orderBy([(q) => OrderingTerm.desc(q.position)])
              ..limit(1))
            .getSingleOrNull();
    return result?.position ?? -1;
  }

  // Re-number positions sequentially after any modification.
  Future<void> _compactPositions() async {
    final rows = await (_db.select(
      _db.queueItems,
    )..orderBy([(q) => OrderingTerm.asc(q.position)])).get();
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].position != i) {
        await (_db.update(_db.queueItems)
              ..where((q) => q.id.equals(rows[i].id)))
            .write(QueueItemsCompanion(position: Value(i)));
      }
    }
  }

  Episode _episodeFromRow(EpisodeRow row) => Episode(
    id: row.id,
    podcastId: row.podcastId,
    guid: row.guid,
    title: row.title,
    description: row.description,
    audioUrl: row.audioUrl,
    durationSeconds: row.durationSeconds,
    pubDate: row.pubDate,
    artworkUrl: row.artworkUrl,
    episodeNumber: row.episodeNumber,
    seasonNumber: row.seasonNumber,
    chapterUrl: row.chapterUrl,
    transcriptUrl: row.transcriptUrl,
    status: row.status,
    downloadStatus: row.downloadStatus,
    downloadPath: row.downloadPath,
    positionSeconds: row.positionSeconds,
    playedAt: row.playedAt,
    createdAt: row.createdAt,
  );
}
