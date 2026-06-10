import 'package:drift/drift.dart' hide isNotNull;
import 'package:drift/native.dart';
import 'package:earshot/data/db/app_database.dart';
import 'package:earshot/data/db/enums.dart';
import 'package:earshot/features/player/data/queue_repository_impl.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late QueueRepositoryImpl repo;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = QueueRepositoryImpl(database: db);
  });

  tearDown(() => db.close());

  Future<int> _addPodcast() => db
      .into(db.podcasts)
      .insert(
        PodcastsCompanion.insert(
          rssUrl:
              'https://example.com/${DateTime.now().microsecondsSinceEpoch}',
          title: 'Test Podcast',
        ),
      );

  Future<int> _addEpisode(
    int podcastId, {
    EpisodeStatus status = EpisodeStatus.newEpisode,
  }) => db
      .into(db.episodes)
      .insert(
        EpisodesCompanion.insert(
          podcastId: podcastId,
          guid: 'guid-${DateTime.now().microsecondsSinceEpoch}',
          title: 'Episode',
          audioUrl: 'https://example.com/ep.mp3',
          status: Value(status),
        ),
      );

  Future<List<int>> _queueOrder() async {
    final rows = await (db.select(
      db.queueItems,
    )..orderBy([(q) => OrderingTerm.asc(q.position)])).get();
    return rows.map((r) => r.episodeId).toList();
  }

  Future<EpisodeStatus> _episodeStatus(int episodeId) async {
    final row = await (db.select(
      db.episodes,
    )..where((e) => e.id.equals(episodeId))).getSingle();
    return row.status;
  }

  // ── addToQueue ────────────────────────────────────────────────────────────

  group('addToQueue', () {
    test('adds episode to empty queue at position 0', () async {
      final podcastId = await _addPodcast();
      final epId = await _addEpisode(podcastId);

      await repo.addToQueue(epId);

      expect(await _queueOrder(), [epId]);
    });

    test('appends to non-empty queue', () async {
      final podcastId = await _addPodcast();
      final ep1 = await _addEpisode(podcastId);
      final ep2 = await _addEpisode(podcastId);

      await repo.addToQueue(ep1);
      await repo.addToQueue(ep2);

      expect(await _queueOrder(), [ep1, ep2]);
    });

    test('sets status to inQueue for newEpisode', () async {
      final podcastId = await _addPodcast();
      final epId = await _addEpisode(podcastId);

      await repo.addToQueue(epId);

      expect(await _episodeStatus(epId), EpisodeStatus.inQueue);
    });

    test('does not flip status for already-played episode', () async {
      final podcastId = await _addPodcast();
      final epId = await _addEpisode(podcastId, status: EpisodeStatus.played);

      await repo.addToQueue(epId);

      expect(await _episodeStatus(epId), EpisodeStatus.played);
    });

    test('is idempotent — duplicate insert is silently ignored', () async {
      final podcastId = await _addPodcast();
      final epId = await _addEpisode(podcastId);

      await repo.addToQueue(epId);
      await repo.addToQueue(epId);

      expect(await _queueOrder(), [epId]);
    });
  });

  // ── removeFromQueue ───────────────────────────────────────────────────────

  group('removeFromQueue', () {
    test('removes episode from queue', () async {
      final podcastId = await _addPodcast();
      final ep1 = await _addEpisode(podcastId);
      final ep2 = await _addEpisode(podcastId);
      await repo.addToQueue(ep1);
      await repo.addToQueue(ep2);

      await repo.removeFromQueue(ep1);

      expect(await _queueOrder(), [ep2]);
    });

    test('does not change episode status', () async {
      final podcastId = await _addPodcast();
      final epId = await _addEpisode(podcastId);
      await repo.addToQueue(epId);

      await repo.removeFromQueue(epId);

      expect(await _episodeStatus(epId), EpisodeStatus.inQueue);
    });

    test('compacts positions after removal', () async {
      final podcastId = await _addPodcast();
      final ep1 = await _addEpisode(podcastId);
      final ep2 = await _addEpisode(podcastId);
      final ep3 = await _addEpisode(podcastId);
      await repo.addToQueue(ep1);
      await repo.addToQueue(ep2);
      await repo.addToQueue(ep3);

      await repo.removeFromQueue(ep2);

      expect(await _queueOrder(), [ep1, ep3]);
    });
  });

  // ── markPlayedAndRemove ───────────────────────────────────────────────────

  group('markPlayedAndRemove', () {
    test('removes episode from queue and compacts positions', () async {
      final podcastId = await _addPodcast();
      final ep1 = await _addEpisode(podcastId);
      final ep2 = await _addEpisode(podcastId);
      final ep3 = await _addEpisode(podcastId);
      await repo.addToQueue(ep1);
      await repo.addToQueue(ep2);
      await repo.addToQueue(ep3);

      await repo.markPlayedAndRemove(ep2);

      expect(await _queueOrder(), [ep1, ep3]);
    });

    test(
      'marks the episode played with position reset and playedAt set',
      () async {
        final podcastId = await _addPodcast();
        final epId = await _addEpisode(podcastId);
        await repo.addToQueue(epId);
        await (db.update(db.episodes)..where((e) => e.id.equals(epId))).write(
          const EpisodesCompanion(positionSeconds: Value(1234)),
        );

        await repo.markPlayedAndRemove(epId);

        final row = await (db.select(
          db.episodes,
        )..where((e) => e.id.equals(epId))).getSingle();
        expect(row.status, EpisodeStatus.played);
        expect(row.positionSeconds, 0);
        expect(row.playedAt, isNotNull);
      },
    );

    test('episode no longer matches the inbox predicate', () async {
      final podcastId = await _addPodcast();
      final epId = await _addEpisode(podcastId);
      await repo.addToQueue(epId);

      await repo.markPlayedAndRemove(epId);

      // Inbox shows status == newEpisode && !inboxDismissed; a completed
      // episode must not reappear there or be stranded at inQueue.
      final row = await (db.select(
        db.episodes,
      )..where((e) => e.id.equals(epId))).getSingle();
      expect(row.status, isNot(EpisodeStatus.newEpisode));
      expect(row.status, isNot(EpisodeStatus.inQueue));
    });
  });

  // ── cancelFromQueue ───────────────────────────────────────────────────────

  group('cancelFromQueue', () {
    test('removes episode from queue', () async {
      final podcastId = await _addPodcast();
      final epId = await _addEpisode(podcastId);
      await repo.addToQueue(epId);

      await repo.cancelFromQueue(epId);

      expect(await _queueOrder(), isEmpty);
    });

    test('reverts inQueue status to newEpisode', () async {
      final podcastId = await _addPodcast();
      final epId = await _addEpisode(podcastId);
      await repo.addToQueue(epId);
      expect(await _episodeStatus(epId), EpisodeStatus.inQueue);

      await repo.cancelFromQueue(epId);

      expect(await _episodeStatus(epId), EpisodeStatus.newEpisode);
    });

    test('does not revert status for non-inQueue episodes', () async {
      final podcastId = await _addPodcast();
      final epId = await _addEpisode(podcastId, status: EpisodeStatus.played);
      await repo.addToQueue(epId);

      await repo.cancelFromQueue(epId);

      expect(await _episodeStatus(epId), EpisodeStatus.played);
    });
  });

  // ── moveToTop / moveToBottom ──────────────────────────────────────────────

  group('moveToTop', () {
    test('moves last episode to front', () async {
      final podcastId = await _addPodcast();
      final ep1 = await _addEpisode(podcastId);
      final ep2 = await _addEpisode(podcastId);
      final ep3 = await _addEpisode(podcastId);
      await repo.addToQueue(ep1);
      await repo.addToQueue(ep2);
      await repo.addToQueue(ep3);

      await repo.moveToTop(ep3);

      expect(await _queueOrder(), [ep3, ep1, ep2]);
    });

    test('no-op when already at top', () async {
      final podcastId = await _addPodcast();
      final ep1 = await _addEpisode(podcastId);
      final ep2 = await _addEpisode(podcastId);
      await repo.addToQueue(ep1);
      await repo.addToQueue(ep2);

      await repo.moveToTop(ep1);

      expect(await _queueOrder(), [ep1, ep2]);
    });
  });

  group('moveToBottom', () {
    test('moves first episode to end', () async {
      final podcastId = await _addPodcast();
      final ep1 = await _addEpisode(podcastId);
      final ep2 = await _addEpisode(podcastId);
      final ep3 = await _addEpisode(podcastId);
      await repo.addToQueue(ep1);
      await repo.addToQueue(ep2);
      await repo.addToQueue(ep3);

      await repo.moveToBottom(ep1);

      expect(await _queueOrder(), [ep2, ep3, ep1]);
    });
  });

  // ── moveUp / moveDown ─────────────────────────────────────────────────────

  group('moveUp', () {
    test('swaps with the episode above', () async {
      final podcastId = await _addPodcast();
      final ep1 = await _addEpisode(podcastId);
      final ep2 = await _addEpisode(podcastId);
      final ep3 = await _addEpisode(podcastId);
      await repo.addToQueue(ep1);
      await repo.addToQueue(ep2);
      await repo.addToQueue(ep3);

      await repo.moveUp(ep2);

      expect(await _queueOrder(), [ep2, ep1, ep3]);
    });

    test('no-op when already at top', () async {
      final podcastId = await _addPodcast();
      final ep1 = await _addEpisode(podcastId);
      final ep2 = await _addEpisode(podcastId);
      await repo.addToQueue(ep1);
      await repo.addToQueue(ep2);

      await repo.moveUp(ep1);

      expect(await _queueOrder(), [ep1, ep2]);
    });
  });

  group('moveDown', () {
    test('swaps with the episode below', () async {
      final podcastId = await _addPodcast();
      final ep1 = await _addEpisode(podcastId);
      final ep2 = await _addEpisode(podcastId);
      final ep3 = await _addEpisode(podcastId);
      await repo.addToQueue(ep1);
      await repo.addToQueue(ep2);
      await repo.addToQueue(ep3);

      await repo.moveDown(ep2);

      expect(await _queueOrder(), [ep1, ep3, ep2]);
    });

    test('no-op when already at bottom', () async {
      final podcastId = await _addPodcast();
      final ep1 = await _addEpisode(podcastId);
      final ep2 = await _addEpisode(podcastId);
      await repo.addToQueue(ep1);
      await repo.addToQueue(ep2);

      await repo.moveDown(ep2);

      expect(await _queueOrder(), [ep1, ep2]);
    });
  });

  // ── reorder ───────────────────────────────────────────────────────────────

  group('reorder', () {
    test('moves first episode to the end via a large position value', () async {
      final podcastId = await _addPodcast();
      final ep1 = await _addEpisode(podcastId);
      final ep2 = await _addEpisode(podcastId);
      final ep3 = await _addEpisode(podcastId);
      await repo.addToQueue(ep1);
      await repo.addToQueue(ep2);
      await repo.addToQueue(ep3);

      // Using a large position that doesn't collide with any existing slot so
      // _compactPositions produces a deterministic result.
      await repo.reorder(ep1, 100);

      expect(await _queueOrder(), [ep2, ep3, ep1]);
    });
  });

  // ── sortGroup ─────────────────────────────────────────────────────────────

  group('sortGroup', () {
    test('reorders episodes within their existing queue slots', () async {
      final podA = await _addPodcast();
      final podB = await _addPodcast();
      // Queue order: A1, B1, A2, A3, B2 — A occupies positions 0, 2, 3.
      final a1 = await _addEpisode(podA);
      final b1 = await _addEpisode(podB);
      final a2 = await _addEpisode(podA);
      final a3 = await _addEpisode(podA);
      final b2 = await _addEpisode(podB);
      await repo.addToQueue(a1);
      await repo.addToQueue(b1);
      await repo.addToQueue(a2);
      await repo.addToQueue(a3);
      await repo.addToQueue(b2);

      // Desired group A order: a3, a2, a1.
      await repo.sortGroup([a3, a2, a1]);

      // B episodes keep their slots; A episodes reorder into A's slots.
      expect(await _queueOrder(), [a3, b1, a2, a1, b2]);
    });

    test('shuffles all members of a contiguous group', () async {
      final podA = await _addPodcast();
      final a1 = await _addEpisode(podA);
      final a2 = await _addEpisode(podA);
      final a3 = await _addEpisode(podA);
      await repo.addToQueue(a1);
      await repo.addToQueue(a2);
      await repo.addToQueue(a3);

      await repo.sortGroup([a3, a1, a2]);

      expect(await _queueOrder(), [a3, a1, a2]);
    });

    test('no-op when fewer than two episodes are passed', () async {
      final podA = await _addPodcast();
      final a1 = await _addEpisode(podA);
      final a2 = await _addEpisode(podA);
      await repo.addToQueue(a1);
      await repo.addToQueue(a2);

      await repo.sortGroup([a1]);

      expect(await _queueOrder(), [a1, a2]);
    });
  });

  // ── bringGroupToFront ─────────────────────────────────────────────────────

  group('bringGroupToFront', () {
    test(
      'moves interleaved group episodes to front in specified order',
      () async {
        final podA = await _addPodcast();
        final podB = await _addPodcast();
        // Interleaved: A1, B1, A2, B2
        final a1 = await _addEpisode(podA);
        final b1 = await _addEpisode(podB);
        final a2 = await _addEpisode(podA);
        final b2 = await _addEpisode(podB);
        await repo.addToQueue(a1);
        await repo.addToQueue(b1);
        await repo.addToQueue(a2);
        await repo.addToQueue(b2);

        // Play group A in reverse order (a2 first, then a1).
        await repo.bringGroupToFront([a2, a1]);

        // Group A at front in requested order; B episodes follow in original order.
        expect(await _queueOrder(), [a2, a1, b1, b2]);
      },
    );

    test(
      'handles already-contiguous group without disturbing non-group order',
      () async {
        final podA = await _addPodcast();
        final podB = await _addPodcast();
        // Contiguous: A1, A2 at front, then B1.
        final a1 = await _addEpisode(podA);
        final a2 = await _addEpisode(podA);
        final b1 = await _addEpisode(podB);
        await repo.addToQueue(a1);
        await repo.addToQueue(a2);
        await repo.addToQueue(b1);

        // Reverse the A group order.
        await repo.bringGroupToFront([a2, a1]);

        expect(await _queueOrder(), [a2, a1, b1]);
      },
    );
  });

  // ── watchQueue ────────────────────────────────────────────────────────────

  group('watchQueue', () {
    test('emits empty list when queue is empty', () async {
      expect(await repo.watchQueue().first, isEmpty);
    });

    test('emits episodes in position order', () async {
      final podcastId = await _addPodcast();
      final ep1 = await _addEpisode(podcastId);
      final ep2 = await _addEpisode(podcastId);
      await repo.addToQueue(ep1);
      await repo.addToQueue(ep2);

      final queue = await repo.watchQueue().first;
      expect(queue.map((e) => e.id).toList(), [ep1, ep2]);
    });

    test('emits update when episode is added', () async {
      final podcastId = await _addPodcast();
      final ep1 = await _addEpisode(podcastId);

      final stream = repo.watchQueue();
      final first = await stream.first;
      expect(first, isEmpty);

      await repo.addToQueue(ep1);
      final second = await stream.first;
      expect(second.map((e) => e.id).toList(), [ep1]);
    });
  });

  // ── clearQueue ────────────────────────────────────────────────────────────

  group('clearQueue', () {
    test('removes all items from queue', () async {
      final podcastId = await _addPodcast();
      final ep1 = await _addEpisode(podcastId);
      final ep2 = await _addEpisode(podcastId);
      await repo.addToQueue(ep1);
      await repo.addToQueue(ep2);

      await repo.clearQueue();

      expect(await _queueOrder(), isEmpty);
    });

    test('reverts all inQueue episodes to newEpisode', () async {
      final podcastId = await _addPodcast();
      final ep1 = await _addEpisode(podcastId);
      final ep2 = await _addEpisode(podcastId);
      await repo.addToQueue(ep1);
      await repo.addToQueue(ep2);

      await repo.clearQueue();

      expect(await _episodeStatus(ep1), EpisodeStatus.newEpisode);
      expect(await _episodeStatus(ep2), EpisodeStatus.newEpisode);
    });
  });
}
