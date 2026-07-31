import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:earshot/data/db/app_database.dart';
import 'package:earshot/data/db/enums.dart';
import 'package:earshot/features/stats/data/stats_repository.dart';
import 'package:earshot/features/stats/domain/stats_period.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late StatsRepositoryImpl repo;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = StatsRepositoryImpl(database: db);
  });

  tearDown(() => db.close());

  Future<int> _addPodcast(String title) => db
      .into(db.podcasts)
      .insert(
        PodcastsCompanion.insert(
          rssUrl: 'https://example.com/$title',
          title: title,
        ),
      );

  Future<int> _addEpisode(int podcastId) => db
      .into(db.episodes)
      .insert(
        EpisodesCompanion.insert(
          podcastId: podcastId,
          guid: 'guid-${DateTime.now().microsecondsSinceEpoch}',
          title: 'Episode',
          audioUrl: 'https://example.com/ep.mp3',
        ),
      );

  Future<void> _addSession({
    required int episodeId,
    required int podcastId,
    required int durationSeconds,
    double speed = 1.0,
    DateTime? date,
  }) => db
      .into(db.listeningSessions)
      .insert(
        ListeningSessionsCompanion.insert(
          episodeId: episodeId,
          podcastId: podcastId,
          durationSeconds: durationSeconds,
          speed: Value(speed),
          date: Value(date ?? DateTime.now().toUtc()),
        ),
      );

  group('getStats', () {
    test('returns zero stats when no sessions', () async {
      final stats = await repo.getStats(StatsPeriod.allTime);
      expect(stats.totalSeconds, 0);
      expect(stats.timeSavedSeconds, 0);
      expect(stats.episodesCompleted, 0);
      expect(stats.perPodcast, isEmpty);
    });

    test('sums total listening time', () async {
      final podcastId = await _addPodcast('Test');
      final epId = await _addEpisode(podcastId);
      await _addSession(
        episodeId: epId,
        podcastId: podcastId,
        durationSeconds: 3600,
      );
      await _addSession(
        episodeId: epId,
        podcastId: podcastId,
        durationSeconds: 1800,
      );

      final stats = await repo.getStats(StatsPeriod.allTime);
      expect(stats.totalSeconds, 5400);
    });

    test('calculates time saved at 2x speed', () async {
      final podcastId = await _addPodcast('Test');
      final epId = await _addEpisode(podcastId);
      // At 2x, 3600s listened = 3600 * (1 - 1/2) = 1800s saved.
      await _addSession(
        episodeId: epId,
        podcastId: podcastId,
        durationSeconds: 3600,
        speed: 2.0,
      );

      final stats = await repo.getStats(StatsPeriod.allTime);
      expect(stats.timeSavedSeconds, 1800);
    });

    test('no time saved at 1x speed', () async {
      final podcastId = await _addPodcast('Test');
      final epId = await _addEpisode(podcastId);
      await _addSession(
        episodeId: epId,
        podcastId: podcastId,
        durationSeconds: 3600,
      );

      final stats = await repo.getStats(StatsPeriod.allTime);
      expect(stats.timeSavedSeconds, 0);
    });

    test('counts episodes completed', () async {
      final podcastId = await _addPodcast('Test');
      final epId = await _addEpisode(podcastId);
      await (db.update(db.episodes)..where((e) => e.id.equals(epId))).write(
        EpisodesCompanion(
          status: const Value(EpisodeStatus.played),
          playedAt: Value(DateTime.now().toUtc()),
        ),
      );

      final stats = await repo.getStats(StatsPeriod.allTime);
      expect(stats.episodesCompleted, 1);
    });

    test('filters sessions by period', () async {
      final podcastId = await _addPodcast('Test');
      final epId = await _addEpisode(podcastId);
      final oldDate = DateTime.now().toUtc().subtract(const Duration(days: 60));
      await _addSession(
        episodeId: epId,
        podcastId: podcastId,
        durationSeconds: 3600,
        date: oldDate,
      );
      await _addSession(
        episodeId: epId,
        podcastId: podcastId,
        durationSeconds: 1800,
      );

      final stats = await repo.getStats(StatsPeriod.thisMonth);
      expect(stats.totalSeconds, 1800);
    });

    test('groups per-podcast correctly', () async {
      final p1 = await _addPodcast('Podcast A');
      final p2 = await _addPodcast('Podcast B');
      final ep1 = await _addEpisode(p1);
      final ep2 = await _addEpisode(p2);
      await _addSession(episodeId: ep1, podcastId: p1, durationSeconds: 3600);
      await _addSession(episodeId: ep2, podcastId: p2, durationSeconds: 1800);

      final stats = await repo.getStats(StatsPeriod.allTime);
      expect(stats.perPodcast.length, 2);
      expect(stats.perPodcast[0].totalSeconds, 3600);
      expect(stats.perPodcast[1].totalSeconds, 1800);
    });
  });

  group('applyRetentionPolicy', () {
    test('deletes sessions older than retention window', () async {
      final podcastId = await _addPodcast('Test');
      final epId = await _addEpisode(podcastId);
      final old = DateTime.now().toUtc().subtract(const Duration(days: 100));
      await _addSession(
        episodeId: epId,
        podcastId: podcastId,
        durationSeconds: 60,
        date: old,
      );
      await _addSession(
        episodeId: epId,
        podcastId: podcastId,
        durationSeconds: 60,
      );

      await repo.applyRetentionPolicy(90);

      final remaining = await db.select(db.listeningSessions).get();
      expect(remaining.length, 1);
    });

    test('keeps all sessions when null (keep forever)', () async {
      final podcastId = await _addPodcast('Test');
      final epId = await _addEpisode(podcastId);
      final old = DateTime.now().toUtc().subtract(const Duration(days: 400));
      await _addSession(
        episodeId: epId,
        podcastId: podcastId,
        durationSeconds: 60,
        date: old,
      );

      await repo.applyRetentionPolicy(null);

      final remaining = await db.select(db.listeningSessions).get();
      expect(remaining.length, 1);
    });
  });

  group('deleteAllHistory', () {
    test('removes all sessions', () async {
      final podcastId = await _addPodcast('Test');
      final epId = await _addEpisode(podcastId);
      await _addSession(
        episodeId: epId,
        podcastId: podcastId,
        durationSeconds: 60,
      );
      await _addSession(
        episodeId: epId,
        podcastId: podcastId,
        durationSeconds: 60,
      );

      await repo.deleteAllHistory();

      final remaining = await db.select(db.listeningSessions).get();
      expect(remaining, isEmpty);
    });
  });
}
