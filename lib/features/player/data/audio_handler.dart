import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:logging/logging.dart';

import '../domain/sleep_timer.dart';

final _log = Logger('AudioHandler');

class EarshotAudioHandler extends BaseAudioHandler with SeekHandler {
  EarshotAudioHandler() {
    _loudnessEnhancer = AndroidLoudnessEnhancer();
    _player = AudioPlayer(
      audioPipeline: AudioPipeline(
        androidAudioEffects: [_loudnessEnhancer],
      ),
    );
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

  late final AndroidLoudnessEnhancer _loudnessEnhancer;
  late final AudioPlayer _player;
  late final SleepTimer sleepTimer;
  StreamSubscription<PlaybackState>? _playbackSubscription;

  Future<void> Function()? onEpisodeCompleted;

  void _attachPlaybackListener() {
    _playbackSubscription = _player.playbackEventStream
        .map(_buildPlaybackState)
        .listen(playbackState.add);
  }

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

    // Restore per-podcast speed override before playback starts.
    final speedOverride = item.extras?['speedOverride'] as double?;
    if (speedOverride != null) {
      await _player.setSpeed(speedOverride);
      playbackState.add(playbackState.value.copyWith(speed: speedOverride));
    }

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

  // AirPods double-click fires skipToNext(). Remap to seek +30 s.
  @override
  Future<void> skipToNext() => _seekBy(const Duration(seconds: 30));

  // AirPods triple-click fires skipToPrevious(). Remap to seek -15 s.
  @override
  Future<void> skipToPrevious() => _seekBy(const Duration(seconds: -15));

  Future<void> _seekBy(Duration offset) async {
    var pos = _player.position + offset;
    if (pos < Duration.zero) pos = Duration.zero;
    final dur = _player.duration;
    if (dur != null && pos > dur) pos = dur;
    await _player.seek(pos);
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
    playbackState.add(playbackState.value.copyWith(speed: speed));
  }

  Future<void> setSkipSilenceEnabled(bool enabled) async {
    await _player.setSkipSilenceEnabled(enabled);
    _log.info('Skip silence: $enabled');
  }

  // Volume boost + Android dynamic compression.
  // iOS gets a 1.5× volume boost; Android also gets loudness normalization
  // via AndroidLoudnessEnhancer (targetGain 500 millibels ≈ +5 dB).
  Future<void> setVoiceEnhance(bool enabled) async {
    await _player.setVolume(enabled ? 1.5 : 1.0);
    try {
      await _loudnessEnhancer.setEnabled(enabled);
      if (enabled) await _loudnessEnhancer.setTargetGain(500);
    } on Exception {
      // AndroidLoudnessEnhancer is a no-op on iOS; swallow the error.
    }
    _log.info('Voice enhance: $enabled');
  }

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
        MediaAction.skipToNext,
        MediaAction.skipToPrevious,
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
