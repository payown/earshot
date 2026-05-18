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

  void attach(
    Stream<PlaybackState> playbackStateStream,
    Stream<int?> episodeIdStream,
  ) {
    int? currentEpisodeId;
    episodeIdStream.listen((id) => currentEpisodeId = id);

    _subscription = playbackStateStream.listen((state) async {
      final id = currentEpisodeId;
      if (id == null) return;

      final position = state.position.inSeconds;

      if (!state.playing &&
          state.processingState != AudioProcessingState.idle) {
        await _savePosition(id, position);
      }

      if (state.processingState == AudioProcessingState.completed) {
        await _markPlayed(id);
      }
    });
  }

  Future<void> savePositionNow(int episodeId, Duration position) =>
      _savePosition(episodeId, position.inSeconds);

  Future<void> _savePosition(int episodeId, int seconds) async {
    await (_db.update(_db.episodes)..where((e) => e.id.equals(episodeId)))
        .write(EpisodesCompanion(positionSeconds: Value(seconds)));
    _log.fine('Saved position $seconds for episode $episodeId');
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
