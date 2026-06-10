import 'package:audio_service/audio_service.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:earshot/core/episode_playback.dart';
import 'package:earshot/core/providers/core_providers.dart';
import 'package:earshot/data/db/app_database.dart';
import 'package:earshot/data/db/enums.dart';
import 'package:earshot/features/player/data/audio_handler.dart';
import 'package:earshot/features/player/presentation/providers/player_providers.dart';
import 'package:earshot/features/subscriptions/domain/episode.dart';
import 'package:earshot/features/subscriptions/presentation/providers/subscriptions_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockAudioHandler extends Mock implements EarshotAudioHandler {}

Episode _episode({
  String? artworkUrl,
  String? downloadPath,
  DownloadStatus downloadStatus = DownloadStatus.none,
  int positionSeconds = 0,
  int? durationSeconds = 3600,
  EpisodeStatus status = EpisodeStatus.newEpisode,
}) => Episode(
  id: 1,
  podcastId: 1,
  guid: 'ep-1',
  title: 'Episode 1',
  audioUrl: 'https://example.com/ep1.mp3',
  artworkUrl: artworkUrl,
  status: status,
  downloadStatus: downloadStatus,
  downloadPath: downloadPath,
  positionSeconds: positionSeconds,
  createdAt: DateTime(2024, 6, 1),
  durationSeconds: durationSeconds,
  pubDate: DateTime(2024, 1, 1),
);

void main() {
  late AppDatabase db;
  late MockAudioHandler handler;

  setUpAll(() {
    registerFallbackValue(const MediaItem(id: 'fallback', title: 'fallback'));
  });

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    handler = MockAudioHandler();
    when(
      () => handler.playEpisode(
        any(),
        resumePositionSeconds: any(named: 'resumePositionSeconds'),
      ),
    ).thenAnswer((_) async {});

    // addToQueue has a foreign key on episodes.id, so the row must exist.
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
            status: const Value(EpisodeStatus.newEpisode),
          ),
        );
  });

  tearDown(() async {
    await db.close();
  });

  /// Pumps a button that calls [playEpisodeNow] for [episode] when tapped,
  /// then taps it and settles.
  Future<void> playEpisode(WidgetTester tester, Episode episode) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          audioHandlerProvider.overrideWithValue(handler),
          podcastProvider.overrideWith((_, __) => Stream.value(null)),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => ElevatedButton(
                onPressed: () => playEpisodeNow(
                  context: context,
                  ref: ref,
                  episode: episode,
                ),
                child: const Text('Play'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Play'));
    await tester.pumpAndSettle();
  }

  List<Object?> capturedPlay() => verify(
    () => handler.playEpisode(
      captureAny(),
      resumePositionSeconds: captureAny(named: 'resumePositionSeconds'),
    ),
  ).captured;

  testWidgets('a downloaded episode passes downloadPath to the handler', (
    tester,
  ) async {
    await playEpisode(
      tester,
      _episode(
        downloadPath: '/var/mobile/ep1.mp3',
        downloadStatus: DownloadStatus.downloaded,
      ),
    );

    final mediaItem = capturedPlay().first as MediaItem;
    expect(mediaItem.extras?['downloadPath'], '/var/mobile/ep1.mp3');
  });

  testWidgets('a malformed artwork URL does not throw and yields null artUri', (
    tester,
  ) async {
    await playEpisode(tester, _episode(artworkUrl: 'http://[invalid'));

    expect(tester.takeException(), isNull);
    final mediaItem = capturedPlay().first as MediaItem;
    expect(mediaItem.artUri, isNull);
  });

  testWidgets('adds the episode to the queue', (tester) async {
    await playEpisode(tester, _episode());

    final rows = await db.select(db.queueItems).get();
    expect(rows.map((r) => r.episodeId), contains(1));
  });

  testWidgets('never marks the episode played', (tester) async {
    await playEpisode(tester, _episode());

    final row = await (db.select(
      db.episodes,
    )..where((e) => e.id.equals(1))).getSingle();
    expect(row.status, isNot(EpisodeStatus.played));
    expect(row.playedAt, isNull);
  });

  testWidgets('clamps the resume position past the 95% threshold', (
    tester,
  ) async {
    // 3500 of 3600 is past 95% (3420), so resume should reset to 0.
    await playEpisode(
      tester,
      _episode(positionSeconds: 3500, durationSeconds: 3600),
    );

    final resume = capturedPlay()[1] as int;
    expect(resume, 0);
  });

  testWidgets('honors a mid-episode resume position', (tester) async {
    await playEpisode(
      tester,
      _episode(positionSeconds: 600, durationSeconds: 3600),
    );

    final resume = capturedPlay()[1] as int;
    expect(resume, 600);
  });
}
