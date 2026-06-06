import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:logging/logging.dart';

import '../../../core/constants/playback.dart';
import '../../../features/settings/data/app_settings_repository.dart';
import '../domain/sleep_timer.dart';

final _log = Logger('AudioHandler');

/// Returns [AudioSource.file] when the item has a local [downloadPath] in its
/// extras, otherwise falls back to streaming via [AudioSource.uri].
AudioSource resolveAudioSource(MediaItem item) {
  final downloadPath = item.extras?['downloadPath'] as String?;
  if (downloadPath != null) {
    return AudioSource.file(downloadPath);
  }
  return AudioSource.uri(Uri.parse(item.id));
}

/// Returns true when the player should preload the next episode.
/// [position] >= [duration] - [threshold] triggers buffering.
bool shouldPreload(Duration position, Duration duration, Duration threshold) =>
    duration > Duration.zero && position >= duration - threshold;

class EarshotAudioHandler extends BaseAudioHandler with SeekHandler {
  EarshotAudioHandler() {
    _loudnessEnhancer = AndroidLoudnessEnhancer();
    _player = AudioPlayer(
      audioPipeline: AudioPipeline(
        androidAudioEffects: [_loudnessEnhancer],
      ),
    );
    _attachPlaybackListener();
    _attachIndexListener();
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

  AppSettingsRepository? _settings;

  // Called by the provider layer once the DB is available so _applyPlaybackSettings
  // can read global speed + trim silence without relying on MediaItem extras.
  void attachSettings(AppSettingsRepository settings) {
    _settings = settings;
  }

  StreamSubscription<PlaybackState>? _playbackSubscription;

  MediaItem? _currentMediaItem;
  MediaItem? _nextMediaItem;

  // Tracks previous index to detect forward advances in the playlist.
  int? _lastKnownIndex;

  // Prevents re-entrant processing when removeAudioSourceAt(0) fires a
  // currentIndexStream event.
  bool _isAdvancing = false;

  /// Called when the playlist advances gaplessly to the next episode.
  /// [previousEpisodeId] is the episode that just finished.
  Future<void> Function(int? previousEpisodeId)? onEpisodeAdvanced;

  /// Called when the last episode in the playlist finishes.
  Future<void> Function()? onEpisodeCompleted;

  void _attachPlaybackListener() {
    _playbackSubscription = _player.playbackEventStream
        .map(_buildPlaybackState)
        .listen(playbackState.add);
  }

  void _attachIndexListener() {
    _player.currentIndexStream.listen((index) {
      final last = _lastKnownIndex;
      _lastKnownIndex = index;
      if (index == null || last == null) return;
      if (index > last && !_isAdvancing) {
        _isAdvancing = true;
        unawaited(_onGaplessAdvance());
      }
    });
  }

  final StreamController<int?> _episodeIdController =
      StreamController<int?>.broadcast();
  Stream<int?> get episodeIdStream => _episodeIdController.stream;

  AudioSource _resolveAudioSource(MediaItem item) => resolveAudioSource(item);

  Future<void> _applyPlaybackSettings(MediaItem item) async {
    final globalSpeed = await _settings?.getGlobalSpeed() ?? 1.0;
    final speed = (item.extras?['speedOverride'] as double?) ?? globalSpeed;
    await _player.setSpeed(speed);
    playbackState.add(playbackState.value.copyWith(speed: speed));

    final globalTrimSilence = await _settings?.isSkipSilenceEnabled() ?? false;
    final trimSilence =
        (item.extras?['trimSilenceOverride'] as bool?) ?? globalTrimSilence;
    await _player.setSkipSilenceEnabled(trimSilence);
  }

  Future<void> playEpisode(
    MediaItem item, {
    int resumePositionSeconds = 0,
  }) async {
    _log.info('Playing: ${item.title}');
    _currentMediaItem = item;
    _nextMediaItem = null;
    _lastKnownIndex = 0;
    mediaItem.add(item);
    queue.add([item]);

    final episodeId = item.extras?['episodeId'] as int?;
    _episodeIdController.add(episodeId);

    await _applyPlaybackSettings(item);

    try {
      await _player.setAudioSources(
        [_resolveAudioSource(item)],
        initialIndex: 0,
        initialPosition: Duration(seconds: resumePositionSeconds),
      );
      await _player.play();
    } on Exception catch (e) {
      _log.severe('Failed to load audio for "${item.title}": $e');
      mediaItem.add(null);
      await stop();
    }
  }

  Future<void> loadEpisode(
    MediaItem item, {
    int resumePositionSeconds = 0,
  }) async {
    _log.info('Restoring: ${item.title}');
    _currentMediaItem = item;
    _nextMediaItem = null;
    _lastKnownIndex = 0;
    mediaItem.add(item);
    queue.add([item]);

    final episodeId = item.extras?['episodeId'] as int?;
    _episodeIdController.add(episodeId);

    await _applyPlaybackSettings(item);

    try {
      await _player.setAudioSources(
        [_resolveAudioSource(item)],
        initialIndex: 0,
        initialPosition: Duration(seconds: resumePositionSeconds),
      );
    } on Exception catch (e) {
      _log.severe('Failed to restore "${item.title}": $e');
      mediaItem.add(null);
      await stop();
    }
  }

  /// Adds [item] as the next item in the playlist so just_audio can
  /// buffer and transition gaplessly. Replaces any previously preloaded item.
  Future<void> preloadNext(MediaItem item) async {
    _nextMediaItem = item;
    // Drop any stale preloaded item before adding the new one.
    while (_player.audioSources.length > 1) {
      await _player.removeAudioSourceAt(_player.audioSources.length - 1);
    }
    await _player.addAudioSource(_resolveAudioSource(item));
    _log.info('Preloaded next: ${item.title}');
  }

  Future<void> _onGaplessAdvance() async {
    _log.info(
      'Gapless advance: ${_currentMediaItem?.title} → ${_nextMediaItem?.title}',
    );
    final previousEpisodeId = _currentMediaItem?.extras?['episodeId'] as int?;
    final next = _nextMediaItem;

    try {
      if (next != null) {
        _currentMediaItem = next;
        _nextMediaItem = null;
        mediaItem.add(next);

        final episodeId = next.extras?['episodeId'] as int?;
        _episodeIdController.add(episodeId);

        await _applyPlaybackSettings(next);

        // Remove the completed episode from the playlist head.
        // This causes currentIndexStream to emit 0; _isAdvancing suppresses it.
        await _player.removeAudioSourceAt(0);
      }

      sleepTimer.onEpisodeEnded();
      final callback = onEpisodeAdvanced;
      if (callback != null) {
        await callback(previousEpisodeId);
      }
    } finally {
      _isAdvancing = false;
    }
  }

  // AirPods double-click fires skipToNext(). Remap to seek +30 s.
  @override
  Future<void> skipToNext() => _seekBy(kSkipForwardDuration);

  // AirPods triple-click fires skipToPrevious(). Remap to seek -15 s.
  @override
  Future<void> skipToPrevious() => _seekBy(-kSkipBackDuration);

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
    _currentMediaItem = null;
    _nextMediaItem = null;
    _lastKnownIndex = null;
    _isAdvancing = false;
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

  // Android only: loudness normalization via AndroidLoudnessEnhancer.
  // iOS Voice Boost is not shown in the UI (AVQueuePlayer cannot host
  // AVAudioEngine EQ nodes). This method is therefore only called on Android.
  Future<void> setVoiceEnhance(bool enabled) async {
    try {
      await _loudnessEnhancer.setEnabled(enabled);
      if (enabled) await _loudnessEnhancer.setTargetGain(500);
    } on Exception {
      _log.warning('setVoiceEnhance failed: $enabled');
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
