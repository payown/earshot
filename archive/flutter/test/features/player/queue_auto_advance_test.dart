import 'package:audio_service/audio_service.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:earshot/core/providers/core_providers.dart';
import 'package:earshot/data/db/app_database.dart';
import 'package:earshot/data/db/enums.dart';
import 'package:earshot/features/player/data/audio_handler.dart';
import 'package:earshot/features/player/presentation/providers/player_providers.dart';
import 'package:earshot/features/settings/data/app_settings_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:rxdart/subjects.dart';

class MockAudioHandler extends Mock implements EarshotAudioHandler {}

/// Drives the real onEpisodeCompleted advance logic (`queueAutoAdvanceProvider`)
/// against a real in-memory database. This is the path that "Mark as played"
/// (#281), "Remove from queue on the playing episode" (#316), and natural
/// end-of-track all route into, so it must produce the correct end state for the
/// #327 model: advance to the item *below* the current one, and stop when both
/// switches are off / a stop-after flag is set.
void main() {
  setUpAll(() {
    registerFallbackValue(const MediaItem(id: 'fallback', title: 'fallback'));
    registerFallbackValue(({required bool stopAfter}) async {});
  });

  late AppDatabase db;
  late MockAudioHandler handler;

  Future<int> addQueuedFor(int podcastId, String guid, int position) async {
    final id = await db
        .into(db.episodes)
        .insert(
          EpisodesCompanion.insert(
            podcastId: podcastId,
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

  Future<int> addQueued(String guid, int position) =>
      addQueuedFor(1, guid, position);

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
    await db
        .into(db.podcasts)
        .insert(
          PodcastsCompanion.insert(
            rssUrl: 'https://example.com/feed2.xml',
            title: 'Other Podcast',
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

  /// Wires queueAutoAdvanceProvider with [currentEpisodeId] as the playing
  /// episode and returns the assigned onEpisodeCompleted callback.
  Future<void> Function({required bool stopAfter}) wireCompletion(
    int currentEpisodeId, {
    int currentPodcastId = 1,
  }) {
    final mediaItemSubject = BehaviorSubject<MediaItem?>.seeded(
      MediaItem(
        id: 'current',
        title: 'current',
        extras: {'episodeId': currentEpisodeId, 'podcastId': currentPodcastId},
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
        as Future<void> Function({required bool stopAfter});
  }

  /// The episodeId passed to the most recent playEpisode call.
  int playedEpisodeId() {
    final item =
        verify(
              () => handler.playEpisode(
                captureAny(),
                resumePositionSeconds: any(named: 'resumePositionSeconds'),
              ),
            ).captured.last
            as MediaItem;
    return item.extras!['episodeId'] as int;
  }

  test(
    'default settings: completing the head advances to the next item',
    () async {
      final ep1 = await addQueued('ep1', 0);
      final ep2 = await addQueued('ep2', 1);

      final onCompleted = wireCompletion(ep1);
      await onCompleted(stopAfter: false);

      final ep1Row = await (db.select(
        db.episodes,
      )..where((e) => e.id.equals(ep1))).getSingle();
      expect(
        ep1Row.status,
        EpisodeStatus.played,
        reason: 'current marked played',
      );
      // markPlayedAndRemove preserves the saved position (#293).
      expect(ep1Row.positionSeconds, 120);

      final queue = await db.select(db.queueItems).get();
      expect(queue.map((q) => q.episodeId), [ep2]);
      expect(playedEpisodeId(), ep2);
      verifyNever(() => handler.stop());
    },
  );

  test('default settings: completing a MID-queue episode advances to the item '
      'below it, not the queue head (#327)', () async {
    await addQueued('ep1', 0);
    final ep2 = await addQueued('ep2', 1);
    final ep3 = await addQueued('ep3', 2);

    final onCompleted = wireCompletion(ep2);
    await onCompleted(stopAfter: false);

    expect(
      playedEpisodeId(),
      ep3,
      reason: 'advances to ep3 (below ep2), not ep1 (the head)',
    );
    verifyNever(() => handler.stop());
  });

  test('completing the last queued episode stops', () async {
    final ep1 = await addQueued('only', 0);

    final onCompleted = wireCompletion(ep1);
    await onCompleted(stopAfter: false);

    final queue = await db.select(db.queueItems).get();
    expect(queue, isEmpty);
    verify(() => handler.stop()).called(1);
    verifyNever(
      () => handler.playEpisode(
        any(),
        resumePositionSeconds: any(named: 'resumePositionSeconds'),
      ),
    );
  });

  test(
    'both switches off: completing a mid-queue episode stops (no advance)',
    () async {
      await addQueued('ep1', 0);
      final ep2 = await addQueued('ep2', 1);
      await addQueued('ep3', 2);
      // continueAfterQueue defaults to false; turn group continuation off too.
      await AppSettingsRepositoryImpl(
        database: db,
      ).setContinueAfterGroupEnds(value: false);

      final onCompleted = wireCompletion(ep2);
      await onCompleted(stopAfter: false);

      expect(
        (await db.select(db.queueItems).get()).map((q) => q.episodeId).toList(),
        isNot(contains(ep2)),
        reason: 'ep2 still removed',
      );
      verify(() => handler.stop()).called(1);
      verifyNever(
        () => handler.playEpisode(
          any(),
          resumePositionSeconds: any(named: 'resumePositionSeconds'),
        ),
      );
    },
  );

  test('stopAfter flag stops even when continue settings are on', () async {
    final ep1 = await addQueued('ep1', 0);
    await addQueued('ep2', 1);

    final onCompleted = wireCompletion(ep1);
    await onCompleted(stopAfter: true);

    verify(() => handler.stop()).called(1);
    verifyNever(
      () => handler.playEpisode(
        any(),
        resumePositionSeconds: any(named: 'resumePositionSeconds'),
      ),
    );
  });

  test('group boundary with "continue after group" off stops at the podcast '
      'change (#327)', () async {
    final ep1 = await addQueuedFor(1, 'ep1', 0);
    await addQueuedFor(2, 'ep2-otherpod', 1);
    // Not both-off: keep queue continuation on so the group gate is what stops.
    final settings = AppSettingsRepositoryImpl(database: db);
    await settings.setContinueAfterQueue(value: true);
    await settings.setContinueAfterGroupEnds(value: false);

    final onCompleted = wireCompletion(ep1);
    await onCompleted(stopAfter: false);

    verify(() => handler.stop()).called(1);
    verifyNever(
      () => handler.playEpisode(
        any(),
        resumePositionSeconds: any(named: 'resumePositionSeconds'),
      ),
    );
  });
}
