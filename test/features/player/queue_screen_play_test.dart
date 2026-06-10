import 'package:audio_service/audio_service.dart';
import 'package:drift/native.dart';
import 'package:earshot/core/providers/core_providers.dart';
import 'package:earshot/data/db/app_database.dart';
import 'package:earshot/data/db/enums.dart';
import 'package:earshot/features/player/data/audio_handler.dart';
import 'package:earshot/features/player/presentation/providers/player_providers.dart';
import 'package:earshot/features/player/presentation/screens/queue_screen.dart';
import 'package:earshot/features/subscriptions/domain/episode.dart';
import 'package:earshot/features/subscriptions/presentation/providers/subscriptions_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockAudioHandler extends Mock implements EarshotAudioHandler {}

Episode _episode({required String? artworkUrl}) => Episode(
  id: 1,
  podcastId: 1,
  guid: 'ep-1',
  title: 'Episode 1',
  audioUrl: 'https://example.com/ep1.mp3',
  artworkUrl: artworkUrl,
  status: EpisodeStatus.inQueue,
  downloadStatus: DownloadStatus.none,
  positionSeconds: 0,
  createdAt: DateTime(2024, 6, 1),
  durationSeconds: 3600,
  pubDate: DateTime(2024, 1, 1),
);

void main() {
  late AppDatabase db;
  late MockAudioHandler handler;

  setUpAll(() {
    registerFallbackValue(const MediaItem(id: 'fallback', title: 'fallback'));
  });

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    handler = MockAudioHandler();
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

  Future<void> pumpQueueScreen(WidgetTester tester, Episode episode) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          audioHandlerProvider.overrideWithValue(handler),
          queueProvider.overrideWith((_) => Stream.value([episode])),
          mediaItemProvider.overrideWith((_) => Stream.value(null)),
          subscriptionsProvider.overrideWith((_) => Stream.value(const [])),
          podcastProvider.overrideWith((_, __) => Stream.value(null)),
        ],
        child: const MaterialApp(home: QueueScreen()),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  group('Queue play with malformed artwork URL', () {
    // Regression test: Uri.parse on a malformed artworkUrl threw a
    // FormatException from every play entry point on the Queue tab.
    testWidgets('playing an episode does not throw and reaches the handler', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final episode = _episode(artworkUrl: 'http://[invalid');

      await pumpQueueScreen(tester, episode);

      final node = tester.getSemantics(
        find.bySemanticsLabel(RegExp('Episode 1')),
      );
      RendererBinding.instance.renderViews.first.owner!.semanticsOwner!
          .performAction(node.id, SemanticsAction.tap);
      await tester.pump();

      expect(tester.takeException(), isNull);

      final captured =
          verify(
                () => handler.playEpisode(
                  captureAny(),
                  resumePositionSeconds: any(named: 'resumePositionSeconds'),
                ),
              ).captured.single
              as MediaItem;
      expect(captured.artUri, isNull);

      // Let the gapless tip announce/dismiss timers expire.
      await tester.pump(const Duration(seconds: 6));
      handle.dispose();
    });

    testWidgets('a valid artwork URL still reaches the handler as artUri', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final episode = _episode(
        artworkUrl: 'https://example.com/art.jpg',
      );

      await pumpQueueScreen(tester, episode);

      final node = tester.getSemantics(
        find.bySemanticsLabel(RegExp('Episode 1')),
      );
      RendererBinding.instance.renderViews.first.owner!.semanticsOwner!
          .performAction(node.id, SemanticsAction.tap);
      await tester.pump();

      final captured =
          verify(
                () => handler.playEpisode(
                  captureAny(),
                  resumePositionSeconds: any(named: 'resumePositionSeconds'),
                ),
              ).captured.single
              as MediaItem;
      expect(captured.artUri, Uri.parse('https://example.com/art.jpg'));

      await tester.pump(const Duration(seconds: 6));
      handle.dispose();
    });
  });
}
