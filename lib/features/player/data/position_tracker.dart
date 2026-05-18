import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:drift/drift.dart';
import 'package:logging/logging.dart';

import '../../../data/db/app_database.dart';
import '../../../data/db/enums.dart';

final _log = Logger('PositionTracker');

class PositionTracker {
  PositionTracker({required AppDatabase database}) : _db = database;

  final AppDatabase _db;
  StreamSubscription<PlaybackState>? _subscription;

  int? _lastPositionSeconds;
  double _lastSpeed = 1.0;

  void attach(
    Stream<PlaybackState> playbackStateStream,
    Stream<int?> episodeIdStream,
  ) {
    int? currentEpisodeId;
    episodeIdStream.listen((id) {
      _lastPositionSeconds = null;
      currentEpisodeId = id;
    });

    _subscription = playbackStateStream.listen((state) async {
      final id = currentEpisodeId;
      if (id == null) return;

      final position = state.position.inSeconds;
      _lastSpeed = state.speed;

      final wasPlaying = state.playing;
      final isPaused =
          !wasPlaying &&
          state.processingState != AudioProcessingState.idle &&
          state.processingState != AudioProcessingState.completed;

      if (isPaused) {
        await _savePosition(id, position);
        await _recordSession(id, position);
      }

      if (state.processingState == AudioProcessingState.completed) {
        await _recordSession(id, position);
        await _markPlayed(id);
      }

      _lastPositionSeconds = position;
    });
  }

  Future<void> savePositionNow(int episodeId, Duration position) =>
      _savePosition(episodeId, position.inSeconds);

  Future<void> _savePosition(int episodeId, int seconds) async {
    await (_db.update(_db.episodes)..where((e) => e.id.equals(episodeId)))
        .write(EpisodesCompanion(positionSeconds: Value(seconds)));
    _log.fine('Saved position $seconds for episode $episodeId');
  }

  Future<void> _recordSession(int episodeId, int currentPosition) async {
    final prev = _lastPositionSeconds;
    if (prev == null || currentPosition <= prev) return;

    final duration = currentPosition - prev;
    if (duration < 2) return; // Ignore trivial sessions.

    final episode = await (_db.select(
      _db.episodes,
    )..where((e) => e.id.equals(episodeId))).getSingleOrNull();
    if (episode == null) return;

    await _db
        .into(_db.listeningSessions)
        .insert(
          ListeningSessionsCompanion.insert(
            episodeId: episodeId,
            podcastId: episode.podcastId,
            durationSeconds: duration,
            speed: Value(_lastSpeed),
            date: Value(DateTime.now().toUtc()),
          ),
        );
    _log.fine('Recorded session: ${duration}s at ${_lastSpeed}x');
  }

  Future<void> _markPlayed(int episodeId) async {
    await (_db.update(
      _db.episodes,
    )..where((e) => e.id.equals(episodeId))).write(
      EpisodesCompanion(
        status: const Value(EpisodeStatus.played),
        positionSeconds: const Value(0),
        playedAt: Value(DateTime.now().toUtc()),
      ),
    );
    _log.info('Marked episode $episodeId as played');
  }

  void dispose() => _subscription?.cancel();
}
