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
  Timer? _periodicTimer;

  int? _currentEpisodeId;
  bool _isPlaying = false;

  // True once real playback has been observed for the current episode.
  // Gates the completed branch so a completion-on-load (restore at/past the
  // media end) can't mark an episode played without any actual listening.
  bool _hasPlayedSinceEpisodeChange = false;
  int _currentPositionSeconds = 0;
  int? _lastPositionSeconds;
  double _lastSpeed = 1.0;
  int _periodicTicks = 0;
  int _lastStateTimestampMs = 0;

  void attach(
    Stream<PlaybackState> playbackStateStream,
    Stream<int?> episodeIdStream,
  ) {
    episodeIdStream.listen((id) {
      _lastPositionSeconds = null;
      _currentEpisodeId = id;
      // Reset playing state so the periodic timer cannot write the previous
      // episode's position to the new episode before fresh state arrives.
      _isPlaying = false;
      _currentPositionSeconds = 0;
      _periodicTicks = 0;
      _hasPlayedSinceEpisodeChange = false;
    });

    _subscription = playbackStateStream.listen((state) async {
      final id = _currentEpisodeId;
      if (id == null) return;

      final position = state.position.inSeconds;
      _lastSpeed = state.speed;
      _isPlaying = state.playing;
      _currentPositionSeconds = position;
      _lastStateTimestampMs = DateTime.now().millisecondsSinceEpoch;

      if (state.playing &&
          state.processingState == AudioProcessingState.ready) {
        _hasPlayedSinceEpisodeChange = true;
      }

      final isPaused =
          !state.playing &&
          state.processingState != AudioProcessingState.idle &&
          state.processingState != AudioProcessingState.completed;

      if (isPaused) {
        await _savePosition(id, position);
        await _recordSession(id, position);
      }

      if (state.processingState == AudioProcessingState.completed) {
        if (!_hasPlayedSinceEpisodeChange) {
          _log.warning(
            'Ignoring completed state for episode $id: '
            'no playback observed since the episode was loaded.',
          );
          return;
        }
        await _recordSession(id, position);
        await _markPlayed(id, completionPosition: position);
      }

      _lastPositionSeconds = position;
    });

    _periodicTimer = Timer.periodic(const Duration(seconds: 10), (_) async {
      if (!_isPlaying) return;
      final id = _currentEpisodeId;
      if (id == null) return;
      await _savePosition(id, _currentPositionSeconds);
      _periodicTicks++;
      if (_periodicTicks >= 3) {
        _periodicTicks = 0;
        final pos = _interpolatedPositionSeconds;
        await _recordSession(id, pos);
        _lastPositionSeconds = pos;
      }
    });
  }

  int get _interpolatedPositionSeconds {
    if (!_isPlaying || _lastStateTimestampMs == 0)
      return _currentPositionSeconds;
    final elapsedMs =
        DateTime.now().millisecondsSinceEpoch - _lastStateTimestampMs;
    return _currentPositionSeconds + (elapsedMs / 1000 * _lastSpeed).round();
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

  Future<void> _markPlayed(
    int episodeId, {
    required int completionPosition,
  }) async {
    // Guard against false completion events fired when switching episodes.
    // Only mark as played when the position is within 85% of the episode
    // duration. If duration is unknown we trust the completion event.
    final episode = await (_db.select(
      _db.episodes,
    )..where((e) => e.id.equals(episodeId))).getSingleOrNull();
    if (episode == null) return;

    final duration = episode.durationSeconds;
    if (duration != null && duration > 0) {
      // Integer math avoids floating-point rounding: pos * 100 < dur * 85.
      if (completionPosition * 100 < duration * 85) {
        _log.warning(
          'Skipping markPlayed for episode $episodeId: '
          'position ${completionPosition}s is less than 85% of ${duration}s. '
          'Likely a spurious completion event from episode switching.',
        );
        return;
      }
    }

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

  void dispose() {
    _periodicTimer?.cancel();
    _subscription?.cancel();
  }
}
