import 'package:audio_service/audio_service.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:earshot/core/providers/core_providers.dart';
import 'package:earshot/data/db/app_database.dart';
import 'package:earshot/data/db/enums.dart';
import 'package:earshot/features/bookmarks/domain/bookmark.dart';
import 'package:earshot/features/bookmarks/presentation/providers/bookmarks_providers.dart';
import 'package:earshot/features/player/data/audio_handler.dart';
import 'package:earshot/features/player/domain/chapter.dart';
import 'package:earshot/features/player/domain/sleep_timer.dart';
import 'package:earshot/features/player/presentation/providers/chapter_providers.dart';
import 'package:earshot/features/player/presentation/providers/player_providers.dart';
import 'package:earshot/features/player/presentation/screens/player_screen.dart';
import 'package:earshot/features/subscriptions/domain/podcast.dart';
import 'package:earshot/features/subscriptions/presentation/providers/subscriptions_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockAudioHandler extends Mock implements EarshotAudioHandler {}

void main() {
  late AppDatabase db;
  late MockAudioHandler handler;

  const mediaItem = MediaItem(
    id: 'https://example.com/ep1.mp3',
    title: 'Episode 1',
    extras: {'episodeId': 1, 'podcastId': 1},
  );

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    handler = MockAudioHandler();
    when(() => handler.markCurrentEpisodePlayed()).thenAnswer((_) async {});

    await db
        .into(db.podcasts)
        .insert(
          PodcastsCompanion.insert(
            rssUrl: 'https://example.com/feed.xml',
            title: 'Test Podcast',
          ),
        );
    await db
        .into(db.episodes)
        .insert(
          EpisodesCompanion.insert(
            podcastId: 1,
            guid: 'ep-1',
            title: 'Episode 1',
            audioUrl: 'https://example.com/ep1.mp3',
            status: const Value(EpisodeStatus.inQueue),
          ),
        );
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> pumpPlayer(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          audioHandlerProvider.overrideWithValue(handler),
          mediaItemProvider.overrideWith((_) => Stream.value(mediaItem)),
          playbackStateProvider.overrideWith(
            (_) => Stream.value(PlaybackState()),
          ),
          positionProvider.overrideWith((_) => Stream.value(Duration.zero)),
          sleepTimerStateProvider.overrideWith(
            (_) => Stream.value(const SleepTimerState.inactive()),
          ),
          chaptersProvider.overrideWith((_) async => const <Chapter>[]),
          // Override the DB-backed watch streams so no drift query streams stay
          // open; drift schedules a zero-duration cleanup timer when those close
          // at teardown, which trips the test framework's pending-timer check.
          currentEpisodeDescriptionProvider.overrideWith(
            (_) => Stream<String?>.value(null),
          ),
          currentEpisodeDownloadStatusProvider.overrideWith(
            (_) => Stream<DownloadStatus?>.value(null),
          ),
          bookmarksForEpisodeProvider.overrideWith(
            (_, __) => Stream.value(const <Bookmark>[]),
          ),
          optionalPodcastProvider.overrideWith(
            (_, __) => Stream<Podcast?>.value(null),
          ),
        ],
        child: const MaterialApp(home: PlayerScreen()),
      ),
    );
    // The player screen has implicit reveal animations; pump finite frames
    // rather than pumpAndSettle, which never settles in the test harness.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets(
    'Mark as played menu item routes to the handler completion flow',
    (tester) async {
      await pumpPlayer(tester);

      await tester.tap(find.byTooltip('Episode actions'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      await tester.tap(find.text('Mark as played'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      verify(() => handler.markCurrentEpisodePlayed()).called(1);
    },
  );

  testWidgets(
    'artwork node exposes a Mark as played rotor action, not the title heading',
    (tester) async {
      final handle = tester.ensureSemantics();
      await pumpPlayer(tester);

      // The rotor action lives on the Artwork node (the screen's actions host),
      // not on the title, which stays a clean heading. Direct Touch is off in
      // this test, so the action must still be present.
      final artwork = tester.getSemantics(find.bySemanticsLabel('Artwork'));
      expect(
        artwork.getSemanticsData().customSemanticsActionIds,
        isNotEmpty,
        reason: 'artwork node should carry the Mark as played rotor action',
      );

      final title = tester.getSemantics(find.text('Episode 1'));
      expect(
        title.getSemanticsData().flagsCollection.isHeader,
        isTrue,
        reason: 'title should remain a heading',
      );
      expect(
        title.getSemanticsData().customSemanticsActionIds ?? const <int>[],
        isEmpty,
        reason: 'title heading should not carry custom actions',
      );

      handle.dispose();
    },
  );
}
