import 'package:audio_service/audio_service.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:earshot/core/providers/core_providers.dart';
import 'package:earshot/data/db/app_database.dart';
import 'package:earshot/data/db/enums.dart';
import 'package:earshot/features/player/data/audio_handler.dart';
import 'package:earshot/features/player/presentation/providers/player_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:rxdart/subjects.dart';

class MockAudioHandler extends Mock implements EarshotAudioHandler {}

/// Drives the real onEpisodeCompleted advance logic (`queueAutoAdvanceProvider`)
/// against a real in-memory database. This is the path that both
/// "Mark as played" (#281) and "Remove from queue on the playing episode"
/// (#316) route into via `markCurrentEpisodePlayed()`, so it must produce the
/// correct end state regardless of play/pause — it's invoked manually, not only
/// at genuine end-of-track.
void main() {
  setUpAll(() {
    registerFallbackValue(const MediaItem(id: 'fallback', title: 'fallback'));
    registerFallbackValue(() async {});
  });

  late AppDatabase db;
  late MockAudioHandler handler;

  Future<int> addQueued(String guid, int position) async {
    final id = await db
        .into(db.episodes)
        .insert(
          EpisodesCompanion.insert(
            podcastId: 1,
            guid: guid,
            title: guid,
            audioUrl: 'https://example.com/$guid.mp3',
            status: const Value(EpisodeStatus.inQueue),
            positionSeconds: const Value(120),
          ),
        );
    await db
        .into(db.queueItems)
        .insert(QueueItemsCompanion.insert(episodeId: id, position: position));
    return id;
  }

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await db
        .into(db.podcasts)
        .insert(
          PodcastsCompanion.insert(
            rssUrl: 'https://example.com/feed.xml',
            title: 'Test Podcast',
          ),
        );

    handler = MockAudioHandler();
    when(
      () => handler.positionStream,
    ).thenAnswer((_) => const Stream<Duration>.empty());
    // Queue-reconcile subscription reads these on every queue change.
    when(() => handler.isAdvancing).thenReturn(false);
    when(() => handler.preloadedNextEpisodeId).thenReturn(null);
    when(() => handler.currentEpisodeId).thenReturn(null);
    when(() => handler.clearPreloadedNext()).thenAnswer((_) async {});
    when(() => handler.stop()).thenAnswer((_) async {});
    when(() => handler.preloadNext(any())).thenAnswer((_) async {});
    when(
      () => handler.playEpisode(
        any(),
        resumePositionSeconds: any(named: 'resumePositionSeconds'),
      ),
    ).thenAnswer((_) async {});
  });

  tearDown(() async {
    await db.close();
  });

  /// Wires queueAutoAdvanceProvider and returns the assigned onEpisodeCompleted
  /// callback (what markCurrentEpisodePlayed triggers).
  Future<void> Function() wireCompletion(int currentEpisodeId) {
    final mediaItemSubject = BehaviorSubject<MediaItem?>.seeded(
      MediaItem(
        id: 'current',
        title: 'current',
        extras: {'episodeId': currentEpisodeId, 'podcastId': 1},
      ),
    );
    addTearDown(mediaItemSubject.close);
    when(() => handler.mediaItem).thenAnswer((_) => mediaItemSubject);

    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        audioHandlerProvider.overrideWithValue(handler),
      ],
    );
    addTearDown(container.dispose);
    container.read(queueAutoAdvanceProvider);

    return verify(() => handler.onEpisodeCompleted = captureAny()).captured.last
        as Future<void> Function();
  }

  test(
    'completing the current episode marks it played, removes it, advances',
    () async {
      final ep1 = await addQueued('ep1', 0);
      final ep2 = await addQueued('ep2', 1);

      final onCompleted = wireCompletion(ep1);
      await onCompleted();

      final ep1Row = await (db.select(
        db.episodes,
      )..where((e) => e.id.equals(ep1))).getSingle();
      expect(
        ep1Row.status,
        EpisodeStatus.played,
        reason: 'current marked played',
      );
      // markPlayedAndRemove intentionally preserves the saved position (#293):
      // an interrupted episode keeps its place so it can be recovered later.
      expect(
        ep1Row.positionSeconds,
        120,
        reason: 'saved position is preserved, not cleared (#293)',
      );
      expect(ep1Row.playedAt, isNotNull, reason: 'playedAt stamped');

      final queue = await db.select(db.queueItems).get();
      expect(queue.map((q) => q.episodeId), [
        ep2,
      ], reason: 'ep1 removed, ep2 left');

      verify(
        () => handler.playEpisode(
          any(),
          resumePositionSeconds: any(named: 'resumePositionSeconds'),
        ),
      ).called(1);
      verifyNever(() => handler.stop());
    },
  );

  test(
    'completing the last queued episode marks it played and stops',
    () async {
      final ep1 = await addQueued('only', 0);

      final onCompleted = wireCompletion(ep1);
      await onCompleted();

      final ep1Row = await (db.select(
        db.episodes,
      )..where((e) => e.id.equals(ep1))).getSingle();
      expect(ep1Row.status, EpisodeStatus.played);

      final queue = await db.select(db.queueItems).get();
      expect(queue, isEmpty, reason: 'queue drained');

      verify(() => handler.stop()).called(1);
      verifyNever(
        () => handler.playEpisode(
          any(),
          resumePositionSeconds: any(named: 'resumePositionSeconds'),
        ),
      );
    },
  );
}
