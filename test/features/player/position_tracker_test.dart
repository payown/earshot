import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:drift/drift.dart' hide isNotNull;
import 'package:drift/native.dart';
import 'package:earshot/data/db/app_database.dart';
import 'package:earshot/data/db/enums.dart';
import 'package:earshot/features/player/data/position_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late PositionTracker tracker;
  late StreamController<PlaybackState> playbackStates;
  late StreamController<int?> episodeIds;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    tracker = PositionTracker(database: db);
    playbackStates = StreamController<PlaybackState>();
    episodeIds = StreamController<int?>();
    tracker.attach(playbackStates.stream, episodeIds.stream);
  });

  tearDown(() async {
    tracker.dispose();
    await playbackStates.close();
    await episodeIds.close();
    await db.close();
  });

  Future<int> addEpisode({int? durationSeconds}) async {
    final podcastId = await db
        .into(db.podcasts)
        .insert(
          PodcastsCompanion.insert(
            rssUrl: 'https://example.com/feed.xml',
            title: 'Test Podcast',
          ),
        );
    return db
        .into(db.episodes)
        .insert(
          EpisodesCompanion.insert(
            podcastId: podcastId,
            guid: 'guid-1',
            title: 'Episode',
            audioUrl: 'https://example.com/ep.mp3',
            durationSeconds: Value(durationSeconds),
          ),
        );
  }

  Future<EpisodeRow> episodeRow(int id) =>
      (db.select(db.episodes)..where((e) => e.id.equals(id))).getSingle();

  Future<int> sessionCount() async =>
      (await db.select(db.listeningSessions).get()).length;

  PlaybackState state({
    required AudioProcessingState processingState,
    required bool playing,
    int positionSeconds = 0,
  }) => PlaybackState(
    processingState: processingState,
    playing: playing,
    updatePosition: Duration(seconds: positionSeconds),
  );

  test(
    'completed without any prior playback does not mark played '
    '(completion-on-load after a crash)',
    () async {
      final epId = await addEpisode(durationSeconds: 100);

      episodeIds.add(epId);
      await pumpEventQueue();
      playbackStates.add(
        state(
          processingState: AudioProcessingState.completed,
          playing: false,
          positionSeconds: 99,
        ),
      );
      await pumpEventQueue();

      final row = await episodeRow(epId);
      expect(row.status, EpisodeStatus.newEpisode);
      expect(await sessionCount(), 0);
    },
  );

  test('completed after real playback at >= 85% marks played', () async {
    final epId = await addEpisode(durationSeconds: 100);

    episodeIds.add(epId);
    await pumpEventQueue();
    playbackStates.add(
      state(
        processingState: AudioProcessingState.ready,
        playing: true,
        positionSeconds: 10,
      ),
    );
    await pumpEventQueue();
    playbackStates.add(
      state(
        processingState: AudioProcessingState.completed,
        playing: true,
        positionSeconds: 99,
      ),
    );
    await pumpEventQueue();

    final row = await episodeRow(epId);
    expect(row.status, EpisodeStatus.played);
    expect(row.positionSeconds, 0);
    expect(row.playedAt, isNotNull);
  });

  test(
    'duration-null episode: completed without playback does not mark played',
    () async {
      // Before the playback-evidence gate, a null duration bypassed the 85%
      // guard entirely and any completed event marked the episode played.
      final epId = await addEpisode();

      episodeIds.add(epId);
      await pumpEventQueue();
      playbackStates.add(
        state(
          processingState: AudioProcessingState.completed,
          playing: false,
        ),
      );
      await pumpEventQueue();

      final row = await episodeRow(epId);
      expect(row.status, EpisodeStatus.newEpisode);
    },
  );

  test(
    'duration-null episode: completed after real playback still marks played',
    () async {
      final epId = await addEpisode();

      episodeIds.add(epId);
      await pumpEventQueue();
      playbackStates.add(
        state(
          processingState: AudioProcessingState.ready,
          playing: true,
          positionSeconds: 10,
        ),
      );
      await pumpEventQueue();
      playbackStates.add(
        state(
          processingState: AudioProcessingState.completed,
          playing: true,
          positionSeconds: 50,
        ),
      );
      await pumpEventQueue();

      final row = await episodeRow(epId);
      expect(row.status, EpisodeStatus.played);
    },
  );

  test('switching episodes resets the playback-evidence gate', () async {
    final ep1 = await addEpisode(durationSeconds: 100);
    final ep2 = await db
        .into(db.episodes)
        .insert(
          EpisodesCompanion.insert(
            podcastId: (await episodeRow(ep1)).podcastId,
            guid: 'guid-2',
            title: 'Episode 2',
            audioUrl: 'https://example.com/ep2.mp3',
            durationSeconds: const Value(100),
          ),
        );

    // Real playback on episode 1.
    episodeIds.add(ep1);
    await pumpEventQueue();
    playbackStates.add(
      state(
        processingState: AudioProcessingState.ready,
        playing: true,
        positionSeconds: 10,
      ),
    );
    await pumpEventQueue();

    // Switch to episode 2, then a completed event arrives before any
    // playback of episode 2 — it must not be marked played.
    episodeIds.add(ep2);
    await pumpEventQueue();
    playbackStates.add(
      state(
        processingState: AudioProcessingState.completed,
        playing: false,
        positionSeconds: 99,
      ),
    );
    await pumpEventQueue();

    final row = await episodeRow(ep2);
    expect(row.status, EpisodeStatus.newEpisode);
  });
}
