import 'package:drift/drift.dart';

import '../../../data/db/app_database.dart';
import '../domain/stats_period.dart';

abstract interface class StatsRepository {
  Future<ListeningStats> getStats(StatsPeriod period);

  Stream<ListeningStats> watchStats(StatsPeriod period);

  Future<void> applyRetentionPolicy(int? retentionDays);

  Future<void> deleteAllHistory();
}

class StatsRepositoryImpl implements StatsRepository {
  const StatsRepositoryImpl({required AppDatabase database}) : _db = database;

  final AppDatabase _db;

  @override
  Future<ListeningStats> getStats(StatsPeriod period) async {
    final since = period.since;

    final sessions = await _sessionsSince(since);

    var totalSeconds = 0;
    var timeSavedSeconds = 0;
    final podcastMap = <int, ({String title, int seconds, int count})>{};

    for (final s in sessions) {
      totalSeconds += s.durationSeconds;

      // Time saved vs 1.0x: duration * (1 - 1/speed)
      if (s.speed > 1.0) {
        timeSavedSeconds += (s.durationSeconds * (1 - 1 / s.speed)).round();
      }

      final existing = podcastMap[s.podcastId];
      final title = await _podcastTitle(s.podcastId);
      podcastMap[s.podcastId] = (
        title: title,
        seconds: (existing?.seconds ?? 0) + s.durationSeconds,
        count: (existing?.count ?? 0) + 1,
      );
    }

    final episodesCompleted = await _episodesCompleted(since);

    final perPodcast =
        podcastMap.entries
            .map(
              (e) => PodcastStats(
                podcastId: e.key,
                podcastTitle: e.value.title,
                totalSeconds: e.value.seconds,
                episodeCount: e.value.count,
              ),
            )
            .toList()
          ..sort((a, b) => b.totalSeconds.compareTo(a.totalSeconds));

    return ListeningStats(
      totalSeconds: totalSeconds,
      timeSavedSeconds: timeSavedSeconds,
      episodesCompleted: episodesCompleted,
      perPodcast: perPodcast,
    );
  }

  @override
  Stream<ListeningStats> watchStats(StatsPeriod period) {
    final query = _db.select(_db.listeningSessions);
    if (period.since != null) {
      query.where((s) => s.date.isBiggerOrEqualValue(period.since!));
    }
    return query.watch().asyncMap((_) => getStats(period));
  }

  @override
  Future<void> applyRetentionPolicy(int? retentionDays) async {
    if (retentionDays == null) return;
    final cutoff = DateTime.now().toUtc().subtract(
      Duration(days: retentionDays),
    );
    await (_db.delete(
      _db.listeningSessions,
    )..where((s) => s.date.isSmallerThanValue(cutoff))).go();
  }

  @override
  Future<void> deleteAllHistory() async {
    await _db.delete(_db.listeningSessions).go();
  }

  Future<List<ListeningSessionRow>> _sessionsSince(DateTime? since) {
    final query = _db.select(_db.listeningSessions);
    if (since != null) {
      query.where((s) => s.date.isBiggerOrEqualValue(since));
    }
    return query.get();
  }

  Future<int> _episodesCompleted(DateTime? since) async {
    final query = _db.select(_db.episodes)
      ..where((e) => e.playedAt.isNotNull());
    if (since != null) {
      query.where((e) => e.playedAt.isBiggerOrEqualValue(since));
    }
    final rows = await query.get();
    return rows.length;
  }

  Future<String> _podcastTitle(int podcastId) async {
    final row = await (_db.select(
      _db.podcasts,
    )..where((p) => p.id.equals(podcastId))).getSingleOrNull();
    return row?.title ?? 'Unknown Podcast';
  }
}
