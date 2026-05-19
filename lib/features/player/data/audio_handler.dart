import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:logging/logging.dart';

import '../domain/sleep_timer.dart';

final _log = Logger('AudioHandler');

class EarshotAudioHandler extends BaseAudioHandler with SeekHandler {
  EarshotAudioHandler() {
    _attachPlaybackListener();
    _player.processingStateStream.listen((state) {
      if (state == ProcessingState.completed) unawaited(_onEpisodeCompleted());
    });

    sleepTimer = SleepTimer(
      onExpired: () {
        pause();
      },
    );
  }

  final AudioPlayer _player = AudioPlayer();
  late final SleepTimer sleepTimer;
  StreamSubscription<PlaybackState>? _playbackSubscription;

  // Set by queueAutoAdvanceProvider. If set, called instead of stop() when
  // an episode completes. The callback is responsible for calling stop() or
  // playEpisode() as appropriate.
  Future<void> Function()? onEpisodeCompleted;

  void _attachPlaybackListener() {
    _playbackSubscription = _player.playbackEventStream
        .map(_buildPlaybackState)
        .listen(playbackState.add);
  }

  // episodeId of the currently loaded episode — used by PositionTracker.
  final StreamController<int?> _episodeIdController =
      StreamController<int?>.broadcast();
  Stream<int?> get episodeIdStream => _episodeIdController.stream;

  Future<void> playEpisode(
    MediaItem item, {
    int resumePositionSeconds = 0,
  }) async {
    _log.info('Playing: ${item.title}');
    mediaItem.add(item);
    queue.add([item]);

    final episodeId = item.extras?['episodeId'] as int?;
    _episodeIdController.add(episodeId);

    try {
      await _player.setUrl(item.id);
      if (resumePositionSeconds > 0) {
        await _player.seek(Duration(seconds: resumePositionSeconds));
      }
      await _player.play();
    } on Exception catch (e) {
      _log.severe('Failed to load audio: $e');
    }
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() async {
    await _playbackSubscription?.cancel();
    _playbackSubscription = null;
    await _player.stop();
    _episodeIdController.add(null);
    // Skip super.stop() — it calls playbackState.add() which throws
    // "cannot add while addStream is in progress" because audio_service's
    // own infrastructure has an addStream open on the same BehaviorSubject.
    // BaseAudioHandler.stop() only emits idle state, so we do it directly.
    playbackState.add(
      playbackState.value.copyWith(
        processingState: AudioProcessingState.idle,
        playing: false,
      ),
    );
    _attachPlaybackListener();
  }

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> setSpeed(double speed) async {
    await _player.setSpeed(speed);
    // BaseAudioHandler.setSpeed only updates the state; we also need the
    // player itself changed, so we push the new speed explicitly.
    playbackState.add(playbackState.value.copyWith(speed: speed));
  }

  // SeekHandler provides fastForward/rewind using the configured intervals.

  Duration get position => _player.position;

  Stream<Duration> get positionStream => _player.positionStream;

  PlaybackState _buildPlaybackState(PlaybackEvent event) {
    return PlaybackState(
      controls: [
        MediaControl.rewind,
        if (_player.playing) MediaControl.pause else MediaControl.play,
        MediaControl.fastForward,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.fastForward,
        MediaAction.rewind,
      },
      androidCompactActionIndices: const [0, 1, 2],
      processingState: _mapProcessingState(_player.processingState),
      playing: _player.playing,
      updatePosition: _player.position,
      bufferedPosition: _player.bufferedPosition,
      speed: _player.speed,
    );
  }

  AudioProcessingState _mapProcessingState(ProcessingState state) =>
      switch (state) {
        ProcessingState.idle => AudioProcessingState.idle,
        ProcessingState.loading => AudioProcessingState.loading,
        ProcessingState.buffering => AudioProcessingState.buffering,
        ProcessingState.ready => AudioProcessingState.ready,
        ProcessingState.completed => AudioProcessingState.completed,
      };

  Future<void> _onEpisodeCompleted() async {
    _log.info('Episode completed: ${mediaItem.value?.title}');
    sleepTimer.onEpisodeEnded();
    final callback = onEpisodeCompleted;
    if (callback != null) {
      await callback();
    } else {
      await stop();
    }
  }

  Future<void> dispose() async {
    sleepTimer.dispose();
    await _playbackSubscription?.cancel();
    await _episodeIdController.close();
    await _player.dispose();
  }
}
