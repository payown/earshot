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
    await _db.transaction(() async {
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
      // Only flip to inQueue when the episode is new. Played/expired episodes
      // can be re-queued without disturbing their existing status.
      await (_db.update(_db.episodes)..where(
            (e) =>
                e.id.equals(episodeId) &
                e.status.equals(EpisodeStatus.newEpisode.name),
          ))
          .write(
            const EpisodesCompanion(status: Value(EpisodeStatus.inQueue)),
          );
    });
    _log.fine('Added episode $episodeId to queue');
  }

  @override
  Future<void> addAfterCurrent(int episodeId) async {
    await _db.transaction(() async {
      final rows = await (_db.select(
        _db.queueItems,
      )..orderBy([(q) => OrderingTerm.asc(q.position)])).get();

      final alreadyQueued = rows.any((r) => r.episodeId == episodeId);
      final insertAt = rows.isEmpty ? 0 : 1;

      if (alreadyQueued) {
        // Remove from current slot without touching episode status.
        await (_db.delete(
          _db.queueItems,
        )..where((q) => q.episodeId.equals(episodeId))).go();
      }

      // Re-fetch after possible removal so positions are current.
      final fresh = alreadyQueued
          ? await (_db.select(
              _db.queueItems,
            )..orderBy([(q) => OrderingTerm.asc(q.position)])).get()
          : rows;

      // Shift items from insertAt onwards up by 1 (iterate in reverse to avoid
      // collisions when two rows temporarily share the same position value).
      for (final row in fresh.reversed) {
        if (row.position >= insertAt) {
          await (_db.update(_db.queueItems)..where((q) => q.id.equals(row.id)))
              .write(QueueItemsCompanion(position: Value(row.position + 1)));
        }
      }

      await _db
          .into(_db.queueItems)
          .insert(
            QueueItemsCompanion.insert(
              episodeId: episodeId,
              position: insertAt,
            ),
          );

      if (!alreadyQueued) {
        await (_db.update(_db.episodes)..where(
              (e) =>
                  e.id.equals(episodeId) &
                  e.status.equals(EpisodeStatus.newEpisode.name),
            ))
            .write(
              const EpisodesCompanion(status: Value(EpisodeStatus.inQueue)),
            );
      }
    });
    await _compactPositions();
    _log.fine('Added episode $episodeId to queue after current');
  }

  @override
  Future<void> removeFromQueue(int episodeId) async {
    await (_db.delete(
      _db.queueItems,
    )..where((q) => q.episodeId.equals(episodeId))).go();
    await _compactPositions();
  }

  @override
  Future<void> markPlayedAndRemove(int episodeId) async {
    await _db.transaction(() async {
      await (_db.delete(
        _db.queueItems,
      )..where((q) => q.episodeId.equals(episodeId))).go();
      await _compactPositions();
      await (_db.update(
        _db.episodes,
      )..where((e) => e.id.equals(episodeId))).write(
        EpisodesCompanion(
          status: const Value(EpisodeStatus.played),
          positionSeconds: const Value(0),
          playedAt: Value(DateTime.now().toUtc()),
        ),
      );
    });
    _log.fine('Marked episode $episodeId played and removed from queue');
  }

  @override
  Future<void> cancelFromQueue(int episodeId) async {
    await _db.transaction(() async {
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
    });
    _log.fine('Cancelled episode $episodeId from queue, returned to inbox');
  }

  @override
  Future<void> moveToTop(int episodeId) async {
    // Use -1 so _compactPositions sorts this item before anything at position 0.
    await (_db.update(_db.queueItems)
          ..where((q) => q.episodeId.equals(episodeId)))
        .write(const QueueItemsCompanion(position: Value(-1)));
    await _compactPositions();
  }

  @override
  Future<void> moveToBottom(int episodeId) async {
    final max = await _maxPosition();
    await (_db.update(_db.queueItems)
          ..where((q) => q.episodeId.equals(episodeId)))
        .write(QueueItemsCompanion(position: Value(max + 1)));
    await _compactPositions();
  }

  @override
  Future<void> moveUp(int episodeId) async {
    final rows = await (_db.select(
      _db.queueItems,
    )..orderBy([(q) => OrderingTerm.asc(q.position)])).get();
    final idx = rows.indexWhere((r) => r.episodeId == episodeId);
    if (idx <= 0) return;
    await _db.transaction(() async {
      await (_db.update(_db.queueItems)
            ..where((q) => q.id.equals(rows[idx].id)))
          .write(QueueItemsCompanion(position: Value(rows[idx - 1].position)));
      await (_db.update(_db.queueItems)
            ..where((q) => q.id.equals(rows[idx - 1].id)))
          .write(QueueItemsCompanion(position: Value(rows[idx].position)));
    });
    await _compactPositions();
  }

  @override
  Future<void> moveDown(int episodeId) async {
    final rows = await (_db.select(
      _db.queueItems,
    )..orderBy([(q) => OrderingTerm.asc(q.position)])).get();
    final idx = rows.indexWhere((r) => r.episodeId == episodeId);
    if (idx < 0 || idx >= rows.length - 1) return;
    await _db.transaction(() async {
      await (_db.update(_db.queueItems)
            ..where((q) => q.id.equals(rows[idx].id)))
          .write(QueueItemsCompanion(position: Value(rows[idx + 1].position)));
      await (_db.update(_db.queueItems)
            ..where((q) => q.id.equals(rows[idx + 1].id)))
          .write(QueueItemsCompanion(position: Value(rows[idx].position)));
    });
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
  Future<void> sortGroup(List<int> episodeIdsInOrder) async {
    if (episodeIdsInOrder.length < 2) return;
    await _db.transaction(() async {
      final rows = await (_db.select(
        _db.queueItems,
      )..orderBy([(q) => OrderingTerm.asc(q.position)])).get();

      final idSet = episodeIdsInOrder.toSet();

      // Collect the positions currently held by this group, in queue order.
      final slots = <int>[
        for (final row in rows)
          if (idSet.contains(row.episodeId)) row.position,
      ];

      // Move to temp positions first to avoid conflicts during reassignment.
      const tempBase = 1000000;
      for (var i = 0; i < episodeIdsInOrder.length; i++) {
        await (_db.update(_db.queueItems)
              ..where((q) => q.episodeId.equals(episodeIdsInOrder[i])))
            .write(QueueItemsCompanion(position: Value(tempBase + i)));
      }

      // Assign each episode to its target slot.
      for (var i = 0; i < episodeIdsInOrder.length; i++) {
        await (_db.update(_db.queueItems)
              ..where((q) => q.episodeId.equals(episodeIdsInOrder[i])))
            .write(QueueItemsCompanion(position: Value(slots[i])));
      }
    });
    await _compactPositions();
  }

  @override
  Future<void> bringGroupToFront(List<int> episodeIdsInOrder) async {
    if (episodeIdsInOrder.isEmpty) return;
    await _db.transaction(() async {
      final rows = await (_db.select(
        _db.queueItems,
      )..orderBy([(q) => OrderingTerm.asc(q.position)])).get();

      final idSet = episodeIdsInOrder.toSet();
      final nonGroupRows = rows
          .where((r) => !idSet.contains(r.episodeId))
          .toList();

      // Move everything to temp positions first to avoid unique-constraint
      // collisions while reassigning. Same pattern as sortGroup().
      const tempBase = 1000000;
      for (var i = 0; i < episodeIdsInOrder.length; i++) {
        await (_db.update(_db.queueItems)
              ..where((q) => q.episodeId.equals(episodeIdsInOrder[i])))
            .write(QueueItemsCompanion(position: Value(tempBase + i)));
      }
      for (var i = 0; i < nonGroupRows.length; i++) {
        await (_db.update(
          _db.queueItems,
        )..where((q) => q.id.equals(nonGroupRows[i].id))).write(
          QueueItemsCompanion(
            position: Value(tempBase + episodeIdsInOrder.length + i),
          ),
        );
      }

      // Group episodes go to positions 0..N-1 in the requested order.
      for (var i = 0; i < episodeIdsInOrder.length; i++) {
        await (_db.update(_db.queueItems)
              ..where((q) => q.episodeId.equals(episodeIdsInOrder[i])))
            .write(QueueItemsCompanion(position: Value(i)));
      }

      // Non-group episodes follow at positions N..N+M-1, original order kept.
      for (var i = 0; i < nonGroupRows.length; i++) {
        await (_db.update(
          _db.queueItems,
        )..where((q) => q.id.equals(nonGroupRows[i].id))).write(
          QueueItemsCompanion(
            position: Value(episodeIdsInOrder.length + i),
          ),
        );
      }
    });
    await _compactPositions();
    _log.fine(
      'Brought group of ${episodeIdsInOrder.length} episodes to front',
    );
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
    await _db.transaction(() async {
      await _db.delete(_db.queueItems).go();
      await (_db.update(
        _db.episodes,
      )..where((e) => e.status.equals(EpisodeStatus.inQueue.name))).write(
        const EpisodesCompanion(status: Value(EpisodeStatus.newEpisode)),
      );
    });
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
